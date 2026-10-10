import Combine
import Foundation

/// Turns saved items into memory: gathers content (fetches links, reads attachments), asks Gemini for
/// title, summary, takeaways, people, projects, topics, tags and moments (with lens guidance and the
/// profile), then embeds the result. Lightweight items (auto-captured tasks, ENGRAM imports) and
/// processed items without a vector are only embedded, in batches.
///
/// - Two items at a time (`concurrency`); transient failures retry with backoff (`retryDelays`), then
///   the queue pauses and resumes after `resumeDelay` (or `resume()`), leaving items pending on disk,
///   so nothing is lost offline or across relaunches.
/// - No AI (`ai == nil`): pending items become `.skipped` (searchable by text). Setting `ai` processes
///   them. A rejected key pauses the queue until `ai` is replaced.
/// - A different embedding model than the stored vectors' re-embeds everything (vectors can't mix).
/// - With `autoProcess` it watches the library and picks up new pending items by itself.
@MainActor
public final class MemoryProcessor: ObservableObject {
    public let library: MemoryLibrary
    /// The AI to use; nil without a key. Replace it when the key or model changes.
    public var ai: MemoryAI? { didSet { aiDidChange() } }
    public var fetcher: LinkFetcher
    /// Items processed at the same time.
    public var concurrency: Int
    /// Waits between attempts after a transient failure (offline, rate limited).
    public var retryDelays: [TimeInterval] = [2, 10, 30]
    /// After retries run out on a transient failure, how long the queue rests before trying again.
    public var resumeDelay: TimeInterval = 300
    /// Embed-only items sent in one request.
    public var embedBatchSize = 50
    /// The clock (tests pin it).
    public var now: () -> Date = { Date() }

    /// Items queued or being worked on. 0 when idle.
    @Published public private(set) var processingCount = 0
    /// Items being worked on right now (show a spinner on these).
    @Published public private(set) var runningIDs: Set<UUID> = []
    /// The most recent failure, cleared by the next success. `needsSettings` says whether to offer Settings.
    @Published public private(set) var lastError: MemoryAIError?
    /// Waiting for the network or for a working key; pending items stay pending.
    @Published public private(set) var isPaused = false

    private struct Job: Equatable {
        var id: UUID
        var embedOnly: Bool
    }

    private var queue: [Job] = []
    private var queuedIDs: Set<UUID> = []
    private var workers = 0
    private var subscription: AnyCancellable?
    private var resumeTask: Task<Void, Never>?
    private var idleWaiters: [CheckedContinuation<Void, Never>] = []

    public init(library: MemoryLibrary, ai: MemoryAI?, fetcher: LinkFetcher = LinkFetcher(),
                concurrency: Int = 2, autoProcess: Bool = true) {
        self.library = library
        self.ai = ai
        self.fetcher = fetcher
        self.concurrency = max(1, concurrency)
        if autoProcess {
            subscription = library.changes
                .debounce(for: .milliseconds(300), scheduler: RunLoop.main)
                .sink { [weak self] in Task { @MainActor in self?.processPending() } }
            processPending()
        }
    }

    // MARK: Control

    /// Queues everything that needs work: pending and skipped items (all of them, when there's AI),
    /// and processed items missing a vector. Without AI, marks pending items skipped.
    public func processPending() {
        guard let ai else {
            let pending = library.items.filter { $0.processing == .pending }.map(\.id)
            library.update(pending) { $0.processing = .skipped }
            return
        }
        guard !isPaused else { return }
        let index = library.vectors
        if !index.isEmpty && (index.model != ai.embeddingModel || index.dimensions != ai.embeddingDimensions) {
            library.removeAllVectors()
        }
        let vectors = library.vectors
        var jobs: [Job] = []
        for item in library.items where !queuedIDs.contains(item.id) && !runningIDs.contains(item.id) {
            switch item.processing {
            case .pending, .skipped:
                jobs.append(Job(id: item.id, embedOnly: item.lightweight))
            case .processed where !vectors.contains(item.id):
                jobs.append(Job(id: item.id, embedOnly: true))
            default:
                break
            }
        }
        enqueue(jobs)
    }

    /// Processes one item again from scratch (the "Retry" / "Process again" action).
    public func reprocess(_ id: UUID) {
        library.update(id) { $0.processing = .pending; $0.attempts = 0 }
        if !queuedIDs.contains(id), !runningIDs.contains(id), let item = library.item(id) {
            enqueue([Job(id: id, embedOnly: item.lightweight)], front: true)
        }
    }

    /// Sets every failed item back to pending and processes them.
    public func retryFailed() {
        let failed = library.items.filter { $0.processing.isFailed }.map(\.id)
        library.update(failed) { $0.processing = .pending; $0.attempts = 0 }
        processPending()
    }

    /// Drops all vectors and embeds everything again ("Rebuild index").
    public func reembedAll() {
        library.removeAllVectors()
        processPending()
    }

    /// Ends a pause now (the app calls this when the network comes back).
    public func resume() {
        resumeTask?.cancel()
        resumeTask = nil
        isPaused = false
        processPending()
    }

    /// Clears the queue. Items being worked on finish; the rest stay pending for next time.
    public func cancelAll() {
        queue.removeAll()
        queuedIDs.removeAll()
        updateCount()
    }

    /// Returns when nothing is queued or running (tests; app quit after `cancelAll`).
    public func waitUntilIdle() async {
        if processingCount == 0 { return }
        await withCheckedContinuation { idleWaiters.append($0) }
    }

    private func aiDidChange() {
        resumeTask?.cancel()
        resumeTask = nil
        isPaused = false
        lastError = nil
        if ai == nil { cancelAll() }
        processPending()
    }

    // MARK: Queue

    private func enqueue(_ jobs: [Job], front: Bool = false) {
        let fresh = jobs.filter { queuedIDs.insert($0.id).inserted }
        guard !fresh.isEmpty else { return }
        if front { queue.insert(contentsOf: fresh, at: 0) } else { queue += fresh }
        pump()
    }

    private func pump() {
        while workers < concurrency, !isPaused, let ai, let first = queue.first {
            var batch: [Job]
            if first.embedOnly {
                batch = []
                var rest: [Job] = []
                for job in queue {
                    if job.embedOnly && batch.count < embedBatchSize { batch.append(job) } else { rest.append(job) }
                }
                queue = rest
            } else {
                batch = [queue.removeFirst()]
            }
            let ids = batch.map(\.id)
            queuedIDs.subtract(ids)
            runningIDs.formUnion(ids)
            workers += 1
            Task {
                await self.run(batch, ai: ai)
                self.workers -= 1
                self.runningIDs.subtract(ids)
                self.updateCount()
                self.pump()
            }
        }
        updateCount()
    }

    private func updateCount() {
        let count = queue.count + runningIDs.count
        if processingCount != count { processingCount = count }
        if count == 0 && workers == 0 {
            let waiters = idleWaiters
            idleWaiters.removeAll()
            waiters.forEach { $0.resume() }
        }
    }

    private func run(_ batch: [Job], ai: MemoryAI) async {
        let ids = batch.map(\.id)
        do {
            try await withRetry {
                if batch.count == 1 && !batch[0].embedOnly {
                    try await self.process(ids[0], ai: ai)
                } else {
                    try await self.embed(ids, ai: ai)
                }
            }
            lastError = nil
        } catch is CancellationError {
            // Stays pending.
        } catch {
            let failure = (error as? MemoryAIError) ?? .badResponse(error.localizedDescription)
            handle(failure, ids: ids)
        }
    }

    /// Transient failures retry through every delay; a bad answer gets one more try.
    private func withRetry(_ operation: () async throws -> Void) async throws {
        var attempt = 0
        while true {
            do {
                try await operation()
                return
            } catch let error as MemoryAIError {
                let limit = error.isTransient ? retryDelays.count : (error.needsSettings ? 0 : min(1, retryDelays.count))
                guard attempt < limit else { throw error }
                let delay = retryDelays[attempt]
                attempt += 1
                if delay > 0 { try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000)) }
            }
        }
    }

    private func handle(_ error: MemoryAIError, ids: [UUID]) {
        lastError = error
        library.update(ids) { $0.attempts += 1 }
        if error.isTransient || error.needsSettings {
            // Offline, busy, or the key is wrong: everything else would fail the same way. Keep it all
            // pending and pause (a new key, `resume()` or the timer starts again).
            isPaused = true
            cancelAll()
            if error.isTransient { scheduleResume() }
        } else {
            library.update(ids) { item in
                // A processed item that only lacked a vector keeps its extraction.
                if item.processing != .processed { item.processing = .failed(error.localizedDescription) }
            }
        }
    }

    private func scheduleResume() {
        resumeTask?.cancel()
        let delay = resumeDelay
        resumeTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(max(0, delay) * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.resumeTask = nil
            self?.isPaused = false
            self?.processPending()
        }
    }

    // MARK: Steps

    /// Embeds items as they are (no extraction) and marks pending/skipped ones processed.
    private func embed(_ ids: [UUID], ai: MemoryAI) async throws {
        let items = ids.compactMap(library.item)
        guard !items.isEmpty else { return }
        let vectors = try await ai.embed(items.map(\.embeddingText), task: .document)
        guard vectors.count == items.count else { throw MemoryAIError.badResponse(MemoryAIError.unexpectedFormat) }
        for (item, vector) in zip(items, vectors) { library.setVector(vector, for: item.id, model: ai.embeddingModel) }
        let stamp = now()
        library.update(items.map(\.id)) { item in
            if item.processing != .processed {
                item.processing = .processed
                item.processedAt = stamp
            }
            item.attempts = 0
        }
    }

    /// Gather → extract → embed → store, for one item.
    private func process(_ id: UUID, ai: MemoryAI) async throws {
        guard let item = library.item(id) else { return }
        let gathered = try await gather(item)
        let system = MemoryPrompts.extractionSystem(lenses: library.lenses, profile: library.profile, now: now())
        let prompt = MemoryPrompts.extractionPrompt(for: item, content: gathered.text, attachmentNote: gathered.note)
        let data = try await ai.generateJSON(system: system, prompt: prompt, schema: MemoryPrompts.extractionSchema, parts: gathered.parts)
        guard let extraction = try? MemoryCoding.decoder.decode(MemoryPrompts.Extraction.self, from: data) else {
            throw MemoryAIError.badResponse(MemoryAIError.unexpectedFormat)
        }
        // Re-read: the user may have edited it while Gemini was thinking.
        guard var updated = library.item(id) else { return }
        Self.apply(extraction, page: gathered.page, to: &updated)
        let vector = try await ai.embed([updated.embeddingText], task: .document).first
        updated.processing = .processed
        updated.processedAt = now()
        updated.attempts = 0
        guard library.item(id) != nil else { return }
        library.update(updated)
        if let vector { library.setVector(vector, for: id, model: ai.embeddingModel) }
    }

    struct Gathered {
        var text: String
        var parts: [MemoryInlinePart] = []
        var note: String?
        var page: LinkFetcher.Page?
    }

    /// The text to send, plus files Gemini should see. Links are fetched once (a body that already
    /// holds page text isn't fetched again).
    private func gather(_ item: MemoryItem) async throws -> Gathered {
        var g = Gathered(text: item.body)
        if item.kind == .link, let url = item.url {
            let note = item.body.trimmingCharacters(in: .whitespacesAndNewlines)
            var text = note.isEmpty ? "" : "The user's note: \(note)\n\n"
            if item.extractedText.isEmpty {
                do {
                    let page = try await fetcher.fetch(url)
                    g.page = page
                    if !page.title.isEmpty { text += "Page title: \(page.title)\n" }
                    if let d = page.description, !d.isEmpty { text += "Page description: \(d)\n" }
                    text += "Page text:\n\(page.text)"
                } catch let error as MemoryAIError where error.isTransient {
                    throw error
                } catch {
                    g.note = "The page couldn't be fetched; work from the URL and the note."
                }
            } else {
                // Fetched on an earlier run.
                text += "Page text:\n\(item.extractedText)"
            }
            g.text = text
        }
        var notes: [String] = []
        var inlineBytes = 0
        for attachment in item.attachments {
            let url = library.fileURL(for: attachment, of: item.id)
            let mime = attachment.mimeType
            if MimeType.isPlainText(mime) {
                let text = await Task.detached { (try? String(contentsOf: url, encoding: .utf8)) ?? "" }.value
                if !text.isEmpty { g.text += "\n\nAttached \(attachment.name):\n" + TextFold.cap(text, 30_000) }
            } else if MimeType.isInlineable(mime), attachment.byteCount <= MemoryInlinePart.maxBytes - inlineBytes,
                      let data = await Task.detached(operation: { try? Data(contentsOf: url) }).value,
                      data.count <= MemoryInlinePart.maxBytes - inlineBytes {
                g.parts.append(MemoryInlinePart(mimeType: mime, data: data))
                inlineBytes += data.count
                notes.append("Attached: \(attachment.name) (\(mime)), included.")
            } else {
                notes.append("Attached: \(attachment.name) (\(mime)), too large or not readable; use its name only.")
            }
        }
        if !notes.isEmpty { g.note = ([g.note].compactMap { $0 } + notes).joined(separator: "\n") }
        if g.text.count > 40_000 { g.text = String(g.text.prefix(40_000)) }
        return g
    }

    /// Writes an extraction onto an item. User-given title, people and tags stay; AI's are added.
    static func apply(_ x: MemoryPrompts.Extraction, page: LinkFetcher.Page?, to item: inout MemoryItem) {
        let clean: ([String]) -> [String] = { $0.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty } }
        if item.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let pageTitle = page?.title.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            item.title = pageTitle.isEmpty ? x.title.trimmingCharacters(in: .whitespacesAndNewlines) : TextFold.cap(pageTitle, 120)
        }
        item.summary = x.summary.trimmingCharacters(in: .whitespacesAndNewlines)
        item.keyTakeaways = Array(clean(x.keyTakeaways).prefix(5))
        item.people = TextFold.uniqueNames(item.people + x.people)
        item.projects = TextFold.uniqueNames(item.projects + x.projects, limit: 10)
        item.topics = TextFold.uniqueNames(x.topics, limit: 5)
        item.tags = TextFold.uniqueNames((item.tags + x.tags).map { $0.lowercased().replacingOccurrences(of: " ", with: "-") }, limit: 10)
        item.moments = x.moments(keeping: item.moments)
        if let page {
            if item.imageURL == nil { item.imageURL = page.imageURL }
            item.extractedText = page.text
            if item.capturedFrom == nil, let site = page.siteName { item.capturedFrom = site }
        }
        let extracted = x.extractedText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !extracted.isEmpty, item.kind != .link {
            item.extractedText = TextFold.cap(extracted, LinkFetcher.maxTextCharacters)
        }
    }
}
