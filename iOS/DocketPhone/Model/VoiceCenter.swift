import Combine
import Foundation
import MemoryKit
import Network
import SwiftUI
import UIKit

/// One recorded debrief on its way to the Mac. Lives in `Documents/Voice/` (the audio as `<id>.aac`, the
/// list in `jobs.json`) until it's written to the Docket folder, then a little longer so its tasks can show
/// in Today until the Mac's task list has them.
struct VoiceJob: Codable, Identifiable, Equatable {
    enum Status: String, Codable {
        /// Still being recorded (on disk from the first second, so a crash keeps it).
        case recording
        /// Gemini is turning it into tasks.
        case processing
        /// Debriefed; held a moment so edits on the result card are free.
        case ready
        /// Couldn't reach Gemini; tried again when the network comes back.
        case offline
        /// Written without a debrief (no key, Gemini refused, or offline for 30 minutes): the Mac does it.
        case handedToMac
        /// Written with its debrief.
        case written
    }

    var id: UUID
    var recordedAt: Date
    var duration: TimeInterval
    /// "Voice note 2026-10-09 10.42.05.aac"
    var attachmentName: String
    /// On-device, rough.
    var transcript: String
    var debrief: VoiceDebrief?
    var status: Status
    /// Gemini's problem in a sentence, when there was one.
    var message: String?
    var lastAttempt: Date?
    /// Not written before this (the result card's grace period); nil = as soon as it's ready.
    var commitAfter: Date?
    var writtenAt: Date?
    /// When the phone saw the Mac take it from the Inbox.
    var macReceivedAt: Date?
    /// Tasks removed after it was written (a taskDelete went out); hidden here.
    var deletedTaskIDs: [UUID] = []

    var isWritten: Bool { writtenAt != nil }

    /// The tasks still in it.
    var tasks: [DebriefTask] {
        (debrief?.tasks ?? []).filter { !deletedTaskIDs.contains($0.id) }
    }
}

/// Recording, debriefing and delivering voice notes. After a recording stops: with a key and a network,
/// Gemini turns it into a debrief in seconds and the result card shows it; the capture is held while the
/// card is open (and 20 s after it was shown) so edits cost nothing, then written to the Docket folder
/// with the audio, the on-device transcript and the debrief. Offline, it waits and retries when the network
/// returns, and after 30 minutes goes to the Mac without a debrief. Without a key it goes at once.
/// The audio never leaves `Documents/Voice` except into Pending/the Inbox.
@MainActor
final class VoiceCenter: ObservableObject {
    let recorder = VoiceRecorder()

    @Published private(set) var jobs: [VoiceJob] = []
    /// The job the result card shows.
    @Published private(set) var cardID: UUID?
    @Published private(set) var isOnline = true

    weak var model: AppModel?

    /// Edits are free for this long after the card first shows (or while it's open).
    static let holdSeconds: TimeInterval = 20
    /// Offline this long after recording: hand it to the Mac without a debrief.
    static let giveUpAfter: TimeInterval = 30 * 60
    /// Between automatic retries while online.
    static let retryEvery: TimeInterval = 60

    let folder: URL
    private var jobsURL: URL { folder.appendingPathComponent("jobs.json") }
    private let isDemo: Bool
    private var recordingID: UUID?
    private var cardShownAt: Date?
    private let monitor = NWPathMonitor()
    private var sweepTask: Task<Void, Never>?
    private var cancellables: Set<AnyCancellable> = []
    private var processing: Set<UUID> = []

    init(local: LocalStore, isDemo: Bool) {
        folder = local.root.appendingPathComponent("Voice", isDirectory: true)
        self.isDemo = isDemo
        // Demo mode starts clean (its folder is a throwaway that's reset on every launch).
        jobs = isDemo ? [] : Self.load(jobsURL: folder.appendingPathComponent("jobs.json"))
        recorder.$autoStopped.removeDuplicates().filter { $0 }.sink { [weak self] _ in
            Task { await self?.stopRecording() }
        }.store(in: &cancellables)
        if !isDemo {
            monitor.pathUpdateHandler = { [weak self] path in
                let online = path.status == .satisfied
                Task { @MainActor in self?.networkChanged(online) }
            }
            monitor.start(queue: DispatchQueue(label: "docket.network"))
        }
    }

    deinit { monitor.cancel() }

    func audioURL(_ id: UUID) -> URL { folder.appendingPathComponent("\(id.uuidString).aac") }

    func job(_ id: UUID) -> VoiceJob? { jobs.first { $0.id == id } }

    var card: VoiceJob? { cardID.flatMap(job) }

    // MARK: Launch

    /// After launch: a recording that was cut short by a crash is finished and processed; anything that was
    /// mid-debrief or waiting is tried again.
    func resumeAfterLaunch() async {
        for job in jobs where job.status == .recording && job.id != recordingID {
            let url = audioURL(job.id)
            if let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.intValue, size > 0 {
                // ~32 kbps → 4 kB a second.
                update(job.id) {
                    $0.status = .processing
                    $0.duration = max($0.duration, Double(size) / 4000)
                }
                model?.noteVoice(job.id, title: "Voice note", detail: PhoneFmt.clock(Double(size) / 4000))
            } else {
                jobs.removeAll { $0.id == job.id }
            }
        }
        save()
        for job in jobs where job.status == .processing || job.status == .offline {
            await process(job.id)
        }
        sweep()
    }

    // MARK: Recording

    func startRecording() async {
        guard !recorder.isActive else { return }
        Speaker.shared.stop()
        closeCard()
        let id = UUID()
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let now = Date()
        guard await recorder.start(to: audioURL(id)) else {
            if let problem = recorder.problem { model?.show(problem) }
            return
        }
        Haptics.tap()
        recordingID = id
        jobs.insert(VoiceJob(id: id, recordedAt: now, duration: 0, attachmentName: "Voice note \(PhoneFmt.fileStamp(now)).aac",
                             transcript: "", status: .recording), at: 0)
        save()
    }

    /// Stops, shows the result card and starts the debrief.
    func stopRecording() async {
        guard recorder.isActive else { return }
        guard let id = recordingID else {
            _ = await recorder.stop()
            return
        }
        recordingID = nil
        guard let recording = await recorder.stop() else {
            jobs.removeAll { $0.id == id }
            save()
            model?.show("Nothing was recorded.")
            return
        }
        Haptics.success()
        update(id) {
            $0.recordedAt = recording.startedAt
            $0.duration = recording.duration
            $0.transcript = recording.transcript
            $0.status = .processing
        }
        model?.tab = .capture
        model?.noteVoice(id, title: "Voice note", detail: PhoneFmt.clock(recording.duration))
        openCard(id)
        await process(id)
    }

    func discardRecording() {
        recorder.discard()
        if let id = recordingID {
            jobs.removeAll { $0.id == id }
            save()
        }
        recordingID = nil
    }

    // MARK: Debrief

    /// Asks Gemini (or hands it to the Mac without a key). Never loses the recording.
    func process(_ id: UUID) async {
        guard let job = job(id), !job.isWritten, !processing.contains(id), let model else { return }
        if isDemo {
            update(id) { $0.status = .processing }
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            update(id) {
                $0.debrief = DemoSeed.debrief(recordedAt: job.recordedAt)
                $0.status = .ready
            }
            sweepSoon()
            return
        }
        guard let ai = model.makeAI() else {
            update(id) {
                $0.status = .handedToMac
                $0.message = nil
            }
            commit(id)
            return
        }
        guard isOnline else {
            update(id) { $0.status = .offline }
            handToMacIfTooOld(id)
            return
        }
        processing.insert(id)
        defer { processing.remove(id) }
        update(id) {
            $0.status = .processing
            $0.lastAttempt = Date()
        }
        let background = UIApplication.shared.beginBackgroundTask(withName: "Voice debrief")
        defer { if background != .invalid { UIApplication.shared.endBackgroundTask(background) } }
        let snapshot = model.snapshot
        let url = audioURL(id)
        let audio = await Task.detached(priority: .userInitiated) { try? Data(contentsOf: url) }.value
        do {
            // What the Mac's memory knows about what was heard (names, dates, who to chase), when anything was.
            let heard = job.transcript.trimmingCharacters(in: .whitespacesAndNewlines)
            let debriefer = VoiceDebriefer(ai: ai, profile: snapshot?.profile ?? MemoryProfile(), lenses: snapshot?.lenses ?? [],
                                           listNames: snapshot?.listNames ?? [], knownPeople: snapshot?.knownPeople ?? [],
                                           memoryContext: heard.isEmpty ? nil : model.taskContextBlock(for: heard))
            let debrief = try await debriefer.debrief(audio: audio.map { MemoryInlinePart(mimeType: "audio/aac", data: $0) },
                                                      liveTranscript: job.transcript, recordedAt: job.recordedAt, madeBy: "iPhone")
            update(id) {
                $0.debrief = debrief
                $0.status = .ready
                $0.message = nil
            }
            model.noteVoice(id, title: debrief.title.isEmpty ? "Voice note" : debrief.title,
                            detail: Self.recordDetail(duration: job.duration, tasks: debrief.tasks.count))
            sweepSoon()
        } catch let error as MemoryAIError where error.isTransient {
            update(id) {
                $0.status = .offline
                $0.message = Self.plain(error)
            }
            handToMacIfTooOld(id)
        } catch is CancellationError {
            update(id) { $0.status = .offline }
        } catch {
            // Gemini refused (bad key, couldn't make sense of it): the Mac tries with its own key.
            update(id) {
                $0.status = .handedToMac
                $0.message = (error as? MemoryAIError).map(Self.plain) ?? error.localizedDescription
            }
            commit(id)
        }
    }

    private static func plain(_ error: MemoryAIError) -> String {
        (error.errorDescription ?? "").replacingOccurrences(of: "Settings → AI", with: "Settings")
    }

    static func recordDetail(duration: TimeInterval, tasks: Int?) -> String {
        guard let tasks else { return PhoneFmt.clock(duration) }
        return "\(PhoneFmt.clock(duration)) · \(PhoneFmt.count(tasks, "task"))"
    }

    private func handToMacIfTooOld(_ id: UUID) {
        guard let job = job(id), !job.isWritten, Date().timeIntervalSince(job.recordedAt) > Self.giveUpAfter else { return }
        update(id) { $0.status = .handedToMac }
        commit(id)
    }

    private func networkChanged(_ online: Bool) {
        let cameBack = online && !isOnline
        isOnline = online
        guard cameBack else { return }
        Task {
            for job in jobs where job.status == .offline { await process(job.id) }
        }
    }

    // MARK: The result card

    func openCard(_ id: UUID) {
        cardID = id
        cardShownAt = Date()
        update(id) { $0.commitAfter = nil }
    }

    /// Done, ✕, another tab, or the app going away. What's ready is written once the grace period is over.
    func closeCard() {
        guard let id = cardID else { return }
        cardID = nil
        let due = max(Date(), (cardShownAt ?? .distantPast).addingTimeInterval(Self.holdSeconds))
        update(id) { $0.commitAfter = due }
        sweepSoon()
    }

    /// The app is going to the background: nothing waits on a card nobody can see.
    func enterBackground() {
        closeCard()
        for job in jobs where job.status == .ready && !job.isWritten { commit(job.id) }
    }

    // MARK: Editing on the card (and Today)

    /// ✕ on a task: free while held; after writing, a taskDelete goes to the Mac.
    func removeTask(_ taskID: UUID) {
        guard let job = jobs.first(where: { $0.debrief?.tasks.contains { $0.id == taskID } == true }) else { return }
        if job.isWritten {
            guard !job.deletedTaskIDs.contains(taskID) else { return }
            let title = job.debrief?.tasks.first { $0.id == taskID }?.title
            update(job.id) { $0.deletedTaskIDs.append(taskID) }
            model?.sendTaskDelete(taskID, title: title)
        } else {
            update(job.id) { $0.debrief?.tasks.removeAll { $0.id == taskID } }
        }
        refreshRecordDetail(job.id)
    }

    /// Puts a removed task back (Undo on Today) while the job is still held.
    func restoreTask(_ task: DebriefTask, in jobID: UUID, at index: Int) {
        guard let job = job(jobID), !job.isWritten else { return }
        update(jobID) {
            guard $0.debrief != nil, !$0.debrief!.tasks.contains(where: { $0.id == task.id }) else { return }
            $0.debrief!.tasks.insert(task, at: min(index, $0.debrief!.tasks.count))
        }
        refreshRecordDetail(jobID)
    }

    /// A changed title or date. After writing, the old task is deleted and a new one added (there's no
    /// "edit" envelope).
    func updateTask(_ task: DebriefTask) {
        guard let job = jobs.first(where: { $0.debrief?.tasks.contains { $0.id == task.id } == true }) else { return }
        if !job.isWritten {
            update(job.id) {
                guard let i = $0.debrief?.tasks.firstIndex(where: { $0.id == task.id }) else { return }
                $0.debrief?.tasks[i] = task
            }
            return
        }
        var replacement = task
        replacement.id = UUID()
        update(job.id) {
            guard let i = $0.debrief?.tasks.firstIndex(where: { $0.id == task.id }) else { return }
            $0.debrief?.tasks[i] = replacement
        }
        model?.sendTaskDelete(task.id, title: task.title)
        model?.capture(.task(replacement), title: replacement.title, detail: PhoneFmt.taskDetail(replacement), quiet: true)
    }

    /// "Undo all": none of its tasks get added. The recording and its memory stay.
    func undoAll(_ jobID: UUID) {
        guard let job = job(jobID) else { return }
        for task in job.tasks { removeTask(task.id) }
    }

    private func refreshRecordDetail(_ id: UUID) {
        guard let job = job(id) else { return }
        model?.noteVoice(id, title: (job.debrief?.title).flatMap { $0.isEmpty ? nil : $0 } ?? "Voice note",
                         detail: Self.recordDetail(duration: job.duration, tasks: job.debrief == nil ? nil : job.tasks.count))
    }

    /// A task from a held debrief is being ticked off: write the debrief now so the Mac has the task first.
    func commitNow(containing taskID: UUID) {
        guard let job = jobs.first(where: { $0.tasks.contains { $0.id == taskID } }), job.status == .ready, !job.isWritten else { return }
        if cardID == job.id { cardID = nil }
        commit(job.id)
    }

    // MARK: Today

    /// Debrief tasks the Mac's task list doesn't show yet, as task lines.
    func pendingTasks(excluding known: Set<UUID>) -> [TaskSnapshot] {
        jobs.filter { $0.status == .ready || $0.status == .written }
            .flatMap(\.tasks)
            .filter { !known.contains($0.id) }
            .map(\.asSnapshot)
    }

    func debriefTask(_ id: UUID) -> DebriefTask? {
        for job in jobs { if let task = job.tasks.first(where: { $0.id == id }) { return task } }
        return nil
    }

    // MARK: Writing

    /// Into Pending (and on to the Inbox): audio, on-device transcript and the debrief when there is one.
    private func commit(_ id: UUID) {
        guard let job = job(id), !job.isWritten, job.status != .recording, let model else { return }
        let debrief = job.status == .handedToMac ? nil : job.debrief
        let title = (debrief?.title).flatMap { $0.isEmpty ? nil : $0 }
        var envelope = CaptureEnvelope(id: job.id, kind: .voice, createdAt: job.recordedAt, title: title,
                                       device: "iPhone", transcript: job.transcript.isEmpty ? nil : job.transcript, debrief: debrief)
        envelope.attachmentName = job.attachmentName
        let url = audioURL(id)
        let attachment: CaptureAttachment? = FileManager.default.fileExists(atPath: url.path) ? .file(url, move: true) : nil
        let written = model.capture(envelope, attachment: attachment, title: title ?? "Voice note",
                                    detail: Self.recordDetail(duration: job.duration, tasks: debrief.map { $0.tasks.count }), quiet: true)
        guard written else { return }
        update(id) {
            $0.writtenAt = Date()
            if $0.status == .ready { $0.status = .written }
        }
    }

    // MARK: Housekeeping

    /// Writes what's due, retries what's waiting, notes what the Mac has taken, forgets what's done.
    func sweep(now: Date = Date()) {
        guard let model else { return }
        for job in jobs where job.status == .ready && !job.isWritten && job.id != cardID && now >= (job.commitAfter ?? .distantPast) {
            commit(job.id)
        }
        for job in jobs where job.status == .offline {
            if now.timeIntervalSince(job.recordedAt) > Self.giveUpAfter {
                handToMacIfTooOld(job.id)
            } else if isOnline, now.timeIntervalSince(job.lastAttempt ?? .distantPast) > Self.retryEvery {
                Task { await process(job.id) }
            }
        }
        let received = Set(model.records.filter { $0.state == .received }.map(\.id))
        for job in jobs where job.isWritten && job.macReceivedAt == nil && received.contains(job.id) {
            update(job.id) { $0.macReceivedAt = now }
        }
        let generated = model.snapshot?.generatedAt ?? .distantPast
        let before = jobs.count
        jobs.removeAll { job in
            guard job.isWritten, job.id != cardID else { return false }
            if let received = job.macReceivedAt, generated > received { return true }
            return now.timeIntervalSince(job.writtenAt ?? now) > 3 * 24 * 3600
        }
        if jobs.count != before { save() }
        // Wake up for the next held job's grace period.
        if let next = jobs.filter({ $0.status == .ready && !$0.isWritten && $0.id != cardID }).compactMap(\.commitAfter).min(), next > now {
            sweepTask?.cancel()
            sweepTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(max(0.2, next.timeIntervalSinceNow) * 1_000_000_000))
                guard !Task.isCancelled else { return }
                self?.sweep()
            }
        }
    }

    private func sweepSoon() {
        Task { @MainActor [weak self] in self?.sweep() }
    }

    // MARK: Storage

    private func update(_ id: UUID, _ change: (inout VoiceJob) -> Void) {
        guard let i = jobs.firstIndex(where: { $0.id == id }) else { return }
        change(&jobs[i])
        save()
    }

    private func save() {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try? MemoryCoding.encoder.encode(jobs).write(to: jobsURL, options: .atomic)
    }

    private static func load(jobsURL: URL) -> [VoiceJob] {
        guard let data = try? Data(contentsOf: jobsURL) else { return [] }
        return (try? MemoryCoding.decoder.decode([VoiceJob].self, from: data)) ?? []
    }

    // MARK: Demo

    /// Screenshots: a finished debrief on the card.
    func showDemoCard(now: Date = Date()) {
        let recordedAt = now.addingTimeInterval(-90)
        let job = VoiceJob(id: UUID(), recordedAt: recordedAt, duration: 102, attachmentName: "Voice note.aac",
                           transcript: DemoSeed.debriefTranscript, debrief: DemoSeed.debrief(recordedAt: recordedAt), status: .ready)
        jobs.insert(job, at: 0)
        model?.noteVoice(job.id, title: job.debrief?.title ?? "Voice note", detail: Self.recordDetail(duration: job.duration, tasks: job.tasks.count))
        openCard(job.id)
    }
}
