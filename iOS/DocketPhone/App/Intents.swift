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
    static let description = IntentDescription("Adds a task to Docket. It reaches your Mac through your Docket folder.")

    @Parameter(title: "Task", requestValueDialog: "What's the task?")
    var task: String

    static var parameterSummary: some ParameterSummary { Summary("Add \(\.$task) to Docket") }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let title = task.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return .result(dialog: "There was no task to add.") }
        TaskDrop.add(title)
        return .result(dialog: "Added “\(title)” to Docket.")
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
                    phrases: ["Add a task in \(.applicationName)", "Add a task to \(.applicationName)"],
                    shortTitle: "Add a task", systemImageName: "checkmark.circle")
    }
}

/// A task from Siri or Shortcuts: through the running app when there is one, else straight into Pending
/// and on to the Docket folder.
@MainActor
enum TaskDrop {
    static func add(_ title: String) {
        let envelope = CaptureEnvelope(kind: .task, title: title, device: "iPhone")
        if let model = AppModel.current {
            model.capture(envelope, title: title, quiet: true)
            return
        }
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let local = LocalStore(root: documents)
        guard (try? local.stage(envelope, attachment: nil)) != nil else { return }
        var records = local.loadRecords()
        records.insert(CaptureRecord(id: envelope.id, kind: .task, title: title, detail: nil, createdAt: envelope.createdAt, state: .waiting), at: 0)
        if let picked = FolderBookmark.resolve() {
            let sent = Set(local.flush(to: FolderBookmark.bridgeRoot(in: picked)).sent)
            for i in records.indices where sent.contains(records[i].id) { records[i].state = .synced }
        }
        local.saveRecords(Array(records.prefix(LocalStore.recentLimit)))
    }
}
