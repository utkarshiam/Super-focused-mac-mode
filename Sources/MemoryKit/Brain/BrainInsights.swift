import Foundation

/// "Connections you haven't made" and the weekly digest. Pure functions over items; `MemoryBrain` feeds them.
public enum BrainInsights {
    // MARK: Connections

    /// What the connection finder needs to know about one item.
    public struct ItemInfo: Sendable {
        public var item: MemoryItem
        public var primaryTopic: UUID?
        /// People, organisations and projects it mentions.
        public var entities: Set<UUID>

        public init(item: MemoryItem, primaryTopic: UUID?, entities: Set<UUID>) {
            self.item = item
            self.primaryTopic = primaryTopic
            self.entities = entities
        }
    }

    /// Pairs of items from different primary topics that are close in meaning but share no person,
    /// organisation or project, and haven't been shown before. Recent items (the newest `recentLimit`) are
    /// compared with everything. A pair has to stand out for its items (at least mean + 2.5 σ of each recent
    /// item's similarities to items in other topics, so two topics that are merely related don't produce links)
    /// and overall (mean + 1 σ of all compared pairs, and `minimum`). Best first, at most `limit`, one per item.
    public static func findConnections(_ infos: [ItemInfo], vectors: VectorIndex, seen: Set<String>, limit: Int = 5,
                                       recentLimit: Int = 150, minimum: Float = 0.3) -> [(a: UUID, b: UUID, score: Float)] {
        let byID = Dictionary(infos.map { ($0.item.id, $0) }, uniquingKeysWith: { a, _ in a })
        let recent = infos.filter { vectors.contains($0.item.id) && $0.primaryTopic != nil }
            .sorted { $0.item.createdAt != $1.item.createdAt ? $0.item.createdAt > $1.item.createdAt : $0.item.id.uuidString < $1.item.id.uuidString }
            .prefix(recentLimit)
        var candidates: [(a: UUID, b: UUID, score: Float, bar: Float)] = []
        var sum: Double = 0, sumSq: Double = 0, count = 0
        var bars: [UUID: Float] = [:]
        for info in recent {
            guard let v = vectors.vector(for: info.item.id) else { continue }
            let scores = vectors.scores(for: v)
            var mine: [(UUID, Float, Bool)] = []
            for (row, s) in scores.enumerated() {
                let other = vectors.ids[row]
                guard other != info.item.id, let o = byID[other], let ot = o.primaryTopic, ot != info.primaryTopic else { continue }
                let eligible = info.entities.isDisjoint(with: o.entities) && !seen.contains(BrainConnection.pairKey(info.item.id, other))
                mine.append((other, s, eligible))
            }
            guard mine.count >= 3 else { continue }
            let m = mine.reduce(0) { $0 + Double($1.1) } / Double(mine.count)
            let dev = (mine.reduce(0) { $0 + (Double($1.1) - m) * (Double($1.1) - m) } / Double(mine.count)).squareRoot()
            bars[info.item.id] = Float(m + 2.5 * dev)
            for (other, s, eligible) in mine {
                sum += Double(s); sumSq += Double(s) * Double(s); count += 1
                if eligible { candidates.append((info.item.id, other, s, Float(m + 2.5 * dev))) }
            }
        }
        guard count > 0 else { return [] }
        let mean = sum / Double(count)
        let global = Float(mean + (max(0, sumSq / Double(count) - mean * mean)).squareRoot())
        candidates.sort { ($0.score, BrainConnection.pairKey($1.a, $1.b)) > ($1.score, BrainConnection.pairKey($0.a, $0.b)) }
        var out: [(a: UUID, b: UUID, score: Float)] = []
        var used = Set<UUID>()
        var pairs = Set<String>()
        // When both items are recent, the pair has to stand out for each of them.
        for c in candidates where c.score >= max(minimum, global, c.bar, bars[c.b] ?? -1) {
            guard !used.contains(c.a), !used.contains(c.b), pairs.insert(BrainConnection.pairKey(c.a, c.b)).inserted else { continue }
            out.append((c.a, c.b, c.score))
            used.insert(c.a)
            used.insert(c.b)
            if out.count == limit { break }
        }
        return out
    }

    /// A reason without AI: the words both items share ("Both mention retention and digest.").
    public static func sharedTermsReason(_ a: MemoryItem, _ b: MemoryItem) -> String {
        func terms(_ item: MemoryItem) -> [String: Float] { WordSpace.terms(item) }
        let ta = terms(a), tb = terms(b)
        let shared = ta.keys.filter { tb[$0] != nil }.sorted { (ta[$0]! + tb[$0]!, $1) > (ta[$1]! + tb[$1]!, $0) }.prefix(3)
        guard !shared.isEmpty else { return "Close in meaning, though they share no people or projects." }
        let list = shared.count == 1 ? shared[0] : shared.dropLast().joined(separator: ", ") + " and " + shared.last!
        return "Both mention \(list)."
    }

    // MARK: Digest

    /// Monday 00:00 of the week holding `date`, and the following Monday.
    public static func week(of date: Date, calendar: Calendar = .current) -> (start: Date, end: Date) {
        var cal = calendar
        cal.firstWeekday = 2
        let start = cal.dateInterval(of: .weekOfYear, for: date)?.start ?? cal.startOfDay(for: date)
        let end = cal.date(byAdding: .day, value: 7, to: start) ?? start.addingTimeInterval(7 * 86_400)
        return (start, end)
    }

    /// "What you learned, 5–11 Oct" (see `weekRange`).
    public static func digestTitle(start: Date, end: Date, now: Date = Date(), calendar: Calendar = .current,
                                   locale: Locale = .current) -> String {
        "What you learned, " + weekRange(start: start, end: end, now: now, calendar: calendar, locale: locale)
    }

    /// The days from `start` to the day before `end`, always day first like the rest of Docket: "5–11 Oct",
    /// "28 Sep – 4 Oct" across months, "29 Dec 2025 – 4 Jan 2026" across years, and "5–11 Oct 2025" when the
    /// week isn't in `now`'s year. Month names follow `locale`; the order never does.
    public static func weekRange(start: Date, end: Date, now: Date = Date(), calendar: Calendar = .current,
                                 locale: Locale = .current) -> String {
        let last = calendar.date(byAdding: .day, value: -1, to: end) ?? end
        let startYear = calendar.component(.year, from: start), lastYear = calendar.component(.year, from: last)
        let sameMonth = startYear == lastYear && calendar.component(.month, from: start) == calendar.component(.month, from: last)
        let thisYear = lastYear == calendar.component(.year, from: now)
        func format(_ pattern: String, _ date: Date) -> String {
            let f = DateFormatter()
            f.calendar = calendar
            f.timeZone = calendar.timeZone
            f.locale = locale
            f.dateFormat = pattern
            return f.string(from: date)
        }
        let endText = format(thisYear ? "d MMM" : "d MMM yyyy", last)
        if sameMonth { return "\(format("d", start))–\(endText)" }
        return "\(format(startYear == lastYear ? "d MMM" : "d MMM yyyy", start)) – \(endText)"
    }

    /// The week's digest as structure (no AI): items saved, new topics, busiest topics, decisions, open
    /// promises and the best current connection.
    public static func digest(week date: Date, items: [MemoryItem], topics: [BrainEntity], topicItems: (UUID) -> Set<UUID>,
                              connections: [BrainConnection], now: Date, calendar: Calendar = .current) -> BrainDigest {
        let (start, end) = week(of: date, calendar: calendar)
        let inWeek = items.filter { $0.createdAt >= start && $0.createdAt < end }
        let weekIDs = Set(inWeek.map(\.id))
        let newTopics = topics.filter { $0.createdAt >= start && $0.createdAt < end && $0.itemCount > 0 }
            .sorted(by: MemoryBrain.byWeight).prefix(5)
            .map { DigestTopic(topicID: $0.id, name: $0.name, count: topicItems($0.id).intersection(weekIDs).count) }
        let busiest = topics.map { t in (t, topicItems(t.id).intersection(weekIDs).count) }
            .filter { $0.1 > 0 && ($0.0.parentID.map { id in !topics.contains { $0.id == id } } ?? true) }
            .sorted { ($0.1, $1.0.name) > ($1.1, $0.0.name) }.prefix(3)
            .map { DigestTopic(topicID: $0.0.id, name: $0.0.name, count: $0.1) }
        var decisions: [DigestMoment] = []
        var promises: [DigestMoment] = []
        for item in inWeek.sorted(by: { $0.createdAt > $1.createdAt }) {
            for m in item.moments {
                let dm = DigestMoment(momentID: m.id, itemID: item.id, kind: m.kind, text: m.text, who: m.who, due: m.due)
                if m.kind == .decision { decisions.append(dm) }
                if m.kind == .promise && !m.done { promises.append(dm) }
            }
        }
        promises.sort { ($0.due ?? .distantFuture) < ($1.due ?? .distantFuture) }
        let connection = connections.first { !$0.dismissed && (weekIDs.contains($0.a) || weekIDs.contains($0.b)) }
            ?? connections.first { !$0.dismissed }
        return BrainDigest(weekStart: start, weekEnd: end, title: digestTitle(start: start, end: end, now: now, calendar: calendar),
                           itemCount: inWeek.count, newTopics: Array(newTopics), biggestTopics: Array(busiest),
                           decisions: Array(decisions.prefix(6)), openPromises: Array(promises.prefix(6)),
                           connection: connection, generatedAt: now)
    }
}

extension MemoryBrain {
    // MARK: Connections

    /// Looks for new connections when due (at most every `connectionsInterval`, or `force`). With AI each gets a
    /// one-line reason (pairs AI finds unrelated are dropped); without, the shared words. Shown pairs are
    /// remembered and never shown again. Returns the new connections.
    @discardableResult
    public func refreshConnections(ai: MemoryAI?, force: Bool = false) async -> [BrainConnection] {
        if !force, let at = state.connectionsAt, now().timeIntervalSince(at) < connectionsInterval { return [] }
        let vectors = library.vectors
        guard !vectors.isEmpty, state.taxonomy.organizedAt != nil else { return [] }
        let infos = library.items.map { item in
            BrainInsights.ItemInfo(item: item, primaryTopic: state.taxonomy.primary(of: item.id),
                                   entities: Set(entities(for: item.id).filter { $0.kind.isExtracted }.map(\.id)))
        }
        let seen = Set(state.seenPairs)
        let found = await Task.detached(priority: .utility) {
            BrainInsights.findConnections(infos, vectors: vectors, seen: seen)
        }.value
        let stamp = now()
        var fresh: [BrainConnection] = found.compactMap { f in
            guard let a = library.item(f.a), let b = library.item(f.b) else { return nil }
            return BrainConnection(a: f.a, b: f.b, score: (Double(f.score) * 1000).rounded() / 1000,
                                   reason: BrainInsights.sharedTermsReason(a, b), foundAt: stamp)
        }
        if let ai, !fresh.isEmpty {
            let pairs = fresh.compactMap { c -> (MemoryItem, MemoryItem)? in
                guard let a = library.item(c.a), let b = library.item(c.b) else { return nil }
                return (a, b)
            }
            do {
                let data = try await ai.generateJSON(system: BrainPrompts.connectionsSystem(lenses: library.lenses, now: stamp),
                                                     prompt: BrainPrompts.connectionsPrompt(pairs), schema: BrainPrompts.connectionsSchema)
                let reasons = try BrainPrompts.parseConnections(data, count: pairs.count)
                var kept: [BrainConnection] = []
                for (i, var c) in fresh.enumerated() {
                    guard let reason = reasons[i + 1] else { kept.append(c); continue }
                    if reason.isEmpty { continue }
                    c.reason = reason
                    kept.append(c)
                }
                fresh = kept
                setError(nil)
            } catch {
                // Keep the shared-words reasons; try AI again next time.
                setError((error as? MemoryAIError) ?? .badResponse(error.localizedDescription))
            }
        }
        state.connectionsAt = stamp
        for f in found { state.seenPairs.append(BrainConnection.pairKey(f.a, f.b)) }
        if state.seenPairs.count > BrainState.seenPairsLimit { state.seenPairs.removeFirst(state.seenPairs.count - BrainState.seenPairsLimit) }
        if !fresh.isEmpty {
            // Newest first; keep a short list (dismissed ones drop off).
            state.connections = Array((fresh + state.connections.filter { !$0.dismissed }).prefix(5))
            didChange()
        } else {
            didChangeQuietly()
        }
        return fresh
    }

    /// Hides a connection for good.
    public func dismissConnection(_ id: UUID) {
        guard let i = state.connections.firstIndex(where: { $0.id == id }) else { return }
        state.connections[i].dismissed = true
        didChange()
    }

    // MARK: Digest

    /// The digest for the week holding `date`: the AI-written one when it's current, else the structure
    /// (always available, no AI).
    public func digest(for date: Date) -> BrainDigest {
        let fresh = BrainInsights.digest(week: date, items: library.items, topics: allTopics(), topicItems: { self.topicItems($0) },
                                         connections: connections, now: now())
        if let cached = state.digests.first(where: { $0.weekStart == fresh.weekStart }), cached.itemCount == fresh.itemCount, cached.isWritten {
            var merged = fresh
            merged.text = cached.text
            merged.sources = cached.sources
            merged.generatedAt = cached.generatedAt
            return merged
        }
        return fresh
    }

    /// Has AI write the week's digest (and caches it). Without items that week, returns the empty structure.
    @discardableResult
    public func writeDigest(for date: Date, ai: MemoryAI) async throws -> BrainDigest {
        var d = digest(for: date)
        guard d.itemCount > 0 else { return d }
        let ids = Set(d.decisions.map(\.itemID) + d.openPromises.map(\.itemID) + [d.connection?.a, d.connection?.b].compactMap { $0 })
        var items = library.items.filter { $0.createdAt >= d.weekStart && $0.createdAt < d.weekEnd }
        items.sort { (ids.contains($0.id) ? 1 : 0, $0.pinned ? 1 : 0, $0.createdAt) > (ids.contains($1.id) ? 1 : 0, $1.pinned ? 1 : 0, $1.createdAt) }
        if let c = d.connection {
            for id in [c.a, c.b] where !items.contains(where: { $0.id == id }) { if let item = library.item(id) { items.append(item) } }
        }
        let picked = Array(items.prefix(20)).sorted { $0.createdAt < $1.createdAt }
        let stamp = now()
        let data = try await ai.generateJSON(system: BrainPrompts.digestSystem(lenses: library.lenses, profile: library.profile, now: stamp),
                                             prompt: BrainPrompts.digestPrompt(d, items: picked, now: stamp), schema: BrainPrompts.digestSchema)
        let parsed = try BrainPrompts.parseDigest(data, items: picked)
        d.text = parsed.text
        d.sources = parsed.sources
        d.generatedAt = stamp
        state.digests.removeAll { $0.weekStart == d.weekStart }
        state.digests.insert(d, at: 0)
        state.digests.sort { $0.weekStart > $1.weekStart }
        if state.digests.count > BrainState.digestLimit { state.digests.removeLast(state.digests.count - BrainState.digestLimit) }
        didChange()
        return d
    }
}
