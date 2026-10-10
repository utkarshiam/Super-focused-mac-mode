import Accelerate
import Foundation

/// Deterministic clustering for the taxonomy. Pure functions over unit-length row vectors (`n × d` floats,
/// row-major); the same input always gives the same clusters.
///
/// - Up to `directLimit` rows: average-linkage agglomerative clustering on the full cosine-similarity matrix
///   (Lance–Williams updates, best-partner caches; about O(n²)).
/// - Above it: spherical k-means (k-means++ seeded by a fixed seed) into micro-clusters first, then the same
///   agglomerative step on their centroids, weighted by size.
///
/// Groups merge while the best pair is at least `floor` similar (natural structure), and beyond that while
/// there are more than `target` groups (a cap, so a big library doesn't get hundreds of topics). The default
/// floor is relative to the data (mean + `floorDeviations` × standard deviation of all pairwise similarities),
/// so it works for any embedding model, and for the word vectors used without one. Pass `floor: .infinity` to
/// get exactly `target` groups.
public enum BrainClustering {
    public static let directLimit = 1500

    /// One clustering.
    public struct Result: Sendable {
        /// Row indices per cluster, biggest first (ties: smallest first index).
        public var clusters: [[Int]]
        /// Rows left in clusters smaller than `minSize`.
        public var leftovers: [Int]
        /// The similarity floor used.
        public var floor: Float
        /// Mean and standard deviation of pairwise similarities (the floor is derived from these).
        public var mean: Float
        public var deviation: Float
    }

    /// About how many topics a library of `n` items should have: √n × 1.3, between 2 and 60.
    public static func targetTopics(for n: Int) -> Int {
        max(2, min(60, Int((Double(n).squareRoot() * 1.3).rounded())))
    }

    /// The smallest group that makes a topic: 2, growing slowly with the library (n / 200).
    public static func minTopicSize(for n: Int) -> Int { max(2, n / 200) }

    /// Clusters `n` unit rows of `d` floats.
    public static func cluster(_ rows: [Float], n: Int, d: Int, target: Int, minSize: Int,
                               floorDeviations: Float = 0.25, floor fixedFloor: Float? = nil) -> Result {
        guard n > 0, d > 0, rows.count == n * d else { return Result(clusters: [], leftovers: [], floor: 0, mean: 0, deviation: 0) }
        if n == 1 { return Result(clusters: minSize <= 1 ? [[0]] : [], leftovers: minSize <= 1 ? [] : [0], floor: 0, mean: 0, deviation: 0) }

        var groups: [[Int]]
        var sims: [Float]
        var sizes: [Int]
        let stats: (mean: Float, deviation: Float)
        if n <= directLimit {
            groups = (0..<n).map { [$0] }
            sims = similarityMatrix(rows, n: n, d: d)
            sizes = [Int](repeating: 1, count: n)
            stats = pairStats(sims, n: n)
        } else {
            let m = min(600, max(target * 4, n / 8))
            let km = kmeans(rows, n: n, d: d, k: m, iterations: 8, seed: 0xB2A1)
            var members = [[Int]](repeating: [], count: m)
            for (row, c) in km.assignment.enumerated() { members[c].append(row) }
            let keep = members.indices.filter { !members[$0].isEmpty }
            groups = keep.map { members[$0] }
            var centroids = [Float]()
            centroids.reserveCapacity(keep.count * d)
            for c in keep { centroids.append(contentsOf: km.centroids[c * d ..< (c + 1) * d]) }
            sims = similarityMatrix(centroids, n: keep.count, d: d)
            sizes = groups.map(\.count)
            stats = sampledPairStats(rows, n: n, d: d)
        }
        let floor = fixedFloor ?? (stats.mean + floorDeviations * stats.deviation)
        let merged = agglomerate(sims: &sims, sizes: sizes, target: target, floor: floor)
        var clusters = merged.map { $0.flatMap { groups[$0] }.sorted() }
        clusters.sort { ($0.count, -($0.first ?? 0)) > ($1.count, -($1.first ?? 0)) }
        let leftovers = clusters.filter { $0.count < minSize }.flatMap { $0 }.sorted()
        clusters.removeAll { $0.count < minSize }
        return Result(clusters: clusters, leftovers: leftovers, floor: floor, mean: stats.mean, deviation: stats.deviation)
    }

    // MARK: Agglomerative

    /// Average-linkage merging on an `m × m` similarity matrix (modified in place): merges while the best pair is
    /// at least `floor` similar, then while more than `target` groups remain. Returns groups of indices.
    static func agglomerate(sims: inout [Float], sizes initial: [Int], target: Int, floor: Float) -> [[Int]] {
        let m = initial.count
        guard m > 1 else { return m == 1 ? [[0]] : [] }
        var size = initial
        var active = [Bool](repeating: true, count: m)
        var members: [[Int]] = (0..<m).map { [$0] }
        var best = [Int](repeating: -1, count: m)
        var bestSim = [Float](repeating: -.infinity, count: m)
        func rescan(_ i: Int) {
            var b = -1
            var s: Float = -.infinity
            let base = i * m
            for j in 0..<m where j != i && active[j] {
                let v = sims[base + j]
                if v > s { s = v; b = j }
            }
            best[i] = b
            bestSim[i] = s
        }
        for i in 0..<m { rescan(i) }
        var count = m
        while count > 1 {
            var i = -1
            var s: Float = -.infinity
            for k in 0..<m where active[k] && best[k] >= 0 && bestSim[k] > s { s = bestSim[k]; i = k }
            guard i >= 0, s >= floor || count > max(1, target) else { break }
            let j = best[i]
            let a = min(i, j), b = max(i, j)
            let wa = Float(size[a]), wb = Float(size[b])
            for k in 0..<m where active[k] && k != a && k != b {
                let v = (wa * sims[a * m + k] + wb * sims[b * m + k]) / (wa + wb)
                sims[a * m + k] = v
                sims[k * m + a] = v
            }
            size[a] += size[b]
            active[b] = false
            members[a] += members[b]
            members[b] = []
            count -= 1
            rescan(a)
            for k in 0..<m where active[k] && k != a {
                if best[k] == a || best[k] == b { rescan(k) }
                else if sims[k * m + a] > bestSim[k] || (sims[k * m + a] == bestSim[k] && a < best[k]) {
                    best[k] = a
                    bestSim[k] = sims[k * m + a]
                }
            }
        }
        return (0..<m).filter { active[$0] }.map { members[$0] }
    }

    // MARK: Similarities

    /// `rows × rowsᵀ` (cosine for unit rows).
    static func similarityMatrix(_ rows: [Float], n: Int, d: Int) -> [Float] {
        var out = [Float](repeating: 0, count: n * n)
        rows.withUnsafeBufferPointer { a in
            out.withUnsafeMutableBufferPointer { c in
                // (n × d) · (d × n): transpose by passing rows as column-major d × n.
                cblasLikeGram(a.baseAddress!, n: n, d: d, out: c.baseAddress!)
            }
        }
        return out
    }

    /// Gram matrix via vDSP (row-major): out[i*n + j] = rows_i · rows_j.
    private static func cblasLikeGram(_ a: UnsafePointer<Float>, n: Int, d: Int, out: UnsafeMutablePointer<Float>) {
        // Transposed copy (d × n) so a single vDSP_mmul computes (n × d) · (d × n).
        var t = [Float](repeating: 0, count: n * d)
        t.withUnsafeMutableBufferPointer { tp in
            vDSP_mtrans(a, 1, tp.baseAddress!, 1, vDSP_Length(d), vDSP_Length(n))
            vDSP_mmul(a, 1, tp.baseAddress!, 1, out, 1, vDSP_Length(n), vDSP_Length(n), vDSP_Length(d))
        }
    }

    /// Mean and standard deviation of the off-diagonal entries.
    static func pairStats(_ sims: [Float], n: Int) -> (mean: Float, deviation: Float) {
        guard n > 1 else { return (0, 0) }
        var sum: Double = 0, sumSq: Double = 0
        for i in 0..<n {
            let base = i * n
            for j in (i + 1)..<n {
                let v = Double(sims[base + j])
                sum += v
                sumSq += v * v
            }
        }
        let count = Double(n * (n - 1) / 2)
        let mean = sum / count
        return (Float(mean), Float(max(0, sumSq / count - mean * mean).squareRoot()))
    }

    /// Pair statistics from a deterministic sample of rows (for big inputs).
    static func sampledPairStats(_ rows: [Float], n: Int, d: Int, sample: Int = 600) -> (mean: Float, deviation: Float) {
        let step = max(1, n / sample)
        let picked = Array(stride(from: 0, to: n, by: step).prefix(sample))
        var sub = [Float]()
        sub.reserveCapacity(picked.count * d)
        for r in picked { sub.append(contentsOf: rows[r * d ..< (r + 1) * d]) }
        return pairStats(similarityMatrix(sub, n: picked.count, d: d), n: picked.count)
    }

    // MARK: k-means

    /// Spherical k-means with k-means++ seeding from a fixed seed. Returns each row's cluster and the unit centroids.
    static func kmeans(_ rows: [Float], n: Int, d: Int, k requested: Int, iterations: Int, seed: UInt64) -> (assignment: [Int], centroids: [Float]) {
        let k = max(1, min(requested, n))
        var rng = SeedRandom(seed: seed)
        var centroids = [Float](repeating: 0, count: k * d)
        // k-means++: first centroid is row 0's neighbour by seed; the rest by D² sampling.
        var chosen = [Int(rng.next() % UInt64(n))]
        var distance = [Float](repeating: .infinity, count: n)
        func updateDistances(from c: Int) {
            let crow = Array(rows[c * d ..< (c + 1) * d])
            let s = scores(rows, n: n, d: d, query: crow)
            for i in 0..<n { distance[i] = min(distance[i], max(0, 1 - s[i])) }
        }
        updateDistances(from: chosen[0])
        while chosen.count < k {
            let total = distance.reduce(0) { $0 + Double($1 * $1) }
            var pick = 0
            if total > 0 {
                var target = rng.nextUnit() * total
                for i in 0..<n {
                    target -= Double(distance[i] * distance[i])
                    if target <= 0 { pick = i; break }
                }
            } else {
                pick = chosen.count % n
            }
            chosen.append(pick)
            updateDistances(from: pick)
        }
        for (c, r) in chosen.enumerated() { centroids.replaceSubrange(c * d ..< (c + 1) * d, with: rows[r * d ..< (r + 1) * d]) }

        var assignment = [Int](repeating: 0, count: n)
        for _ in 0..<max(1, iterations) {
            // Assign: (n × d) · (d × k).
            var s = [Float](repeating: 0, count: n * k)
            var t = [Float](repeating: 0, count: d * k)
            centroids.withUnsafeBufferPointer { cp in
                t.withUnsafeMutableBufferPointer { tp in vDSP_mtrans(cp.baseAddress!, 1, tp.baseAddress!, 1, vDSP_Length(d), vDSP_Length(k)) }
            }
            rows.withUnsafeBufferPointer { a in
                t.withUnsafeBufferPointer { b in
                    s.withUnsafeMutableBufferPointer { c in
                        vDSP_mmul(a.baseAddress!, 1, b.baseAddress!, 1, c.baseAddress!, 1, vDSP_Length(n), vDSP_Length(k), vDSP_Length(d))
                    }
                }
            }
            var changed = false
            for i in 0..<n {
                var bestC = 0
                var bestS = -Float.infinity
                let base = i * k
                for c in 0..<k where s[base + c] > bestS { bestS = s[base + c]; bestC = c }
                if assignment[i] != bestC { assignment[i] = bestC; changed = true }
            }
            // Update: mean of members, normalised; an empty cluster keeps its centroid.
            var sums = [Float](repeating: 0, count: k * d)
            var counts = [Int](repeating: 0, count: k)
            for i in 0..<n {
                let c = assignment[i]
                counts[c] += 1
                for j in 0..<d { sums[c * d + j] += rows[i * d + j] }
            }
            for c in 0..<k where counts[c] > 0 {
                if let unit = VectorIndex.normalized(Array(sums[c * d ..< (c + 1) * d])) {
                    centroids.replaceSubrange(c * d ..< (c + 1) * d, with: unit)
                }
            }
            if !changed { break }
        }
        return (assignment, centroids)
    }

    /// Dot products of every row with `query`.
    static func scores(_ rows: [Float], n: Int, d: Int, query: [Float]) -> [Float] {
        var out = [Float](repeating: 0, count: n)
        rows.withUnsafeBufferPointer { a in
            query.withUnsafeBufferPointer { b in
                out.withUnsafeMutableBufferPointer { c in
                    vDSP_mmul(a.baseAddress!, 1, b.baseAddress!, 1, c.baseAddress!, 1, vDSP_Length(n), 1, vDSP_Length(d))
                }
            }
        }
        return out
    }

    /// The unit mean of some rows (nil when they cancel out or there are none).
    static func centroid(_ rows: [Float], d: Int, of indices: [Int]) -> [Float]? {
        guard !indices.isEmpty else { return nil }
        var sum = [Float](repeating: 0, count: d)
        for i in indices {
            rows.withUnsafeBufferPointer { r in
                vDSP_vadd(sum, 1, r.baseAddress! + i * d, 1, &sum, 1, vDSP_Length(d))
            }
        }
        return VectorIndex.normalized(sum)
    }

    // MARK: Word vectors (no embeddings)

    /// Hashed TF-IDF vectors for `items` (see `WordSpace`). Unit rows; `hasWords[i]` is false for an item
    /// with no usable words (its row is zero).
    public static func wordVectors(_ items: [MemoryItem], dimensions d: Int = WordSpace.defaultDimensions) -> (rows: [Float], hasWords: [Bool]) {
        let space = WordSpace(items: items, dimensions: d)
        var rows = [Float](repeating: 0, count: items.count * d)
        var has = [Bool](repeating: false, count: items.count)
        for (i, item) in items.enumerated() {
            if let v = space.vector(item) {
                rows.replaceSubrange(i * d ..< (i + 1) * d, with: v)
                has[i] = true
            }
        }
        return (rows, has)
    }
}

/// The space used to cluster without embeddings: hashed TF-IDF over an item's labels and words. Topic labels
/// weigh most, then tags and projects, then the title, then the summary and takeaways (or the start of the
/// text). Document frequencies come from the items it was built from.
public struct WordSpace: Sendable {
    public static let defaultDimensions = 384
    public let dimensions: Int
    let documentFrequency: [String: Int]
    let documentCount: Int

    public init(items: [MemoryItem], dimensions: Int = WordSpace.defaultDimensions) {
        var df: [String: Int] = [:]
        for item in items { for w in Self.terms(item).keys { df[w, default: 0] += 1 } }
        self.dimensions = dimensions
        documentFrequency = df
        documentCount = items.count
    }

    /// Weighted terms of an item (singular forms).
    static func terms(_ item: MemoryItem) -> [String: Float] {
        var tf: [String: Float] = [:]
        func add(_ text: String, _ weight: Float) {
            for w in TextFold.words(text) where w.count > 2 && !TextFold.stopwords.contains(w) && !w.allSatisfy(\.isNumber) {
                tf[EntityNames.singular(w), default: 0] += weight
            }
        }
        for t in item.topics { add(t, 3) }
        for t in item.tags { add(t.replacingOccurrences(of: "-", with: " "), 2) }
        for p in item.projects { add(p, 2) }
        for o in item.organisations { add(o, 1) }
        add(item.displayTitle, 1.5)
        if !item.summary.isEmpty || !item.keyTakeaways.isEmpty {
            add(item.summary, 1)
            for k in item.keyTakeaways { add(k, 0.8) }
        } else {
            add(TextFold.cap(item.fullText, 600), 0.7)
        }
        return tf
    }

    /// The item's unit vector, or nil when it has no usable words.
    public func vector(_ item: MemoryItem) -> [Float]? {
        let n = Float(max(1, documentCount))
        var v = [Float](repeating: 0, count: dimensions)
        for (w, f) in Self.terms(item) {
            let docFreq = Float(max(1, documentFrequency[w] ?? 1))
            // A word in (almost) every item says nothing about which topic it's in.
            if docFreq >= n && n >= 3 { continue }
            let idf = log(1 + n / docFreq)
            let h = BrainIDs.hash(w)
            let sign: Float = (h >> 32) & 1 == 0 ? 1 : -1
            v[Int(h % UInt64(dimensions))] += sign * (1 + log(max(f, 0.5))) * idf
        }
        return VectorIndex.normalized(v)
    }

    /// The most distinctive words of some items (for naming without AI), best first.
    func topWords(_ items: [MemoryItem], limit: Int) -> [String] {
        var score: [String: Float] = [:]
        let n = Float(max(1, documentCount))
        for item in items {
            for (w, f) in Self.terms(item) {
                let docFreq = Float(max(1, documentFrequency[w] ?? 1))
                score[w, default: 0] += f * log(1 + n / docFreq)
            }
        }
        return score.sorted { ($0.value, $1.key) > ($1.value, $0.key) }.prefix(limit).map(\.key)
    }
}
