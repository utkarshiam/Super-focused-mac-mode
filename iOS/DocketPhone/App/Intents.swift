import AppIntents
import Foundation
import MemoryKit

/// Start things without opening Docket first: Siri ("Record in Docket"), Spotlight, the Action Button
/// (Settings → Action Button → Shortcut → Docket), Shortcuts, and `docket://record`.
@MainActor
final class LaunchRouter: ObservableObject {
    static let shared = LaunchRouter()

    /// Set by the intent or URL; the app starts recording as soon as it's in front.
    @Published var wantsRecording = false

    func handle(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == "docket" else { return false }
        switch url.host?.lowercased() {
        case "record", "debrief":
            wantsRecording = true
            return true
        default:
            return false
        }
    }
}

struct RecordDebriefIntent: AppIntent {
    static let title: LocalizedStringResource = "Record a debrief"
    static let description = IntentDescription("Opens Docket and starts recording at once. Stop when you're done and it turns into tasks.")
    static let openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult {
        LaunchRouter.shared.wantsRecording = true
        return .result()
    }
}

struct AddTaskIntent: AppIntent {
    static let title: LocalizedStringResource = "Add a task"
    static let description = IntentDescription("Schedules a task in Docket from what you say: “Call Rohan next Friday at 3 for half an hour, remind me 15 minutes before.” It reaches your Mac through your Docket folder.")

    @Parameter(title: "Task", requestValueDialog: "What's the task, and when?")
    var task: String

    static var parameterSummary: some ParameterSummary { Summary("Add \(\.$task) to Docket") }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let spoken = task.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !spoken.isEmpty else { return .result(dialog: "There was no task to add.") }
        let tasks = await TaskDrop.schedule(spoken)
        for task in tasks { TaskDrop.add(task) }
        return .result(dialog: IntentDialog(stringLiteral: TaskDrop.reply(tasks)))
    }
}

struct DocketShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: RecordDebriefIntent(),
                    phrases: ["Record in \(.applicationName)",
                              "Start a debrief in \(.applicationName)",
                              "Record a debrief in \(.applicationName)",
                              "Start recording in \(.applicationName)"],
                    shortTitle: "Record a debrief", systemImageName: "mic")
        AppShortcut(intent: AddTaskIntent(),
                    phrases: ["Schedule a task in \(.applicationName)",
                              "Add a task in \(.applicationName)",
                              "Add a task to \(.applicationName)",
                              "Schedule in \(.applicationName)",
                              "New task in \(.applicationName)"],
                    shortTitle: "Add a task", systemImageName: "checkmark.circle")
    }
}

/// A task from Siri or Shortcuts: through the running app when there is one, else straight into Pending
/// and on to the Docket folder (and into the sent list, so Today shows it on the next launch).
@MainActor
enum TaskDrop {
    /// What was said, as tasks: Gemini reads it when there's a key (within a few seconds), else the phone reads
    /// the date, time and length itself.
    static func schedule(_ spoken: String, now: Date = Date()) async -> [DebriefTask] {
        let model = AppModel.current
        let ai: MemoryAI? = model?.makeAI() ?? Keychain.readKey().map { GeminiMemoryAI(apiKey: $0) }
        if let ai, model?.isDemo != true {
            let parser = SpokenTaskParser(ai: ai, listNames: model?.snapshot?.listNames ?? [], knownPeople: model?.snapshot?.knownPeople ?? [])
            let parsed = await withTaskGroup(of: [DebriefTask]?.self) { group -> [DebriefTask]? in
                group.addTask { try? await parser.parse(spoken, now: now) }
                group.addTask {
                    try? await Task.sleep(nanoseconds: 8_000_000_000)
                    return nil
                }
                let first = await group.next() ?? nil
                group.cancelAll()
                return first
            }
            if let parsed, !parsed.isEmpty { return parsed }
        }
        return [TaskTextParser.draft(spoken, now: now)]
    }

    /// "Added Call Rohan for Fri 16 Oct at 3:00 PM." / "Added 2 tasks: …"
    static func reply(_ tasks: [DebriefTask]) -> String {
        func line(_ t: DebriefTask) -> String {
            var text = t.title
            if let due = t.dueDate { text += " for \(PhoneFmt.spokenDue(due, hasTime: t.dueHasTime))" }
            if let rule = t.repeatRule { text += ", \(rule.label)" }
            return text
        }
        switch tasks.count {
        case 0: return "There was no task to add."
        case 1: return "Added \(line(tasks[0]))."
        default: return "Added \(tasks.count) tasks: " + tasks.map(line).joined(separator: "; ") + "."
        }
    }

    static func add(_ task: DebriefTask) {
        if let model = AppModel.current {
            model.addTask(task, quiet: true)
            return
        }
        let envelope = CaptureEnvelope.task(task)
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let local = LocalStore(root: documents)
        guard (try? local.stage(envelope, attachment: nil)) != nil else { return }
        var sent = local.loadSentTasks()
        sent.insert(SentTask(task: task, sentAt: Date()), at: 0)
        local.saveSentTasks(sent)
        var records = local.loadRecords()
        records.insert(CaptureRecord(id: envelope.id, kind: .task, title: task.title, detail: PhoneFmt.taskDetail(task),
                                     createdAt: envelope.createdAt, state: .waiting), at: 0)
        if let picked = FolderBookmark.resolve() {
            let sent = Set(local.flush(to: FolderBookmark.bridgeRoot(in: picked)).sent)
            for i in records.indices where sent.contains(records[i].id) { records[i].state = .synced }
        }
        local.saveRecords(Array(records.prefix(LocalStore.recentLimit)))
    }
}
