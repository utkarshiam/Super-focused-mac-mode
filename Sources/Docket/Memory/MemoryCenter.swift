import AppKit
import Combine
import Foundation
import MemoryKit
import Network

/// The Mac app's one memory: the library on disk, the processor that summarises and indexes what's
/// saved, and the capture entry points every screen uses. Views read `library` / `processor` and
/// call the `capture…` methods; they never build their own.
///
/// `start` (at launch) wires it to the rest of the app: remembering work by itself (`MemoryAutoCapture`),
/// the iPhone folder (`PhoneSync`), the Gemini key in Settings → AI, the profile refresh, and the brain
/// (topics, living pages and the map), which tidies up whenever processing goes idle.
@MainActor
final class MemoryCenter: ObservableObject {
    static let shared = MemoryCenter()

    let library: MemoryLibrary
    let processor: MemoryProcessor
    /// Docket Brain: people, organisations, projects and topics, their pages and the map (`brain.json`).
    let brain: MemoryBrain
    /// Voice notes, from the phone or recorded here: their tasks and memories.
    let voice: VoiceIntake
    /// Set by `start`.
    private(set) var autoCapture: MemoryAutoCapture?
    private(set) var phone: PhoneSync?

    private var cancellables = Set<AnyCancellable>()
    private var network: NWPathMonitor?
    private var lastProfileCheck = Date.distantPast
    /// The profile is looked at again at most this often (after processing settles).
    static let profileInterval: TimeInterval = 10 * 60

    /// `Application Support/Docket/Memory` (or `$DOCKET_DATA_DIR/Memory`). Unit tests get a throwaway
    /// folder so they never read or write the real library.
    nonisolated static var defaultDirectory: URL {
        if GeminiClient.isUnitTesting {
            return FileManager.default.temporaryDirectory
                .appendingPathComponent("DocketMemoryTests-\(ProcessInfo.processInfo.processIdentifier)", isDirectory: true)
        }
        return Persistence.defaultDirectory.appendingPathComponent("Memory", isDirectory: true)
    }

    init(directory: URL? = nil) {
        let directory = directory ?? Self.defaultDirectory
        library = MemoryLibrary(directory: directory)
        processor = MemoryProcessor(library: library, ai: Self.makeAI())
        brain = MemoryBrain(library: library)
        voice = VoiceIntake(library: library, store: nil)
        voice.ai = { [weak self] in self?.processor.ai }
    }

    /// True when a Gemini key is set, so items get summarised and Ask works.
    var hasAI: Bool { processor.ai != nil }

    /// Call after the Gemini key or model changes in Settings.
    func refreshAI() {
        processor.ai = Self.makeAI()
        objectWillChange.send()
    }

    /// Gemini with the user's key, unless "Use AI" is off (or in screenshot mode, which never calls out).
    static func makeAI() -> MemoryAI? {
        guard Prefs.aiEnabled, !DebugSnapshot.isActive, let key = Secrets.geminiAPIKey else { return nil }
        return GeminiMemoryAI(apiKey: key, model: Secrets.geminiModel)
    }

    // MARK: Lifecycle

    /// At launch: remember work as it happens, sync the iPhone folder when that's on, follow the Gemini key,
    /// pick up after sleep or a dropped connection, and keep the profile fresh.
    func start(store: Store, integrations: Integrations? = nil) {
        guard autoCapture == nil else { return }
        let integrations = integrations ?? .shared
        // Screenshot mode stays as seeded: nothing is captured or synced behind its back.
        if !DebugSnapshot.isActive {
            let capture = MemoryAutoCapture(library: library, store: store)
            autoCapture = capture
            // The first time Memory runs, what's already in Docket goes in too, not only new work.
            if !UserDefaults.standard.bool(forKey: Prefs.Key.memoryBackfilled) {
                capture.backfill()
                UserDefaults.standard.set(true, forKey: Prefs.Key.memoryBackfilled)
            }
            watchMessages(integrations)
            // Extraction reuses the brain's names, and it organises and writes pages when processing settles.
            brain.attach(to: processor)
        }
        voice.attach(store: store)
        let phone = PhoneSync(library: library, store: store, voice: voice, brain: brain)
        self.phone = phone
        voice.onReady = { [weak phone] in phone?.ingest() }
        voice.onApplied = { [weak store] outcome in
            guard let store else { return }
            NotificationService.shared.deliverVoiceNote(outcome, tasks: outcome.taskIDs.compactMap(store.task))
        }
        phone.update()

        // The key, model or "Use AI" changed in Settings → AI.
        AIService.shared.$settingsRevision.dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.refreshAI() }
            .store(in: &cancellables)
        NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)
            .debounce(for: .milliseconds(300), scheduler: DispatchQueue.main)
            .sink { [weak self] _ in self?.phone?.update() }
            .store(in: &cancellables)
        NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didWakeNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.processor.resume() }
            .store(in: &cancellables)
        watchNetwork()

        // When a run of processing ends, the profile may be due another look.
        processor.$processingCount
            .removeDuplicates()
            .scan((0, 0)) { ($0.1, $1) }
            .filter { $0.0 > 0 && $0.1 == 0 }
            .sink { [weak self] _ in self?.refreshProfileIfNeeded() }
            .store(in: &cancellables)
        // And once a minute after launch, for a library that has nothing to process.
        DispatchQueue.main.asyncAfter(deadline: .now() + 60) { [weak self] in self?.refreshProfileIfNeeded() }
    }

    /// On quit: everything on disk now.
    func flush() {
        library.flush()
        brain.flush()
    }

    /// Back online after being offline: processing waiting out the outage starts again.
    private func watchNetwork() {
        guard !GeminiClient.isUnitTesting, !DebugSnapshot.isActive else { return }
        let monitor = NWPathMonitor()
        var wasOnline = true
        monitor.pathUpdateHandler = { path in
            let online = path.status == .satisfied
            DispatchQueue.main.async { [weak self] in
                if online && !wasOnline { self?.processor.resume() }
                wasOnline = online
            }
        }
        monitor.start(queue: DispatchQueue(label: "docket.memory.network", qos: .utility))
        network = monitor
    }

    /// Refreshes "What Docket knows about me" when it's due (`ProfileSynthesizer.needsRefresh`), at most every
    /// ten minutes, and only with AI.
    func refreshProfileIfNeeded(now: Date = Date()) {
        guard let ai = processor.ai, now.timeIntervalSince(lastProfileCheck) >= Self.profileInterval,
              ProfileSynthesizer.needsRefresh(library.profile, itemCount: library.count, now: now) else { return }
        lastProfileCheck = now
        let library = library
        Task { @MainActor in _ = try? await ProfileSynthesizer(ai: ai).refreshIfNeeded(library) }
    }

    // MARK: Status

    /// One line for Settings: what the AI side is doing.
    var statusLine: String {
        guard Prefs.aiEnabled else { return "AI is off. Turn it on in Settings → AI to summarise and ask" }
        guard hasAI else { return "Add a Gemini key to summarise and ask" }
        if processor.processingCount > 0 { return "Summarising \(processor.processingCount)…" }
        if processor.isPaused, let error = processor.lastError { return error.errorDescription ?? "Waiting to try again" }
        let failed = failedCount
        if failed > 0 { return "\(Self.memories(failed)) couldn't be summarised" }
        return "All caught up"
    }

    /// One line for Settings about the brain: "Organised Thu 8 Oct · 13 topics in 6 areas", what it's doing,
    /// or why it can't.
    var brainLine: String {
        if brain.isWorking { return "Organising…" }
        if let error = brain.lastError, hasAI { return error.errorDescription ?? "Couldn't organise" }
        let topics = brain.allTopics().count, areas = brain.areas().count
        guard let at = brain.organizedAt else {
            return library.count < brain.minimumItemsToOrganize ? "Docket sorts memories into topics once there are a few" : "Not organised yet"
        }
        var line = "Organised \(MemoryText.date(at)) · \(topics) \(topics == 1 ? "topic" : "topics")"
        if areas > 0 { line += " in \(areas) \(areas == 1 ? "area" : "areas")" }
        return line
    }

    /// Reorganises now (Settings → Memory, the Topics screen), then writes the pages that are due.
    func organizeNow() {
        let brain = brain, ai = processor.ai
        Task { @MainActor in
            await brain.organizeNow(ai: ai)
            if let ai { await brain.synthesizeStale(ai: ai) }
        }
    }

    /// Pages being written because the user asked ("Let Docket write it"), for their spinners.
    @Published private(set) var writingPages: Set<UUID> = []

    /// Writes one living page now. Returns the error to show, if any.
    func writePage(_ id: UUID) async -> String? {
        guard let ai = processor.ai else { return MemoryText.noKey }
        writingPages.insert(id)
        defer { writingPages.remove(id) }
        do {
            try await brain.synthesize(id, ai: ai)
            return nil
        } catch {
            return (error as? MemoryAIError)?.errorDescription ?? error.localizedDescription
        }
    }

    var failedCount: Int { library.items.filter { $0.processing.isFailed }.count }

    /// "1 memory", "412 memories".
    static func memories(_ n: Int) -> String { "\(n) \(n == 1 ? "memory" : "memories")" }

    /// The library folder's size on disk (memories, vectors and files).
    func storageBytes() async -> Int64 {
        let folder = library.directory
        return await Task.detached(priority: .utility) {
            var total: Int64 = 0
            let keys: [URLResourceKey] = [.totalFileAllocatedSizeKey, .fileSizeKey, .isRegularFileKey]
            guard let files = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: keys) else { return 0 }
            while let url = files.nextObject() as? URL {
                guard let values = try? url.resourceValues(forKeys: Set(keys)), values.isRegularFile == true else { continue }
                total += Int64(values.totalFileAllocatedSize ?? values.fileSize ?? 0)
            }
            return total
        }.value
    }

    // MARK: Import

    /// Reads an ENGRAM export (Settings → Export in ENGRAM) into memory. Entries already imported are skipped.
    @discardableResult
    func importEngram(from url: URL) throws -> EngramImporter.Report {
        let data = try Data(contentsOf: url)
        return try EngramImporter.importExport(data, into: library)
    }

    /// "Imported 412 memories (3 already here)".
    static func importLine(_ r: EngramImporter.Report) -> String {
        if r.imported == 0 {
            return r.skippedDuplicates > 0 ? "Nothing new: \(memories(r.skippedDuplicates)) already here" : "Nothing to import in that file"
        }
        let line = "Imported \(memories(r.imported))"
        return r.skippedDuplicates > 0 ? line + " (\(r.skippedDuplicates) already here)" : line
    }

    // MARK: Capture

    /// Saves typed text (a thought, an idea, pasted text). Returns nil for blank text.
    @discardableResult
    func capture(text: String, title: String? = nil, origin: MemoryOrigin = .manual) -> MemoryItem? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if let url = Self.singleURL(in: trimmed) {
            return library.addLink(url.absoluteString, title: title ?? "", origin: origin)
        }
        return library.addNote(trimmed, title: title ?? "", origin: origin)
    }

    /// Saves a link; the processor fetches the page and summarises it.
    @discardableResult
    func capture(link: URL, note: String = "", origin: MemoryOrigin = .manual) -> MemoryItem {
        library.addLink(link.absoluteString, note: note, origin: origin)
    }

    /// Copies dropped or picked files into the library (images, videos, PDFs, audio, anything).
    @discardableResult
    func capture(fileURLs: [URL], origin: MemoryOrigin = .manual) -> [MemoryItem] {
        fileURLs.compactMap { url in
            if !url.isFileURL { return library.addLink(url.absoluteString, origin: origin) }
            return try? library.addFile(at: url, origin: origin)
        }
    }

    /// The text is exactly one http(s) link.
    static func singleURL(in text: String) -> URL? {
        guard !text.contains(where: \.isWhitespace),
              let url = URL(string: text), let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https", url.host != nil else { return nil }
        return url
    }

    // MARK: Messages

    /// Remembers a message's thread (Remember in Messages, or automatically): its summary, what was said, who.
    /// Again later, it updates the same memory. Nil when the message isn't in the inbox.
    @discardableResult
    func rememberMessage(_ id: String, reply: String? = nil, origin: MemoryOrigin = .manual,
                         integrations: Integrations? = nil) -> MemoryItem? {
        guard let s = (integrations ?? .shared).suggestion(id) else { return nil }
        return rememberMessage(s, reply: reply, origin: origin, integrations: integrations)
    }

    @discardableResult
    func rememberMessage(_ s: Suggestion, reply: String? = nil, origin: MemoryOrigin = .manual,
                         integrations: Integrations? = nil) -> MemoryItem {
        let integrations = integrations ?? .shared
        return library.add(MessageMemory.item(for: s, summary: integrations.summary(for: s.id),
                                       thread: integrations.wholeThreads[s.id]?.forReplyContext, reply: reply, origin: origin))
    }

    /// A reply went out from Docket: the thread is remembered with it (when messages are remembered).
    func replySent(_ text: String, for id: String) {
        guard autoCapture != nil, Prefs.memoryCapturesMessages else { return }
        rememberMessage(id, reply: text, origin: .auto)
    }

    /// Thread summaries as they're written, and messages made into a task or a note.
    private func watchMessages(_ integrations: Integrations) {
        var known = integrations.threadSummaries.mapValues(\.madeAt)
        integrations.$threadSummaries.dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self, weak integrations] summaries in
                guard let self, let integrations else { return }
                let now = Date()
                for (id, summary) in summaries where known[id] != summary.madeAt && now.timeIntervalSince(summary.madeAt) < 10 * 60 {
                    if Prefs.memoryCapturesMessages { self.rememberMessage(id, origin: .auto, integrations: integrations) }
                }
                known = summaries.mapValues(\.madeAt)
            }
            .store(in: &cancellables)
        integrations.messageUsed = { [weak self, weak integrations] s, note in
            guard let self, let integrations else { return }
            // The note is the message: remembered once, as the message.
            if let note { self.autoCapture?.skipNote(note.id) }
            if Prefs.memoryCapturesMessages { self.rememberMessage(s, origin: .auto, integrations: integrations) }
        }
    }
}
