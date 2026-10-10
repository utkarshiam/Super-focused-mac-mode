import Foundation

/// Writes living pages: for one entity, one AI call over its items (numbered) that returns a summary with
/// [n] citations, key facts, open questions and disagreements, all mapped to item ids. Incremental: the
/// previous summary is passed in to be updated, and items saved since the last page are marked NEW.
/// The user's own text is kept: an edited summary is never replaced, and pinned or user-written key facts
/// stay (AI facts that repeat them are dropped).
public struct EntitySynthesizer: Sendable {
    public var ai: MemoryAI
    public var now: @Sendable () -> Date
    /// Items in one prompt (pinned first, then the newest; shown oldest first).
    public var itemLimit = 24

    public init(ai: MemoryAI, now: @escaping @Sendable () -> Date = { Date() }) {
        self.ai = ai
        self.now = now
    }

    /// Whether an entity's page is due: enough items, and new or changed items since the last page, but not
    /// more often than `minInterval` unless `burst` items arrived; a failure waits an hour.
    public static func isStale(_ entity: BrainEntity, latestItemChange: Date?, minimumItems: Int = 2,
                               minInterval: TimeInterval = 6 * 3600, burst: Int = 3, now: Date) -> Bool {
        guard entity.kind != .area, entity.itemCount >= minimumItems else { return false }
        if let failed = entity.synthesisFailedAt, now.timeIntervalSince(failed) < 3600 { return false }
        guard let at = entity.synthesizedAt else { return true }
        let changed = entity.itemCount != entity.itemCountAtSynthesis || (latestItemChange ?? .distantPast) > at
        guard changed else { return false }
        if abs(entity.itemCount - entity.itemCountAtSynthesis) >= burst { return true }
        return now.timeIntervalSince(at) >= minInterval
    }

    /// The items for the prompt: pinned first, then the newest, at most `itemLimit`; returned oldest first.
    public func pickItems(_ items: [MemoryItem]) -> [MemoryItem] {
        let pinned = items.filter(\.pinned).sorted { $0.createdAt > $1.createdAt }.prefix(itemLimit / 3)
        var out = Array(pinned)
        for item in items.sorted(by: { $0.createdAt > $1.createdAt }) where out.count < itemLimit && !item.pinned { out.append(item) }
        return out.sorted { $0.createdAt != $1.createdAt ? $0.createdAt < $1.createdAt : $0.id.uuidString < $1.id.uuidString }
    }

    /// One page. `items` are the entity's items (any order). Throws `MemoryAIError` (or cancellation).
    public func synthesize(_ entity: BrainEntity, items: [MemoryItem], parentName: String?, lenses: [Lens],
                           profile: MemoryProfile) async throws -> BrainPrompts.SynthesisAnswer {
        let picked = pickItems(items)
        guard !picked.isEmpty else { throw MemoryAIError.badResponse("There's nothing to write about yet.") }
        let system = BrainPrompts.synthesisSystem(kind: entity.kind, lenses: lenses, profile: profile, now: now())
        let prompt = BrainPrompts.synthesisPrompt(entity: entity, parentName: parentName, items: picked, newSince: entity.synthesizedAt,
                                                  vocabulary: Lens.vocabulary(for: lenses), now: now())
        let data = try await ai.generateJSON(system: system, prompt: prompt, schema: BrainPrompts.synthesisSchema)
        return try BrainPrompts.parseSynthesis(data, items: picked)
    }

    /// Writes an answer onto an entity, keeping the user's text.
    public static func apply(_ answer: BrainPrompts.SynthesisAnswer, to entity: inout BrainEntity, itemCount: Int, at date: Date) {
        if !entity.summaryEditedByUser {
            entity.summary = answer.summary
            entity.summarySources = answer.summarySources
        }
        let kept = entity.keyFacts.filter(\.isKept)
        let keptKeys = Set(kept.map { TextFold.words($0.text).joined(separator: " ") })
        // An AI fact that comes back unchanged keeps its id (so a pin made in the meantime isn't lost).
        let previousAI = entity.keyFacts.filter { !$0.isKept }
        var facts = kept
        for var fact in answer.keyFacts {
            let k = TextFold.words(fact.text).joined(separator: " ")
            guard !keptKeys.contains(k) else { continue }
            if let same = previousAI.first(where: { TextFold.words($0.text).joined(separator: " ") == k }) { fact.id = same.id }
            facts.append(fact)
        }
        entity.keyFacts = facts
        entity.openQuestions = answer.openQuestions
        let keptDisagreements = entity.disagreements.filter(\.isKept)
        entity.disagreements = keptDisagreements + answer.disagreements.filter { d in
            !keptDisagreements.contains { TextFold.fold($0.text) == TextFold.fold(d.text) }
        }
        entity.synthesizedAt = date
        entity.itemCountAtSynthesis = itemCount
        entity.synthesisFailedAt = nil
        entity.updatedAt = date
    }
}

extension MemoryBrain {
    /// Entities whose living page is due (see `EntitySynthesizer.isStale`), most items first.
    public func staleEntities(limit: Int = 50) -> [BrainEntity] {
        let stamp = now()
        var out: [BrainEntity] = []
        for e in state.entities.sorted(by: Self.byWeight) where e.kind != .area && e.itemCount >= synthesisMinimumItems {
            let latest = itemIDs(for: e.id).compactMap { library.item($0)?.updatedAt }.max()
            if EntitySynthesizer.isStale(e, latestItemChange: latest, minimumItems: synthesisMinimumItems,
                                         minInterval: synthesisMinInterval, burst: synthesisBurst, now: stamp) {
                out.append(e)
                if out.count == limit { break }
            }
        }
        return out
    }

    /// Writes up to `limit` due living pages, two at a time. Safe to call often (does nothing when nothing is
    /// due or a run is in progress). Failures are kept in `lastError` and the entity waits an hour. Returns how
    /// many pages were written.
    @discardableResult
    public func synthesizeStale(ai: MemoryAI, limit: Int = 4) async -> Int {
        guard !synthesizing else { return 0 }
        let due = staleEntities(limit: limit)
        guard !due.isEmpty else { return 0 }
        synthesizing = true
        setWorking(true)
        defer {
            synthesizing = false
            setWorking(organizing)
        }
        var written = 0
        var queue = due.map(\.id)
        while !queue.isEmpty {
            let batch = Array(queue.prefix(2))
            queue.removeFirst(batch.count)
            let results = await withTaskGroup(of: (UUID, Result<BrainPrompts.SynthesisAnswer, Error>, Int).self) { group in
                for id in batch {
                    guard let job = synthesisJob(id, ai: ai) else { continue }
                    group.addTask {
                        do { return (id, .success(try await job.run()), job.itemCount) } catch { return (id, .failure(error), job.itemCount) }
                    }
                }
                var out: [(UUID, Result<BrainPrompts.SynthesisAnswer, Error>, Int)] = []
                for await r in group { out.append(r) }
                return out.sorted { $0.0.uuidString < $1.0.uuidString }
            }
            for (id, result, count) in results {
                switch result {
                case .success(let answer):
                    updateEntity(id) { EntitySynthesizer.apply(answer, to: &$0, itemCount: count, at: now()) }
                    written += 1
                    setError(nil)
                case .failure(let error):
                    if error is CancellationError { continue }
                    let failure = (error as? MemoryAIError) ?? .badResponse(error.localizedDescription)
                    updateEntity(id) { $0.synthesisFailedAt = now() }
                    setError(failure)
                    // Offline or a bad key: everything else would fail the same way.
                    if failure.isTransient || failure.needsSettings { queue.removeAll() }
                }
            }
            if !results.isEmpty { didChange() }
        }
        return written
    }

    /// Writes one entity's page now (the "Refresh page" action). Throws the AI error.
    public func synthesize(_ id: UUID, ai: MemoryAI) async throws {
        guard let job = synthesisJob(id, ai: ai) else { return }
        do {
            let answer = try await job.run()
            updateEntity(id) { EntitySynthesizer.apply(answer, to: &$0, itemCount: job.itemCount, at: now()) }
            setError(nil)
            didChange()
        } catch {
            updateEntity(id) { $0.synthesisFailedAt = now() }
            didChange()
            throw error
        }
    }

    struct SynthesisJob: Sendable {
        var synthesizer: EntitySynthesizer
        var entity: BrainEntity
        var items: [MemoryItem]
        var parentName: String?
        var lenses: [Lens]
        var profile: MemoryProfile
        var itemCount: Int

        func run() async throws -> BrainPrompts.SynthesisAnswer {
            try await synthesizer.synthesize(entity, items: items, parentName: parentName, lenses: lenses, profile: profile)
        }
    }

    func synthesisJob(_ id: UUID, ai: MemoryAI) -> SynthesisJob? {
        guard let e = entity(id) else { return nil }
        let items = items(for: id)
        guard !items.isEmpty else { return nil }
        let clock = now()
        return SynthesisJob(synthesizer: EntitySynthesizer(ai: ai, now: { clock }), entity: e, items: items,
                            parentName: e.parentID.flatMap(entity)?.name, lenses: library.lenses, profile: library.profile,
                            itemCount: items.count)
    }
}
