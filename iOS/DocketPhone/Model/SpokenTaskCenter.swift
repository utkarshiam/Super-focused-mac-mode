import Combine
import Foundation
import MemoryKit
import SwiftUI
import UIKit

/// One "Speak a task": the words, and the tasks they became.
struct SpokenJob: Codable, Identifiable, Equatable {
    enum Status: String, Codable {
        /// Gemini is reading the words.
        case scheduling
        /// Its tasks are added (written to Pending / the Inbox).
        case added
        /// Couldn't reach Gemini: the words wait and are read when the network is back.
        case offline
        /// Added as said (date and time read on the phone): no key worked, or offline for 30 minutes.
        case plain
    }

    var id: UUID
    var spokenAt: Date
    var words: String
    var status: Status
    var tasks: [DebriefTask] = []
    /// ✕ or Undo all: taken back (unstaged, or a taskDelete went out).
    var removedIDs: [UUID] = []
    /// Why it's offline or plain, in a sentence.
    var message: String?
    var lastAttempt: Date?

    var visibleTasks: [DebriefTask] { tasks.filter { !removedIDs.contains($0.id) } }
}

/// Scheduling tasks by voice. Listening (live words, level, stop by tap or a ~2 s pause), then with a Gemini
/// key `SpokenTaskParser` turns the words into tasks that are added at once, and the result card on Capture
/// shows them (✕ one, Undo all, tap to edit). Offline the words wait and are read when the network is back;
/// after 30 minutes they're added as said. Without a key the composer opens with the date, time and length
/// read on the phone, for one tap on Add.
@MainActor
final class SpokenTaskCenter: ObservableObject {
    @Published private(set) var isListening = false
    @Published private(set) var jobs: [SpokenJob] = []
    /// The job the result card shows.
    @Published private(set) var cardID: UUID?
    /// Demo mode: the fake listening state's words and level (the mic is never touched).
    @Published private(set) var demoWords = ""
    @Published private(set) var demoLevel: Double = 0

    let dictation = Dictation()
    weak var model: AppModel?

    /// Offline this long after speaking: add it as said.
    static let giveUpAfter: TimeInterval = 30 * 60
    static let retryEvery: TimeInterval = 60
    /// How long a pause after speech ends listening.
    static let pauseToStop: TimeInterval = 2

    private let url: URL
    private let isDemo: Bool
    private var processing: Set<UUID> = []
    private var cancellables: Set<AnyCancellable> = []
    private var demoTimer: Timer?

    init(local: LocalStore, isDemo: Bool) {
        url = local.root.appendingPathComponent("spoken-tasks.json")
        self.isDemo = isDemo
        jobs = isDemo ? [] : ((try? MemoryCoding.decoder.decode([SpokenJob].self, from: Data(contentsOf: url))) ?? [])
        dictation.silenceStop = Self.pauseToStop
        dictation.onAutoStop = { [weak self] words in self?.heard(words) }
        dictation.objectWillChange.sink { [weak self] in self?.objectWillChange.send() }.store(in: &cancellables)
    }

    /// Wires the network state in (the voice center watches it).
    func attach(_ model: AppModel) {
        self.model = model
        model.voice.$isOnline.removeDuplicates().dropFirst().filter { $0 }.sink { [weak self] _ in
            Task { @MainActor in self?.retryOffline() }
        }.store(in: &cancellables)
    }

    var card: SpokenJob? { cardID.flatMap { id in jobs.first { $0.id == id } } }
    var heardText: String { isDemo ? demoWords : dictation.text }
    var level: Double { isDemo ? demoLevel : dictation.level }

    // MARK: Listening (Capture's "Speak a task")

    func startListening() async {
        guard !isListening, let model else { return }
        Speaker.shared.stop()
        model.voice.closeCard()
        closeCard()
        if isDemo {
            showDemoListening()
            return
        }
        if let problem = await dictation.start() {
            model.show(problem)
            return
        }
        withAnimation(Motion.snappy) { isListening = true }
    }

    /// Stop tapped.
    func stopListening() async {
        guard isListening else { return }
        if isDemo {
            cancelListening()
            return
        }
        let words = await dictation.stop()
        heard(words)
    }

    func cancelListening() {
        demoTimer?.invalidate()
        demoTimer = nil
        dictation.cancel()
        withAnimation(Motion.snappy) { isListening = false }
    }

    private func heard(_ words: String) {
        guard isListening else { return }
        withAnimation(Motion.snappy) { isListening = false }
        let spoken = words.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !spoken.isEmpty else {
            model?.show("Didn't catch that. Tap the mic and say the task.")
            return
        }
        Haptics.tap()
        if model?.makeAI() != nil {
            schedule(spoken)
        } else {
            // No key: the composer, filled from the words, for one tap on Add.
            model?.composing = ComposerRequest(draft: TaskTextParser.draft(spoken))
        }
    }

    // MARK: Scheduling

    /// With a key: the words become tasks (added at once) and the card shows them. Also used by the
    /// composer's mic.
    func schedule(_ words: String, spokenAt: Date = Date()) {
        let job = SpokenJob(id: UUID(), spokenAt: spokenAt, words: words, status: .scheduling)
        withAnimation(Motion.snappy) {
            jobs.insert(job, at: 0)
            cardID = job.id
        }
        model?.tab = .capture
        save()
        Task { await process(job.id) }
    }

    private func process(_ id: UUID) async {
        guard let job = jobs.first(where: { $0.id == id }), job.status == .scheduling || job.status == .offline,
              !processing.contains(id), let model else { return }
        if isDemo {
            try? await Task.sleep(nanoseconds: 900_000_000)
            finish(id, tasks: DemoSeed.spokenTasks(now: job.spokenAt), status: .added)
            return
        }
        guard let ai = model.makeAI() else {
            addPlain(id, message: nil)
            return
        }
        guard model.voice.isOnline else {
            update(id) { $0.status = .offline }
            giveUpIfOld(id)
            return
        }
        processing.insert(id)
        defer { processing.remove(id) }
        update(id) {
            $0.status = .scheduling
            $0.lastAttempt = Date()
        }
        let background = UIApplication.shared.beginBackgroundTask(withName: "Schedule spoken task")
        defer { if background != .invalid { UIApplication.shared.endBackgroundTask(background) } }
        let parser = SpokenTaskParser(ai: ai, listNames: model.snapshot?.listNames ?? [], knownPeople: model.snapshot?.knownPeople ?? [])
        do {
            let tasks = try await parser.parse(job.words, now: job.spokenAt)
            if tasks.isEmpty {
                addPlain(id, message: nil)
            } else {
                finish(id, tasks: tasks, status: .added)
            }
        } catch let error as MemoryAIError where error.isTransient {
            update(id) {
                $0.status = .offline
                $0.message = (error.errorDescription ?? "").replacingOccurrences(of: "Settings → AI", with: "Settings")
            }
            giveUpIfOld(id)
        } catch is CancellationError {
            update(id) { $0.status = .offline }
        } catch {
            // Gemini refused (bad key, made no sense of it): add it as said rather than lose it.
            let message = (error as? MemoryAIError)?.errorDescription ?? error.localizedDescription
            addPlain(id, message: message.replacingOccurrences(of: "Settings → AI", with: "Settings"))
        }
    }

    /// Writes the tasks (each a `.task` envelope with every field) and shows them.
    private func finish(_ id: UUID, tasks: [DebriefTask], status: SpokenJob.Status) {
        guard let model else { return }
        let written = tasks.filter { model.addTask($0, quiet: true) }
        update(id) {
            $0.tasks = written
            $0.status = status
            if status == .added { $0.message = nil }
        }
        if !written.isEmpty { Haptics.success() }
    }

    /// The date, time, length and reminder read on the phone; the Mac's QuickParser has a go when no date was found.
    private func addPlain(_ id: UUID, message: String?) {
        guard let job = jobs.first(where: { $0.id == id }) else { return }
        update(id) { $0.message = message }
        finish(id, tasks: [TaskTextParser.draft(job.words, now: job.spokenAt)], status: .plain)
    }

    private func giveUpIfOld(_ id: UUID, now: Date = Date()) {
        guard let job = jobs.first(where: { $0.id == id }), job.status == .offline,
              now.timeIntervalSince(job.spokenAt) > Self.giveUpAfter else { return }
        addPlain(id, message: "Gemini couldn't be reached for 30 minutes, so it was added as said.")
    }

    private func retryOffline() {
        for job in jobs where job.status == .offline { Task { await process(job.id) } }
    }

    /// Every refresh: retries what's waiting, gives up on what's too old, forgets finished ones.
    func sweep(now: Date = Date()) {
        guard !isDemo else { return }
        for job in jobs where job.status == .offline {
            if now.timeIntervalSince(job.spokenAt) > Self.giveUpAfter {
                giveUpIfOld(job.id, now: now)
            } else if model?.voice.isOnline == true, now.timeIntervalSince(job.lastAttempt ?? .distantPast) > Self.retryEvery {
                Task { await process(job.id) }
            }
        }
        // Interrupted mid-call (the app was killed): try again.
        for job in jobs where job.status == .scheduling && !processing.contains(job.id) {
            if now.timeIntervalSince(job.lastAttempt ?? job.spokenAt) > Self.retryEvery { Task { await process(job.id) } }
        }
        let before = jobs.count
        jobs.removeAll { ($0.status == .added || $0.status == .plain) && $0.id != cardID && now.timeIntervalSince($0.spokenAt) > 24 * 3600 }
        if jobs.count != before { save() }
    }

    // MARK: The card

    func closeCard() {
        guard cardID != nil else { return }
        withAnimation(Motion.snappy) { cardID = nil }
    }

    /// ✕ on a task.
    func remove(_ taskID: UUID, in jobID: UUID) {
        guard let job = jobs.first(where: { $0.id == jobID }), job.tasks.contains(where: { $0.id == taskID }),
              !job.removedIDs.contains(taskID) else { return }
        model?.takeBackTask(taskID)
        update(jobID) { $0.removedIDs.append(taskID) }
    }

    func undoAll(_ jobID: UUID) {
        guard let job = jobs.first(where: { $0.id == jobID }) else { return }
        for task in job.visibleTasks { remove(task.id, in: jobID) }
    }

    /// Edited on the composer: the old task is taken back and the new one added (no "edit" envelope).
    func update(_ task: DebriefTask, in jobID: UUID) {
        guard let model, let job = jobs.first(where: { $0.id == jobID }),
              let i = job.tasks.firstIndex(where: { $0.id == task.id }) else { return }
        let sent = model.replaceTask(task)
        update(jobID) { $0.tasks[i] = sent }
    }

    // MARK: Storage

    private func update(_ id: UUID, _ change: (inout SpokenJob) -> Void) {
        guard let i = jobs.firstIndex(where: { $0.id == id }) else { return }
        change(&jobs[i])
        save()
    }

    private func save() {
        guard !isDemo else { return }
        try? MemoryCoding.encoder.encode(jobs).write(to: url, options: .atomic)
    }

    // MARK: Demo

    /// `DOCKET_PHONE_TAB=dictate`: listening, with words "heard" and a moving level. No microphone.
    func showDemoListening() {
        demoWords = DemoSeed.spokenWords
        isListening = true
        demoTimer?.invalidate()
        var phase = 0.0
        demoTimer = Timer.scheduledTimer(withTimeInterval: 0.12, repeats: true) { [weak self] _ in
            Task { @MainActor in
                phase += 0.7
                self?.demoLevel = 0.45 + 0.35 * abs(sin(phase))
            }
        }
    }

    /// `DOCKET_PHONE_TAB=dictated`: the result card with two added tasks.
    func showDemoResult(now: Date = Date()) {
        let job = SpokenJob(id: UUID(), spokenAt: now.addingTimeInterval(-20), words: DemoSeed.spokenWords, status: .scheduling)
        jobs.insert(job, at: 0)
        cardID = job.id
        finish(job.id, tasks: DemoSeed.spokenTasks(now: now), status: .added)
    }
}

/// What the composer opens with.
struct ComposerRequest: Identifiable {
    var id = UUID()
    var draft: DebriefTask
    /// Opens with More shown (and the sheet tall).
    var expanded = false
}
