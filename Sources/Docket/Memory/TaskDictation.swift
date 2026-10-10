import Foundation
import MemoryKit
import SwiftUI

// MARK: - Silence

/// When dictation stops by itself: once something was said, after `pause` with no new words and no loud
/// input. Before the first words it waits (people take a breath before they speak). Pure, so it's tested.
struct DictationSilence: Equatable {
    /// Quiet this long after speech ends it.
    static let pause: TimeInterval = 2
    /// An input level (0…1, `VoiceRecorder.normalized`) at or above this is someone speaking, about -35 dB.
    static let speechLevel: Float = 0.15

    private(set) var heardSpeech = false
    private(set) var lastActivity: Date?
    private var lastText = ""

    /// New words from the recognizer.
    mutating func heard(_ text: String, at date: Date) {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, t != lastText else { return }
        lastText = t
        heardSpeech = true
        lastActivity = date
    }

    /// The input level: loud input after the first words keeps it listening (the recognizer can lag).
    mutating func level(_ level: Float, at date: Date) {
        guard heardSpeech, level >= Self.speechLevel else { return }
        lastActivity = date
    }

    func shouldStop(at date: Date) -> Bool {
        guard heardSpeech, let lastActivity else { return false }
        return date.timeIntervalSince(lastActivity) >= Self.pause
    }
}

// MARK: - Model

/// "Dictate a task" in an add field (the main window's, Quick Capture's Task mode, the menu bar's): the words
/// appear in the field as they're heard; stopping (a click, Return, ⇧⌘D, or a pause) sends them to Gemini,
/// which schedules them (`SpokenTaskParser`), and the tasks are added at once (one ⌘Z, or Undo all) with a
/// compact result under the field. Esc cancels. Without a key the words just stay in the field, for quick add.
@MainActor
final class TaskDictation: ObservableObject {
    enum Phase: Equatable {
        case idle
        case starting
        case listening
        /// Gemini is scheduling it.
        case working
        case result
        /// No key: the words are in the field, for quick add to read.
        case typed
        /// The message is a sentence; `privacy` is the System Settings page that fixes it, if any.
        case failed(String, privacy: URL?)
    }

    /// Which add field it belongs to (the menu bar panel stays open while its own dictation runs).
    enum Place { case main, capture, menuBar }

    /// What the result shows.
    struct Result: Equatable {
        /// The tasks still there (✕ and Undo all take them out).
        var taskIDs: [UUID]
        var made: Int
        var undone = false
    }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var result: Result?
    /// Recent input levels, 0…1, oldest first (the small meter by the field).
    @Published private(set) var levels: [Float] = Array(repeating: 0, count: TaskDictation.levelCount)

    let place: Place
    let intake: VoiceIntake
    /// The clock (tests pin it).
    var now: () -> Date = { Date() }
    /// Says what was added when the field isn't on screen any more (a toast).
    var announce: ((String) -> Void)?
    /// The field is on screen.
    var isShown = false

    static let levelCount = 5
    /// Dictation stops by itself after this long.
    static let maxDuration: TimeInterval = 90

    /// The dictation that started last: one microphone, so a second one starting stops the first, and Esc or
    /// Return reach it wherever the focus is.
    private(set) static weak var current: TaskDictation?

    private var field: Binding<String>?
    private var context = AddContext()
    /// What was typed before listening (the words follow it; Esc puts it back).
    private var typedBefore = ""
    private var words = ""
    private var transcriber: LiveTranscriber?
    private var silence = DictationSilence()
    private var timer: Timer?
    private var startedAt = Date()
    private var work: Task<Void, Never>?

    /// `intake` is the app's (`MemoryCenter`) unless a test brings its own.
    init(place: Place = .main, intake: VoiceIntake? = nil) {
        self.place = place
        self.intake = intake ?? MemoryCenter.shared.voice
    }

    var isListening: Bool { phase == .starting || phase == .listening }
    /// Listening or scheduling: Esc cancels, and a floating panel stays up.
    var isBusy: Bool { isListening || phase == .working }
    /// The add field's own dropdowns make way for what dictation shows.
    var showsStatus: Bool { phase != .idle && phase != .typed }

    // MARK: Listening

    /// Starts listening; the words go into `field` (after what's typed there). `context` is what the page gives
    /// a new task (its list, its day…), as with typing.
    func start(field: Binding<String>, context: AddContext) {
        guard !isBusy else { return }
        if let other = Self.current, other !== self, other.isListening { other.cancel() }
        Self.current = self
        self.field = field
        self.context = context
        typedBefore = field.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines)
        words = ""
        result = nil
        phase = .starting
        // Screenshots: listening without the microphone (`debugHear` brings the words).
        if DebugSnapshot.isActive {
            phase = .listening
            return
        }
        Task {
            do {
                try await VoicePermissions.microphone()
                guard await VoicePermissions.speech() else { throw VoiceError.speechDenied }
                // Cancelled while macOS asked.
                guard phase == .starting else { return }
                let live = LiveTranscriber()
                live.onText = { [weak self] text in self?.heard(text) }
                live.onLevel = { [weak self] level in self?.level(level) }
                try live.start()
                transcriber = live
                begin()
            } catch {
                guard phase == .starting else { return }
                let e = error as? VoiceError ?? .couldNotStart(error.localizedDescription)
                let privacy: URL? = e == .micDenied ? VoiceError.microphoneSettingsURL : e == .speechDenied ? VoiceError.speechSettingsURL : nil
                phase = .failed(e.errorDescription ?? "Couldn't listen.", privacy: privacy)
            }
        }
    }

    private func begin() {
        silence = DictationSilence()
        levels = Array(repeating: 0, count: Self.levelCount)
        startedAt = Date()
        phase = .listening
        let t = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func tick() {
        guard phase == .listening else { return }
        let date = Date()
        if silence.shouldStop(at: date) || date.timeIntervalSince(startedAt) > Self.maxDuration { finish() }
    }

    private func heard(_ text: String) {
        guard phase == .listening else { return }
        words = text.trimmingCharacters(in: .whitespacesAndNewlines)
        field?.wrappedValue = Self.combine(typedBefore, words)
        silence.heard(text, at: Date())
    }

    private func level(_ level: Float) {
        guard phase == .listening else { return }
        levels.removeFirst()
        levels.append(level)
        silence.level(level, at: Date())
    }

    /// "Call Rohan" typed, "Friday at 3" said: "Call Rohan Friday at 3".
    static func combine(_ typed: String, _ spoken: String) -> String {
        [typed, spoken].filter { !$0.isEmpty }.joined(separator: " ")
    }

    /// Stops listening and schedules what's in the field (a click, Return, ⇧⌘D or a pause).
    func finish() {
        guard isListening else { return }
        let wasStarting = phase == .starting
        stopListening()
        guard !wasStarting, !words.isEmpty else {
            field?.wrappedValue = typedBefore
            phase = wasStarting ? .idle : .failed(DictationText.nothingHeard, privacy: nil)
            return
        }
        submit(field?.wrappedValue ?? Self.combine(typedBefore, words))
    }

    /// Esc: listening stops and the field goes back to what was typed; scheduling stops and the words stay.
    func cancel() {
        switch phase {
        case .starting, .listening:
            stopListening()
            field?.wrappedValue = typedBefore
            phase = .idle
        case .working:
            work?.cancel()
            work = nil
            phase = .idle
        default:
            break
        }
    }

    /// Esc anywhere: cancels what's running, else closes the result or message. True when there was something.
    @discardableResult
    func escape() -> Bool {
        if isBusy {
            cancel()
            return true
        }
        guard phase != .idle else { return false }
        dismiss()
        return true
    }

    private func stopListening() {
        timer?.invalidate()
        timer = nil
        transcriber?.stop()
        transcriber = nil
        levels = Array(repeating: 0, count: Self.levelCount)
    }

    // MARK: Scheduling

    /// Sends the words to Gemini and adds what it makes. Without a key they stay in the field as text.
    func submit(_ text: String) {
        let spoken = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !spoken.isEmpty else {
            phase = .idle
            return
        }
        guard let ai = intake.ai(), let store = intake.store else {
            field?.wrappedValue = spoken
            phase = .typed
            return
        }
        phase = .working
        let parser = SpokenTaskParser(ai: ai, listNames: store.lists.map(\.name),
                                      knownPeople: intake.library.people().prefix(60).map(\.name))
        let at = now()
        // Holds on to the model until it's done, so tasks asked for are added even if the field went away.
        work = Task {
            do {
                let tasks = try await parser.parse(spoken, now: at)
                guard !Task.isCancelled, phase == .working else { return }
                guard !tasks.isEmpty else {
                    phase = .failed(DictationText.noTask, privacy: nil)
                    return
                }
                add(tasks, at: at)
            } catch {
                guard !Task.isCancelled, phase == .working else { return }
                let e = error as? MemoryAIError ?? .network(error.localizedDescription)
                phase = .failed(DictationText.failed(e), privacy: nil)
            }
            work = nil
        }
    }

    /// Returns once Gemini has answered (tests).
    func waitUntilScheduled() async {
        await work?.value
    }

    /// Adds the scheduled tasks (one undo step; ids already there or deleted are skipped) and shows them.
    @discardableResult
    func add(_ spoken: [DebriefTask], at date: Date) -> [UUID] {
        guard let store = intake.store else { return [] }
        var seen = Set<UUID>()
        let fresh = spoken.filter { t in
            seen.insert(t.id).inserted && store.task(t.id) == nil && !intake.ledger.isDeleted(t.id)
                && !t.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        let tasks = fresh.map { Self.task(from: $0, context: context, store: store, now: date) }
        withAnimation(Motion.gentle) {
            _ = store.addTasks(tasks, undo: tasks.count == 1 ? "Add Dictated Task" : "Add Dictated Tasks")
        }
        let ids = tasks.map(\.id)
        intake.ledger.noteAdded(ids, at: date)
        field?.wrappedValue = ""
        result = Result(taskIDs: ids, made: ids.count)
        phase = .result
        if !ids.isEmpty { Haptics.success() }
        if !isShown, let first = tasks.first { announce?(DictationText.toast(first, count: tasks.count, now: date)) }
        return ids
    }

    /// A dictated task as the Store task: `VoiceIntake.task(from:)`, then what wasn't said comes from the page,
    /// as when typing (its list, its tag, Important's priority, the Calendar's day as the plan day).
    static func task(from t: DebriefTask, context: AddContext, store: Store, now: Date,
                     defaultReminder: Int = Prefs.defaultReminder, defaultIsAlarm: Bool = Prefs.defaultReminderIsAlarm,
                     allDayHour: Int = Prefs.allDayHour) -> TaskItem {
        var task = VoiceIntake.task(from: t, recordedAt: now, store: store, fromVoiceNote: false, defaultReminder: defaultReminder,
                                    defaultIsAlarm: defaultIsAlarm, allDayHour: allDayHour)
        let cal = store.calendar
        if task.listID == nil, let id = context.listID, store.lists.contains(where: { $0.id == id }) { task.listID = id }
        if let tag = context.tag?.trimmingCharacters(in: .whitespaces), !tag.isEmpty,
           !task.tags.contains(where: { $0.caseInsensitiveCompare(tag) == .orderedSame }) {
            task.tags.append(tag)
        }
        task.priority = max(task.priority, context.minimumPriority)
        if task.dueDate == nil, task.scheduledDate == nil, let day = context.day {
            task.scheduledDate = max(cal.startOfDay(for: day), cal.startOfDay(for: now))
        }
        return task
    }

    // MARK: The result

    /// ✕ on one task: it goes, and stays gone (a copy from the phone won't bring it back).
    func remove(_ taskID: UUID) {
        guard var r = result, r.taskIDs.contains(taskID) else { return }
        intake.deleteTasks([taskID])
        r.taskIDs.removeAll { $0 == taskID }
        if r.taskIDs.isEmpty { r.undone = true }
        result = r
    }

    /// Undo all: every task it added goes.
    func undoAll() {
        guard var r = result, !r.taskIDs.isEmpty else { return }
        intake.deleteTasks(r.taskIDs)
        r.taskIDs = []
        r.undone = true
        result = r
    }

    /// Closes the result or the message (the tasks stay).
    func dismiss() {
        guard !isBusy else { return }
        phase = .idle
        result = nil
    }

    // MARK: Screenshots

    /// Words "heard" without the microphone, with a made-up level.
    func debugHear(_ text: String, levels: [Float]) {
        guard phase == .listening else { return }
        words = text
        field?.wrappedValue = Self.combine(typedBefore, text)
        self.levels = Array((Array(repeating: 0, count: Self.levelCount) + levels).suffix(Self.levelCount))
    }

    /// The end of a dictation, with tasks made here instead of by Gemini.
    func debugSchedule(_ tasks: [DebriefTask]) {
        stopListening()
        phase = .working
        add(tasks, at: now())
    }
}

// MARK: - Words

/// What dictation says (kept here so it's easy to test).
enum DictationText {
    static let nothingHeard = "Docket didn't hear anything. Click the mic and try again."
    static let noTask = "Gemini didn't find a task in that. Your words are in the field: edit them, or press Return to add them as typed."
    static let noKeyHint = "Add a Gemini key in Settings → AI and Docket schedules what you say. For now Return adds it as typed."
    static let listening = "↩ done · esc cancel · stops when you pause"
    static let sayHint = "Say it: “Call Rohan Friday at 3 for half an hour, remind me 15 minutes before”"

    static func failed(_ error: MemoryAIError) -> String {
        "Gemini couldn't schedule it (\(error.errorDescription ?? "unknown error")). Your words are in the field: press Return to add them as typed."
    }

    /// "Added 1 task", "Added 2 tasks".
    static func headline(tasks n: Int) -> String { "Added \(Fmt.plural(n, "task"))" }

    /// The quiet line under a task in the result: reminder or alarm, repeat, "Do on", list, priority, waiting on.
    /// (The date and length are on the right.)
    static func details(_ t: TaskItem, listName: String?, now: Date = Date()) -> [AddExtra] {
        var items: [AddExtra] = []
        if let reminder = AddOptions.reminderSummary(t) {
            items.append(AddExtra(icon: t.hasAlarm ? "alarm" : "bell", text: t.hasAlarm ? "Alarm \(reminder.lowercasedFirst)" : reminder))
        }
        if let rule = t.recurrence { items.append(AddExtra(icon: "repeat", text: rule.summary)) }
        // Without a deadline the "Do on" day is the date on the right.
        if let day = t.scheduledDate, t.dueDate != nil { items.append(AddExtra(icon: "calendar", text: "Do on \(Fmt.absoluteDay(day, now: now))")) }
        if let listName { items.append(AddExtra(icon: "list.bullet", text: listName)) }
        if t.priority != .none { items.append(AddExtra(icon: "flag", text: t.priority.label)) }
        if let waiting = t.waitingOn { items.append(AddExtra(icon: "person", text: "Waiting on \(waiting)")) }
        return items
    }

    /// The date on the right: the deadline ("Fri 16 Oct · 15:00"), else the "Do on" day, else "No date".
    static func when(_ t: TaskItem, now: Date = Date()) -> String {
        if let due = t.dueDate { return Fmt.due(due, hasTime: t.dueHasTime, now: now) }
        return t.scheduledDate.map { Fmt.absoluteDay($0, now: now) } ?? "No date"
    }

    /// "Added “Call Rohan” for Fri 16 Oct · 15:00", or "Added 2 tasks, from “Call Rohan”".
    static func toast(_ first: TaskItem, count: Int, now: Date = Date()) -> String {
        guard count == 1 else { return "Added \(Fmt.plural(count, "task")), from “\(first.title)”" }
        guard let due = first.dueDate else { return "Added “\(first.title)”" }
        return "Added “\(first.title)” for \(Fmt.due(due, hasTime: first.dueHasTime, now: now))"
    }
}

private extension String {
    var lowercasedFirst: String { prefix(1).lowercased() + dropFirst() }
}
