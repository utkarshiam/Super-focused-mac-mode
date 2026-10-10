import AppKit
import Combine
import Foundation
import MemoryKit

/// The iPhone link, through a shared folder (iCloud Drive by default; no server, no account). Off until the
/// user turns it on in Settings → Memory. While on:
/// - **In**: every minute, when Docket comes to the front and when the folder's Inbox changes, captures the
///   phone dropped there become memories; a task envelope becomes a task, "done" / "undone" / "delete" ones
///   complete, reopen or delete it, and a voice note becomes its tasks and a memory (`VoiceIntake`).
/// - **Out**: ten seconds after memory, the brain or the tasks change, the library and brain are published for the phone
///   (`PhoneBridge.publish`) with the tasks it shows (open ones overdue, today and the next 7 days, recent ones
///   from voice notes, and today's finished ones) and the list names.
/// Never runs in tests or screenshot mode (`isAllowed`), so iCloud Drive is never touched there.
@MainActor
final class PhoneSync: ObservableObject {
    @Published private(set) var lastSync: Date?
    /// The last thing that went wrong, in a sentence (nil when all is well).
    @Published private(set) var problem: String?
    @Published private(set) var isOn = false

    let library: MemoryLibrary
    let voice: VoiceIntake
    /// Published with the library (topics, pages and the map, capped).
    let brain: MemoryBrain?
    private weak var store: Store?
    private var timer: Timer?
    private var publishWork: DispatchWorkItem?
    private var watcher: DispatchSourceFileSystemObject?
    private var ingestWork: DispatchWorkItem?
    private var cancellables = Set<AnyCancellable>()
    private var publishing = false

    static let ingestInterval: TimeInterval = 60
    static let publishDelay: TimeInterval = 10
    /// How far ahead the phone's task list looks.
    static let daysAhead = 7

    /// The real app only: never in unit tests or screenshot mode.
    static var isAllowed: Bool { !GeminiClient.isUnitTesting && !DebugSnapshot.isActive }

    /// `~/Library/Mobile Documents/com~apple~CloudDocs/Docket`: "Docket" in iCloud Drive.
    nonisolated static var defaultRoot: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs/Docket", isDirectory: true)
    }

    /// The folder chosen in Settings, or the iCloud Drive default.
    static var root: URL {
        let path = UserDefaults.standard.string(forKey: Prefs.Key.phoneFolder) ?? ""
        return path.isEmpty ? defaultRoot : URL(fileURLWithPath: path, isDirectory: true)
    }

    init(library: MemoryLibrary, store: Store, voice: VoiceIntake, brain: MemoryBrain? = nil) {
        self.library = library
        self.brain = brain
        self.store = store
        self.voice = voice
        let stamp = UserDefaults.standard.double(forKey: Prefs.Key.phoneLastSync)
        lastSync = stamp > 0 ? Date(timeIntervalSince1970: stamp) : nil
    }

    /// Follows the switch in Settings (called at launch and when preferences change).
    func update() {
        let wanted = Prefs.phoneSync && Self.isAllowed
        guard wanted != isOn else { return }
        wanted ? start() : stop()
    }

    /// The folder changed in Settings: watch the new one and sync now.
    func folderChanged() {
        guard isOn else { return }
        stop()
        start()
    }

    private func start() {
        isOn = true
        problem = nil
        let root = Self.root
        do {
            for folder in [root, PhoneBridge(root: root).inboxURL, PhoneBridge(root: root).libraryURL] {
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            }
        } catch {
            problem = "Couldn't create the Docket folder: \(error.localizedDescription)"
        }
        let t = Timer(timeInterval: Self.ingestInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.ingest() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
        watch(PhoneBridge(root: root).inboxURL)

        library.changes
            .sink { [weak self] in self?.schedulePublish() }
            .store(in: &cancellables)
        brain?.changes
            .sink { [weak self] in self?.schedulePublish() }
            .store(in: &cancellables)
        store?.$tasks.dropFirst()
            .sink { [weak self] _ in self?.schedulePublish() }
            .store(in: &cancellables)
        NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)
            .sink { [weak self] _ in self?.ingest() }
            .store(in: &cancellables)
        ingest()
        publishNow()
    }

    private func stop() {
        isOn = false
        timer?.invalidate()
        timer = nil
        watcher?.cancel()
        watcher = nil
        publishWork?.cancel()
        ingestWork?.cancel()
        cancellables = []
    }

    /// The Inbox folder changed: ingest once the files have settled (they must be 3 s old).
    private func watch(_ folder: URL) {
        let fd = open(folder.path, O_EVTONLY)
        guard fd >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .rename], queue: .main)
        source.setEventHandler { [weak self] in
            Task { @MainActor in self?.ingestSoon() }
        }
        source.setCancelHandler { close(fd) }
        source.resume()
        watcher = source
    }

    private func ingestSoon() {
        ingestWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.ingest() }
        ingestWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + PhoneBridge.minimumAge + 0.5, execute: work)
    }

    // MARK: In

    /// Brings in what the phone dropped in the Inbox.
    func ingest(now: Date = Date()) {
        guard isOn, let store else { return }
        let voice = voice
        let report = PhoneBridge(root: Self.root).ingest(into: library, now: now, handleTask: { env in
            Self.apply(env, to: store, ledger: voice.ledger, now: now)
        }, handleVoice: { env, audio in
            voice.handleEnvelope(env, attachmentURL: audio)
        })
        problem = report.problems.first
        noteSynced(now)
    }

    /// A task envelope from the phone: "task" adds a task (the due date it carries, or one read from its title
    /// as quick add would), "taskDone" completes one, "taskUndone" reopens it, "taskDelete" deletes it (and the
    /// ledger remembers, so a voice note arriving late doesn't bring it back). True when it's dealt with (a task
    /// that's gone counts).
    @discardableResult
    static func apply(_ env: CaptureEnvelope, to store: Store, ledger: VoiceLedger? = nil, now: Date = Date()) -> Bool {
        switch env.kind {
        case .task:
            let raw = (env.title ?? env.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !raw.isEmpty else { return true }
            var task: TaskItem
            if let due = env.due {
                task = TaskItem(title: raw)
                task.dueHasTime = env.dueHasTime
                task.dueDate = env.dueHasTime ? due : store.calendar.startOfDay(for: due)
                if env.dueHasTime, Prefs.defaultReminder >= 0 {
                    task.reminders = [Reminder(trigger: .beforeDue(minutes: Prefs.defaultReminder), isAlarm: Prefs.defaultReminderIsAlarm)]
                }
            } else {
                let parser = QuickParser(now: now, lists: store.lists, workdayEndMinutes: Prefs.workdayEnd)
                task = TaskItem(parsed: parser.parse(raw), defaultReminder: Prefs.defaultReminder, defaultIsAlarm: Prefs.defaultReminderIsAlarm)
                if task.title.isEmpty { task.title = raw }
            }
            if let text = env.text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty, text != raw { task.notes = text }
            // The phone shows the task under the envelope's id until the next snapshot (an edited voice-note
            // task comes back this way too), so the Mac keeps that id; a repeat or deleted one isn't re-added.
            task.id = env.id
            guard store.task(env.id) == nil, ledger?.isDeleted(env.id) != true else { return true }
            store.addTask(task)
            return true
        case .taskDone:
            if let id = env.taskID, let t = store.task(id), !t.isCompleted { store.setCompleted(id, true) }
            return true
        case .taskUndone:
            if let id = env.taskID, let t = store.task(id), t.isCompleted { store.setCompleted(id, false) }
            return true
        case .taskDelete:
            guard let id = env.taskID else { return true }
            ledger?.markDeleted([id], at: now)
            if store.task(id) != nil { store.deleteTasks([id]) }
            return true
        default:
            return false
        }
    }

    // MARK: Out

    private func schedulePublish() {
        guard isOn else { return }
        publishWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.publishNow() }
        publishWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.publishDelay, execute: work)
    }

    /// Writes the snapshot, vectors and thumbnails for the phone.
    func publishNow() {
        guard isOn, let store else { return }
        guard !publishing else { return schedulePublish() }
        publishing = true
        let now = Date()
        let fromVoice = voice.ledger.taskIDs(since: now.addingTimeInterval(-Self.voiceTaskDays * 86_400))
        let tasks = Self.snapshotTasks(store, now: now, including: fromVoice)
        let lists = store.lists.map(\.name)
        let brain = brain
        Task { @MainActor in
            defer { publishing = false }
            do {
                try await PhoneBridge(root: Self.root).publish(library, tasks: tasks, listNames: lists, now: now, brain: brain)
                problem = nil
                noteSynced(now)
            } catch {
                problem = "Couldn't update the phone's copy: \(error.localizedDescription)"
            }
        }
    }

    /// Tasks made from voice notes in this many days go to the phone whatever their date, so the tasks the
    /// phone showed right after recording don't disappear when the Mac's list comes back.
    static let voiceTaskDays: Double = 14

    /// What the phone's Today shows: open tasks overdue, planned or due from today to 7 days out (plus the open
    /// ones in `including`, whatever their date: tasks from recent voice notes), then the ones finished today.
    /// Ordered by day, undated last; in a day untimed first (as in Calendar), then by time, then priority.
    static func snapshotTasks(_ store: Store, now: Date, including extra: Set<UUID> = []) -> [TaskSnapshot] {
        let cal = store.calendar
        let today = cal.startOfDay(for: now)
        guard let horizon = cal.date(byAdding: .day, value: daysAhead, to: today) else { return [] }
        let open = store.tasks.filter { t in
            guard !t.isCompleted else { return false }
            if extra.contains(t.id) { return true }
            guard let day = t.agendaDay(calendar: cal) else { return false }
            return day <= horizon
        }
        .sorted { a, b in
            let da = a.agendaDay(calendar: cal) ?? .distantFuture, db = b.agendaDay(calendar: cal) ?? .distantFuture
            if da != db { return da < db }
            let ta = a.dueHasTime ? a.dueDate : nil, tb = b.dueHasTime ? b.dueDate : nil
            if ta != tb { return (ta ?? .distantPast) < (tb ?? .distantPast) }
            if a.priority != b.priority { return a.priority > b.priority }
            return a.createdAt < b.createdAt
        }
        let done = store.tasks.filter { t in t.completedAt.map { cal.isDate($0, inSameDayAs: now) } ?? false }
            .sorted { ($0.completedAt ?? now) < ($1.completedAt ?? now) }
        return (open + done).map { t in
            TaskSnapshot(id: t.id, title: t.title, dueDate: t.dueDate, dueHasTime: t.dueHasTime, scheduledDate: t.scheduledDate,
                         estimateMinutes: t.estimateMinutes, priority: t.priority.rawValue, listName: store.list(t.listID)?.name,
                         done: t.isCompleted)
        }
    }

    private func noteSynced(_ date: Date) {
        lastSync = date
        UserDefaults.standard.set(date.timeIntervalSince1970, forKey: Prefs.Key.phoneLastSync)
    }
}
