import Combine
import Foundation
import MemoryKit

// MARK: - Ledger

/// What Docket remembers about voice notes beside the memories themselves, in `<library>/voice.json`:
/// which tasks each voice note made (so its memory can list them, and the phone's task list can include
/// them), the tasks dictated or added on the phone (the phone's list includes those too), and the ids of
/// voice tasks that were deleted (so a late or repeated envelope never brings one back).
@MainActor
final class VoiceLedger: ObservableObject {
    struct Entry: Codable, Hashable {
        var itemID: UUID
        var taskIDs: [UUID]
        var createdAt: Date
    }

    private struct FileContents: Codable {
        var entries: [Entry] = []
        var deleted: [UUID: Date] = [:]
        var added: [UUID: Date] = [:]

        init(entries: [Entry], deleted: [UUID: Date], added: [UUID: Date]) {
            self.entries = entries
            self.deleted = deleted
            self.added = added
        }

        private enum CodingKeys: String, CodingKey { case entries, deleted, added }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            entries = c.value(.entries, default: [])
            deleted = c.value(.deleted, default: [:])
            added = c.value(.added, default: [:])
        }
    }

    let fileURL: URL
    @Published private(set) var entries: [Entry] = []
    private(set) var deleted: [UUID: Date] = [:]
    /// Tasks dictated here or added on the phone, and when (kept as long as deleted ids).
    private(set) var added: [UUID: Date] = [:]

    /// Deleted ids are kept this long (long after any envelope could still arrive).
    static let deletedKeep: TimeInterval = 90 * 86_400

    init(fileURL: URL) {
        self.fileURL = fileURL
        if let data = try? Data(contentsOf: fileURL), let file = try? MemoryCoding.decoder.decode(FileContents.self, from: data) {
            entries = file.entries
            deleted = file.deleted
            added = file.added
        }
    }

    func isDeleted(_ taskID: UUID) -> Bool { deleted[taskID] != nil }

    func markDeleted(_ ids: [UUID], at date: Date = Date()) {
        guard !ids.isEmpty else { return }
        for id in ids { deleted[id] = date }
        save()
    }

    /// Records tasks scheduled by dictation or from the phone, so the phone's list shows them whatever their date.
    func noteAdded(_ ids: [UUID], at date: Date = Date()) {
        guard !ids.isEmpty else { return }
        for id in ids { added[id] = date }
        save()
    }

    /// Records the tasks a voice note made (added to what's already recorded for it).
    func link(item itemID: UUID, tasks taskIDs: [UUID], at date: Date = Date()) {
        if let i = entries.firstIndex(where: { $0.itemID == itemID }) {
            entries[i].taskIDs += taskIDs.filter { !entries[i].taskIDs.contains($0) }
        } else {
            entries.append(Entry(itemID: itemID, taskIDs: taskIDs, createdAt: date))
        }
        save()
    }

    /// The tasks a voice note made, in the order spoken (some may have been deleted since).
    func taskIDs(for itemID: UUID) -> [UUID] {
        entries.first { $0.itemID == itemID }?.taskIDs ?? []
    }

    /// The voice note a task came from.
    func itemID(forTask taskID: UUID) -> UUID? {
        entries.first { $0.taskIDs.contains(taskID) }?.itemID
    }

    /// Tasks from voice notes, dictation and the phone made since `date`.
    func taskIDs(since date: Date) -> Set<UUID> {
        Set(entries.filter { $0.createdAt >= date }.flatMap(\.taskIDs)).union(added.filter { $0.value >= date }.keys)
    }

    private func save() {
        let cutoff = Date().addingTimeInterval(-Self.deletedKeep)
        deleted = deleted.filter { $0.value >= cutoff }
        added = added.filter { $0.value >= cutoff }
        let file = FileContents(entries: entries, deleted: deleted, added: added)
        do {
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try MemoryCoding.encoder.encode(file).write(to: fileURL, options: .atomic)
        } catch {
            NSLog("Docket: couldn't save voice.json: \(error.localizedDescription)")
        }
    }
}

// MARK: - Outcome

/// What one voice note turned into.
struct VoiceOutcome: Equatable {
    /// The memory of it.
    var itemID: UUID
    /// Tasks made just now, in the order spoken (ids already there or deleted are left out).
    var taskIDs: [UUID]
    var debrief: VoiceDebrief
    /// The debrief came from Gemini (not the fallback).
    var processed: Bool
    /// Why the fallback was used, in a sentence (no key, Gemini failed); nil when AI worked.
    var notice: String?
}

// MARK: - Intake

/// Turns voice notes into tasks and a memory, whoever recorded them:
/// - **From the phone** (`handleEnvelope`): a debrief made on the phone is applied as is; without one Docket
///   asks Gemini here (in the background, the files stay in the Inbox meanwhile), and with no key, or after
///   Gemini keeps failing, it falls back to `VoiceDebrief.unprocessed`, so a debrief is never dropped.
/// - **On the Mac** (`processRecording`): the same, straight away.
/// Tasks keep the debrief's ids, so applying the same debrief twice changes nothing, and a task deleted on
/// the phone (`taskDelete`) or from the result card never comes back.
@MainActor
final class VoiceIntake {
    let library: MemoryLibrary
    private(set) weak var store: Store?
    let ledger: VoiceLedger
    /// The AI to debrief with (nil without a key).
    var ai: () -> MemoryAI?
    /// Called after a phone voice note was applied (the app notifies).
    var onApplied: ((VoiceOutcome) -> Void)?
    /// Called when a debrief finished in the background and its envelope can be ingested now.
    var onReady: (() -> Void)?
    /// The clock (tests pin it).
    var now: () -> Date = { Date() }

    /// Debriefs that finished in the background, waiting for their envelope's next pass.
    private var finished: [UUID: (debrief: VoiceDebrief, processed: Bool, notice: String?)] = [:]
    private var running: [UUID: Task<Void, Never>] = [:]
    private var attempts: [UUID: Int] = [:]

    /// Gemini answered but not usefully: how many tries before the fallback.
    static let maxFailedAttempts = 2
    /// Offline or busy: how long a phone recording waits for Gemini before the fallback.
    static let transientPatience: TimeInterval = 24 * 3600

    init(library: MemoryLibrary, store: Store?, ledger: VoiceLedger? = nil, ai: @escaping () -> MemoryAI? = { nil }) {
        self.library = library
        self.store = store
        self.ledger = ledger ?? VoiceLedger(fileURL: library.directory.appendingPathComponent("voice.json"))
        self.ai = ai
    }

    func attach(store: Store) {
        self.store = store
    }

    // MARK: Applying

    /// Creates the debrief's tasks (same ids; ones already there or deleted are skipped) and its memory, with
    /// the recording attached (moved in when `moveAudio`). Nothing is created twice: a memory with this
    /// `sourceRef` already there means it was applied before. Throws when the recording can't be stored.
    @discardableResult
    func apply(_ debrief: VoiceDebrief, audio: URL?, moveAudio: Bool, sourceRef: String, origin: MemoryOrigin,
               capturedFrom: String, processed: Bool, notice: String? = nil) throws -> VoiceOutcome {
        if let existing = library.item(sourceRef: sourceRef) {
            return VoiceOutcome(itemID: existing.id, taskIDs: [], debrief: debrief, processed: processed, notice: notice)
        }
        // The memory first: if the recording can't be stored, nothing is half done.
        let stamp = now()
        var item = debrief.memoryItem(sourceRef: sourceRef, origin: origin, capturedFrom: capturedFrom, processed: processed, now: stamp)
        if let audio, FileManager.default.fileExists(atPath: audio.path) {
            let stored = try library.addFile(at: audio, kind: .audio, name: Self.audioName(debrief.recordedAt, ext: audio.pathExtension),
                                             origin: origin, sourceRef: sourceRef, capturedFrom: capturedFrom,
                                             createdAt: debrief.recordedAt, move: moveAudio)
            // addFile made a bare item around the recording: fill it in with the debrief.
            item.id = stored.id
            item.attachments = stored.attachments
            library.update(item)
        } else {
            item = library.add(item)
        }
        let made = makeTasks(debrief)
        ledger.link(item: item.id, tasks: debrief.tasks.map(\.id).filter { store?.task($0) != nil }, at: stamp)
        return VoiceOutcome(itemID: item.id, taskIDs: made, debrief: debrief, processed: processed, notice: notice)
    }

    /// "Voice note Fri 9 Oct 16.10.m4a"
    static func audioName(_ date: Date, ext: String) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_GB")
        f.dateFormat = "EEE d MMM HH.mm"
        return "Voice note \(f.string(from: date)).\(ext.isEmpty ? "m4a" : ext)"
    }

    /// The debrief's tasks as Store tasks, minus the ones that exist or were deleted. Returns the new ids.
    private func makeTasks(_ debrief: VoiceDebrief) -> [UUID] {
        guard let store else { return [] }
        var seen = Set<UUID>()
        let fresh = debrief.tasks.filter { t in
            seen.insert(t.id).inserted && store.task(t.id) == nil && !ledger.isDeleted(t.id)
                && !t.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        let tasks = fresh.map { Self.task(from: $0, recordedAt: debrief.recordedAt, store: store) }
        store.addTasks(tasks, undo: tasks.count == 1 ? "Add Task from Voice Note" : "Add Tasks from Voice Note")
        return tasks.map(\.id)
    }

    /// One Store task for a debrief task (a voice note's, a dictated one, or the phone's): same id, the list by
    /// name, and everything it was scheduled with. A voice note's tasks say where they came from in their notes.
    /// - The deadline (or time slot) is the task's due date; "Do on" is only its plan day and never moves it.
    /// - A repeat without a date starts on its first day from `recordedAt`.
    /// - Reminder: the minutes asked for (0 = at the time), an alarm when asked; nothing asked (nil) means the
    ///   app's default, and only for a task with a time; below 0 means none at all. Without a deadline, a
    ///   reminder rings on the "Do on" day.
    static func task(from t: DebriefTask, recordedAt: Date, store: Store, fromVoiceNote: Bool = true,
                     defaultReminder: Int = Prefs.defaultReminder, defaultIsAlarm: Bool = Prefs.defaultReminderIsAlarm,
                     allDayHour: Int = Prefs.allDayHour) -> TaskItem {
        let cal = store.calendar
        var task = TaskItem(title: t.title.trimmingCharacters(in: .whitespacesAndNewlines))
        task.id = t.id
        task.notes = fromVoiceNote ? VoiceText.taskNotes(t.notes, recordedAt: recordedAt)
                                   : t.notes.trimmingCharacters(in: .whitespacesAndNewlines)
        if let due = t.dueDate {
            task.dueHasTime = t.dueHasTime
            task.dueDate = t.dueHasTime ? due : cal.startOfDay(for: due)
        }
        if let rule = t.repeatRule {
            let recurrence = Recurrence(rule)
            task.recurrence = recurrence
            if task.dueDate == nil {
                task.dueDate = recurrence.firstOccurrence(onOrAfter: recordedAt, calendar: cal)
                task.dueHasTime = false
            }
        }
        if let doOn = t.scheduledDate { task.scheduledDate = cal.startOfDay(for: doOn) }

        // Below 0: "no reminder" was picked (the phone's "None"), so not even the default.
        let asked = t.reminderMinutes.map { max(0, $0) }
        if let minutes = t.reminderMinutes, minutes < 0 {
            task.reminders = []
        } else if task.dueDate != nil {
            if let minutes = asked {
                task.reminders = [Reminder(trigger: .beforeDue(minutes: minutes), isAlarm: t.isAlarm)]
            } else if t.isAlarm {
                // "Alarm" with no time to it: the default lead for a timed task, the all-day hour otherwise.
                task.reminders = [Reminder(trigger: .beforeDue(minutes: task.dueHasTime ? max(0, defaultReminder) : 0), isAlarm: true)]
            } else if task.dueHasTime, defaultReminder >= 0 {
                task.reminders = [Reminder(trigger: .beforeDue(minutes: defaultReminder), isAlarm: defaultIsAlarm)]
            }
        } else if let doOn = task.scheduledDate, asked != nil || t.isAlarm,
                  let morning = cal.date(bySettingHour: allDayHour, minute: 0, second: 0, of: doOn) {
            task.reminders = [Reminder(trigger: .absolute(morning.addingTimeInterval(-Double(asked ?? 0) * 60)), isAlarm: t.isAlarm)]
        }

        if let minutes = t.estimateMinutes, minutes > 0 { task.estimateMinutes = minutes }
        task.priority = Priority(rawValue: max(0, min(4, t.priority))) ?? .none
        if let waiting = t.waitingOn?.trimmingCharacters(in: .whitespacesAndNewlines), !waiting.isEmpty { task.waitingOn = waiting }
        task.listID = list(named: t.listName, in: store.lists)?.id
        for tag in t.tags {
            let clean = tag.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if !clean.isEmpty, !task.tags.contains(clean) { task.tags.append(clean) }
        }
        return task
    }

    /// The list called exactly `name` (else the one matching without case), nil for the Inbox.
    static func list(named name: String?, in lists: [TaskList]) -> TaskList? {
        guard let name = name?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty else { return nil }
        return lists.first { $0.name == name } ?? lists.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }
    }

    // MARK: Removing

    /// ✕ on the result card, or a `taskDelete` from the phone: the task goes, and stays gone.
    func deleteTasks(_ ids: [UUID]) {
        guard !ids.isEmpty else { return }
        ledger.markDeleted(ids, at: now())
        store?.deleteTasks(Set(ids))
    }

    // MARK: From the phone

    /// A voice envelope from the Inbox. True when it's been applied (its files can go); false while Gemini is
    /// still on it (or will try again on a later pass).
    func handleEnvelope(_ env: CaptureEnvelope, attachmentURL: URL?) -> Bool {
        let ref = SourceRef.phone(env.id)
        if library.item(sourceRef: ref) != nil {
            finished[env.id] = nil
            return true
        }
        let from = env.device?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false ? env.device! : "iPhone"
        func applyNow(_ debrief: VoiceDebrief, processed: Bool, notice: String?) -> Bool {
            do {
                let outcome = try apply(debrief, audio: attachmentURL, moveAudio: true, sourceRef: ref, origin: .phone,
                                        capturedFrom: from, processed: processed, notice: notice)
                finished[env.id] = nil
                attempts[env.id] = nil
                onApplied?(outcome)
                return true
            } catch {
                return false
            }
        }
        // The phone sends a debrief only when Gemini made it there.
        if let debrief = env.debrief { return applyNow(debrief, processed: true, notice: nil) }
        if let ready = finished[env.id] { return applyNow(ready.debrief, processed: ready.processed, notice: ready.notice) }
        guard let ai = ai() else {
            return applyNow(.unprocessed(transcript: env.transcript, recordedAt: env.createdAt), processed: false,
                            notice: VoiceText.noKeyNotice)
        }
        guard running[env.id] == nil else { return false }
        let debriefer = makeDebriefer(ai)
        let audio = Self.audioPart(attachmentURL)
        let transcript = env.transcript
        let recordedAt = env.createdAt
        let id = env.id
        running[id] = Task { [weak self] in
            let result: Result<VoiceDebrief, Error>
            do {
                result = .success(try await debriefer.debrief(audio: audio, liveTranscript: transcript, recordedAt: recordedAt, madeBy: "Mac"))
            } catch {
                result = .failure(error)
            }
            guard let self else { return }
            self.running[id] = nil
            switch result {
            case .success(let debrief):
                self.finished[id] = (debrief, true, nil)
            case .failure(let error):
                let e = error as? MemoryAIError ?? .network(error.localizedDescription)
                let tries = (self.attempts[id] ?? 0) + 1
                self.attempts[id] = tries
                // Offline or busy: try again on a later pass, for up to a day. Anything else (a refused key, an
                // answer that makes no sense, nothing in the recording): the fallback after a second try.
                let waitedTooLong = self.now().timeIntervalSince(recordedAt) > Self.transientPatience
                let giveUp = waitedTooLong || (!e.isTransient && tries >= Self.maxFailedAttempts)
                guard giveUp else { return }
                self.finished[id] = (.unprocessed(transcript: transcript, recordedAt: recordedAt), false, e.errorDescription)
            }
            self.onReady?()
        }
        return false
    }

    /// Returns when no debrief is running (tests).
    func waitForDebriefs() async {
        while let task = running.values.first { await task.value }
    }

    // MARK: On the Mac

    /// A recording made on the Mac: debriefed with Gemini when there's a key (the fallback otherwise, or when
    /// Gemini fails), then tasks and memory. The recording is moved into the library. Throws only when the
    /// recording can't be stored.
    func processRecording(_ file: URL, liveTranscript: String, recordedAt: Date) async throws -> VoiceOutcome {
        let ref = SourceRef.voice(UUID())
        var debrief = VoiceDebrief.unprocessed(transcript: liveTranscript, recordedAt: recordedAt, madeBy: "Mac")
        var processed = false
        var notice: String? = VoiceText.noKeyNotice
        if let ai = ai() {
            do {
                debrief = try await makeDebriefer(ai).debrief(audio: Self.audioPart(file), liveTranscript: liveTranscript,
                                                             recordedAt: recordedAt, madeBy: "Mac")
                processed = true
                notice = nil
            } catch {
                let e = error as? MemoryAIError ?? .network(error.localizedDescription)
                notice = VoiceText.failedNotice(e)
            }
        }
        return try apply(debrief, audio: file, moveAudio: true, sourceRef: ref, origin: .manual, capturedFrom: "Mac",
                         processed: processed, notice: notice)
    }

    private func makeDebriefer(_ ai: MemoryAI) -> VoiceDebriefer {
        VoiceDebriefer(ai: ai, profile: library.profile, lenses: library.lenses,
                       listNames: store?.lists.map(\.name) ?? [], knownPeople: library.people().prefix(60).map(\.name))
    }

    /// The recording as a part Gemini can hear (nil when missing or too big to send).
    nonisolated static func audioPart(_ url: URL?) -> MemoryInlinePart? {
        guard let url, let data = try? Data(contentsOf: url, options: .mappedIfSafe), !data.isEmpty,
              data.count <= MemoryInlinePart.maxBytes else { return nil }
        return MemoryInlinePart(mimeType: MimeType.forExtension(url.pathExtension), data: data)
    }
}

// MARK: - Repeat rules

extension Recurrence {
    /// A repeat rule from the phone or Gemini (same numbers: 1 = Sunday … 7 = Saturday).
    init(_ rule: TaskRepeat) {
        let frequency = Frequency(rawValue: rule.frequency.rawValue) ?? .weekly
        self.init(frequency: frequency, interval: rule.interval, weekdays: frequency == .weekly ? rule.weekdays : [])
    }

    /// The same rule for the phone.
    var taskRepeat: TaskRepeat {
        TaskRepeat(frequency: TaskRepeat.Frequency(rawValue: frequency.rawValue) ?? .weekly, interval: interval, weekdays: weekdays)
    }
}

// MARK: - Words

/// The words voice notes use (kept here so they're easy to test).
enum VoiceText {
    static let noKeyNotice = "No Gemini key, so Docket saved the recording with a task to go through it."

    static func failedNotice(_ error: MemoryAIError) -> String {
        "Gemini couldn't work on it (\(error.errorDescription ?? "unknown error")), so Docket saved the recording with a task to go through it."
    }

    /// "From your voice note, Fri 9 Oct · 16:10" and the task's own line of context under it.
    static func taskNotes(_ notes: String, recordedAt: Date, now: Date = Date()) -> String {
        let head = "From your voice note, \(Fmt.due(recordedAt, hasTime: true, now: now))"
        let extra = notes.trimmingCharacters(in: .whitespacesAndNewlines)
        return extra.isEmpty ? head : head + "\n\n" + extra
    }

    /// "Added 3 tasks", "Added 1 task", "Saved to Memory".
    static func headline(tasks n: Int) -> String {
        n == 0 ? "Saved to Memory" : "Added \(Fmt.plural(n, "task"))"
    }

    /// The task's date as the result card shows it: "Fri 16 Oct", "Fri 16 Oct · 15:00", or "No date".
    static func when(_ task: TaskItem, now: Date = Date()) -> String {
        guard let due = task.dueDate else { return "No date" }
        return Fmt.due(due, hasTime: task.dueHasTime, now: now)
    }

    /// The notification for a voice note from the phone: "3 tasks from your voice note" over the first titles
    /// ("Send revised quote to Rohan Mehta…"). Nil when it made no tasks.
    static func notification(tasks: [TaskItem]) -> (title: String, body: String)? {
        guard let first = tasks.first else { return nil }
        let title = "\(Fmt.plural(tasks.count, "task")) from your voice note"
        var body = first.title + (first.dueDate.map { " · " + Fmt.due($0, hasTime: first.dueHasTime) } ?? "")
        if tasks.count == 2 { body += "\n" + tasks[1].title }
        if tasks.count > 2 { body += "\n" + tasks[1].title + " and \(tasks.count - 2) more" }
        return (title, body)
    }

    /// An answer as it should be read aloud: no [n] citation markers, no doubled spaces.
    static func speakable(_ text: String) -> String {
        var out = ""
        for segment in CitationText.segments(text) {
            if case .text(let s) = segment { out += s }
        }
        out = out.replacingOccurrences(of: #"[ \t]+([.,;:!?])"#, with: "$1", options: .regularExpression)
        out = out.replacingOccurrences(of: #"[ \t]{2,}"#, with: " ", options: .regularExpression)
        return out.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
