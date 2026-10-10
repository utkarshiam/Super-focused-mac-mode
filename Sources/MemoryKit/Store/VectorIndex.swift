import Accelerate
import Foundation

/// Every memory's embedding in one contiguous `[Float]` matrix (row per item, unit length), so a
/// search over 20 000 items is a single matrix-vector multiply. One model and dimension per index:
/// storing a vector from another model (or size) starts the index over, since mixed vectors can't be
/// compared. Value type and `Sendable`, so a copy can be searched off the main thread.
///
/// File format (`vectors.bin`, also published to the phone), all integers little-endian:
/// ```
/// bytes 0–3   magic "DMV1"
/// UInt32      dimensions
/// UInt32      count
/// UInt16      model name length in bytes, then the UTF-8 model name ("gemini-embedding-2")
/// count × 16  item ids (raw UUID bytes), row order
/// count × dimensions × Float32   the unit-length vectors, row after row
/// ```
public struct VectorIndex: Equatable, Sendable {
    public private(set) var model: String
    public private(set) var dimensions: Int
    /// Item ids in row order.
    public private(set) var ids: [UUID]
    /// `count × dimensions` floats; row `i` belongs to `ids[i]`. Rows are normalized to unit length.
    public private(set) var storage: [Float]
    private var rows: [UUID: Int]

    public init(model: String = "", dimensions: Int = 0) {
        self.model = model
        self.dimensions = dimensions
        ids = []
        storage = []
        rows = [:]
    }

    public var count: Int { ids.count }
    public var isEmpty: Bool { ids.isEmpty }

    public func contains(_ id: UUID) -> Bool { rows[id] != nil }

    /// Whether a query vector from this model and size can be compared with the stored ones.
    public func isCompatible(model: String, dimensions: Int) -> Bool {
        !isEmpty && self.model == model && self.dimensions == dimensions
    }

    /// The stored (unit-length) vector.
    public func vector(for id: UUID) -> [Float]? {
        guard let row = rows[id] else { return nil }
        return Array(storage[row * dimensions ..< (row + 1) * dimensions])
    }

    /// Stores `vector` for `id` (normalized). A different model or size than what's stored clears the
    /// index first. Empty or all-zero vectors are ignored.
    public mutating func set(_ vector: [Float], for id: UUID, model: String) {
        guard !vector.isEmpty, let unit = Self.normalized(vector) else { return }
        if model != self.model || unit.count != dimensions {
            self = VectorIndex(model: model, dimensions: unit.count)
        }
        if let row = rows[id] {
            storage.replaceSubrange(row * dimensions ..< (row + 1) * dimensions, with: unit)
        } else {
            rows[id] = ids.count
            ids.append(id)
            storage.append(contentsOf: unit)
        }
    }

    /// Removes a row (the last row moves into its place).
    public mutating func remove(_ id: UUID) {
        guard let row = rows.removeValue(forKey: id) else { return }
        let last = ids.count - 1
        if row != last {
            let lastID = ids[last]
            ids[row] = lastID
            rows[lastID] = row
            storage.replaceSubrange(row * dimensions ..< (row + 1) * dimensions,
                                    with: storage[last * dimensions ..< (last + 1) * dimensions])
        }
        ids.removeLast()
        storage.removeLast(dimensions)
    }

    /// Keeps only the rows whose id passes `keep`.
    public mutating func retain(where keep: (UUID) -> Bool) {
        for id in ids where !keep(id) { remove(id) }
    }

    public mutating func removeAll() { self = VectorIndex(model: model, dimensions: dimensions) }

    // MARK: Similarity

    /// Cosine similarity of `query` with every row, in row order. Empty when the size doesn't match.
    public func scores(for query: [Float]) -> [Float] {
        guard !isEmpty, query.count == dimensions, let q = Self.normalized(query) else { return [] }
        var out = [Float](repeating: 0, count: count)
        // (count × dim) · (dim × 1) = (count × 1)
        storage.withUnsafeBufferPointer { a in
            q.withUnsafeBufferPointer { b in
                out.withUnsafeMutableBufferPointer { c in
                    vDSP_mmul(a.baseAddress!, 1, b.baseAddress!, 1, c.baseAddress!, 1,
                              vDSP_Length(count), 1, vDSP_Length(dimensions))
                }
            }
        }
        return out
    }

    /// The `limit` most similar items, best first, at or above `minScore`.
    public func nearest(to query: [Float], limit: Int, minScore: Float = -1, excluding: Set<UUID> = []) -> [(id: UUID, score: Float)] {
        let all = scores(for: query)
        guard !all.isEmpty, limit > 0 else { return [] }
        var hits: [(id: UUID, score: Float)] = []
        hits.reserveCapacity(min(all.count, 256))
        for (row, score) in all.enumerated() where score >= minScore && !excluding.contains(ids[row]) {
            hits.append((ids[row], score))
        }
        hits.sort { $0.score > $1.score }
        return Array(hits.prefix(limit))
    }

    /// Cosine similarity of two vectors of the same size (0 when either is empty or zero).
    public static func cosine(_ a: [Float], _ b: [Float]) -> Float {
        guard a.count == b.count, !a.isEmpty else { return 0 }
        var dot: Float = 0, na: Float = 0, nb: Float = 0
        vDSP_dotpr(a, 1, b, 1, &dot, vDSP_Length(a.count))
        vDSP_svesq(a, 1, &na, vDSP_Length(a.count))
        vDSP_svesq(b, 1, &nb, vDSP_Length(b.count))
        let denominator = (na * nb).squareRoot()
        return denominator > 0 ? dot / denominator : 0
    }

    /// `v` scaled to unit length; nil for a zero vector.
    public static func normalized(_ v: [Float]) -> [Float]? {
        var sumSquares: Float = 0
        vDSP_svesq(v, 1, &sumSquares, vDSP_Length(v.count))
        guard sumSquares > 0, sumSquares.isFinite else { return nil }
        var scale = 1 / sumSquares.squareRoot()
        var out = [Float](repeating: 0, count: v.count)
        vDSP_vsmul(v, 1, &scale, &out, 1, vDSP_Length(v.count))
        return out
    }

    // MARK: File

    private static let magic = Data("DMV1".utf8)

    /// The binary file described above.
    public func encoded() -> Data {
        var data = Data()
        let modelBytes = Data(model.utf8.prefix(Int(UInt16.max)))
        data.reserveCapacity(4 + 4 + 4 + 2 + modelBytes.count + count * 16 + storage.count * 4)
        data.append(Self.magic)
        Self.append(UInt32(dimensions), to: &data)
        Self.append(UInt32(count), to: &data)
        Self.append(UInt16(modelBytes.count), to: &data)
        data.append(modelBytes)
        for id in ids {
            var raw = id.uuid
            withUnsafeBytes(of: &raw) { data.append(contentsOf: $0) }
        }
        storage.withUnsafeBufferPointer { buffer in
            // Apple platforms are little-endian, so the floats go out as they are in memory.
            data.append(UnsafeBufferPointer(start: UnsafeRawPointer(buffer.baseAddress!).assumingMemoryBound(to: UInt8.self),
                                            count: buffer.count * MemoryLayout<Float>.size))
        }
        return data
    }

    public enum FileError: Error, Equatable { case notAVectorFile, truncated }

    /// Reads the binary file described above.
    public init(data: Data) throws {
        var cursor = data.startIndex
        func take(_ n: Int) throws -> Data {
            guard n >= 0, data.endIndex - cursor >= n else { throw FileError.truncated }
            defer { cursor += n }
            return data[cursor ..< cursor + n]
        }
        func integer<T: FixedWidthInteger>(_: T.Type) throws -> T {
            let bytes = try take(MemoryLayout<T>.size)
            var value: T = 0
            for (i, byte) in bytes.enumerated() { value |= T(byte) << (8 * i) }
            return value
        }
        guard data.count >= 4, try take(4) == Self.magic else { throw FileError.notAVectorFile }
        let dims = Int(try integer(UInt32.self))
        let count = Int(try integer(UInt32.self))
        let modelLength = Int(try integer(UInt16.self))
        let model = String(decoding: try take(modelLength), as: UTF8.self)

        let idBytes = try take(count * 16)
        var ids: [UUID] = []
        ids.reserveCapacity(count)
        idBytes.withUnsafeBytes { raw in
            for i in 0..<count {
                var uuid: uuid_t = (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
                withUnsafeMutableBytes(of: &uuid) { $0.copyMemory(from: UnsafeRawBufferPointer(rebasing: raw[i * 16 ..< (i + 1) * 16])) }
                ids.append(UUID(uuid: uuid))
            }
        }
        let floatBytes = try take(count * dims * MemoryLayout<Float>.size)
        var storage = [Float](repeating: 0, count: count * dims)
        storage.withUnsafeMutableBytes { $0.copyBytes(from: floatBytes) }

        self.model = model
        self.dimensions = dims
        self.ids = ids
        self.storage = storage
        var rows: [UUID: Int] = [:]
        rows.reserveCapacity(count)
        for (i, id) in ids.enumerated() { rows[id] = i }
        self.rows = rows
    }

    private static func append<T: FixedWidthInteger>(_ value: T, to data: inout Data) {
        var little = value.littleEndian
        withUnsafeBytes(of: &little) { data.append(contentsOf: $0) }
    }

    public static func == (a: VectorIndex, b: VectorIndex) -> Bool {
        a.model == b.model && a.dimensions == b.dimensions && a.ids == b.ids && a.storage == b.storage
    }
}
