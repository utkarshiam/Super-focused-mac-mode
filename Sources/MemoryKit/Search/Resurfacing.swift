import Foundation

/// An older item brought back, with why.
public struct ResurfacedItem: Identifiable, Hashable, Sendable {
    public enum Reason: String, Hashable, Sendable {
        /// Pinned, and not opened for a while.
        case pinned
        /// Close in meaning to what the user saved this week.
        case relatedToRecent
        /// Holds a promise that's still open.
        case openPromise
        /// Holds an idea nobody has looked at in a while.
        case idea
    }

    public var item: MemoryItem
    public var reason: Reason
    public var score: Double
    public var id: UUID { item.id }
}

extension MemoryLibrary {
    /// Items saved on this month and day in earlier years, newest first ("On this day").
    public func onThisDay(_ date: Date = Date(), calendar: Calendar = .current) -> [MemoryItem] {
        let target = calendar.dateComponents([.year, .month, .day], from: date)
        return items.filter { item in
            let c = calendar.dateComponents([.year, .month, .day], from: item.createdAt)
            return c.month == target.month && c.day == target.day && (c.year ?? 0) < (target.year ?? 0)
        }
    }

    /// Older items worth a second look: pinned ones not opened lately, ones close to this week's
    /// captures, open promises and forgotten ideas. Items opened in the last two weeks are left out.
    public func worthRevisiting(limit: Int = 5, now: Date = Date()) -> [ResurfacedItem] {
        Resurfacing.worthRevisiting(items, vectors: vectors, limit: limit, now: now)
    }
}

enum Resurfacing {
    static let day: TimeInterval = 86_400

    static func worthRevisiting(_ items: [MemoryItem], vectors: VectorIndex, limit: Int, now: Date) -> [ResurfacedItem] {
        // What the user has been saving this week, as one direction in vector space.
        let recent = items.filter { now.timeIntervalSince($0.createdAt) < 7 * day && $0.createdAt <= now }
        var centroid: [Float]?
        for item in recent {
            guard let v = vectors.vector(for: item.id) else { continue }
            if centroid == nil { centroid = v } else { for i in v.indices { centroid![i] += v[i] } }
        }
        let recentIDs = Set(recent.map(\.id))

        var out: [ResurfacedItem] = []
        for item in items {
            let age = now.timeIntervalSince(item.createdAt)
            guard age >= 14 * day, !recentIDs.contains(item.id) else { continue }
            if let viewed = item.lastViewedAt, now.timeIntervalSince(viewed) < 14 * day { continue }

            var best: (ResurfacedItem.Reason, Double)?
            func consider(_ reason: ResurfacedItem.Reason, _ score: Double) {
                if score > (best?.1 ?? 0) { best = (reason, score) }
            }
            if item.pinned { consider(.pinned, 0.8) }
            if let centroid, let v = vectors.vector(for: item.id) {
                let similarity = Double(VectorIndex.cosine(centroid, v))
                if similarity >= 0.55 { consider(.relatedToRecent, 0.5 + (similarity - 0.55) * 2) }
            }
            if item.moments.contains(where: { $0.kind == .promise && !$0.done && ($0.due.map { $0 < now } ?? true) }) {
                consider(.openPromise, 0.7)
            }
            if item.moments.contains(where: { $0.kind == .idea }) { consider(.idea, 0.45) }
            guard let (reason, score) = best else { continue }
            // Long-forgotten things come back a little more readily.
            let forgotten = min(0.15, age / (365 * day) * 0.1)
            out.append(ResurfacedItem(item: item, reason: reason, score: score + forgotten))
        }
        out.sort { $0.score != $1.score ? $0.score > $1.score : $0.item.createdAt > $1.item.createdAt }
        return Array(out.prefix(limit))
    }
}
