import XCTest
@testable import MemoryKit

/// A fresh temporary directory per test, removed afterwards. Tests never touch real user folders.
func makeTempDirectory(_ name: String = #function) -> URL {
    let safe = name.filter { $0.isLetter || $0.isNumber }
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("MemoryKitTests-\(safe)-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

/// A stand-in `MemoryAI`: answers from closures and records every call. Thread-safe.
final class FakeAI: MemoryAI, @unchecked Sendable {
    struct GenerateCall {
        var system: String
        var prompt: String
        var parts: [MemoryInlinePart]
    }

    let embeddingModel: String
    let embeddingDimensions: Int
    private let lock = NSLock()
    private var _generateCalls: [GenerateCall] = []
    private var _embedCalls: [(texts: [String], task: EmbedTask)] = []
    /// Answers `generateJSON`; default: a minimal extraction.
    var onGenerate: (GenerateCall) throws -> Data
    /// Answers `embed`; default: `FakeAI.wordVector`.
    var onEmbed: ([String], EmbedTask) throws -> [[Float]]

    init(model: String = "fake-embed", dimensions: Int = 32,
         onGenerate: ((GenerateCall) throws -> Data)? = nil, onEmbed: (([String], EmbedTask) throws -> [[Float]])? = nil) {
        embeddingModel = model
        embeddingDimensions = dimensions
        self.onGenerate = onGenerate ?? { _ in Data(#"{"title":"Fake title","summary":"Fake summary.","keyTakeaways":[],"people":[],"projects":[],"topics":[],"tags":[],"moments":[],"extractedText":""}"#.utf8) }
        self.onEmbed = onEmbed ?? { texts, _ in texts.map { FakeAI.wordVector($0, dimensions: dimensions) } }
    }

    var generateCalls: [GenerateCall] { locked { _generateCalls } }
    var embedCalls: [(texts: [String], task: EmbedTask)] { locked { _embedCalls } }

    private func locked<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }

    func generateJSON(system: String, prompt: String, schema: MemoryJSON, parts: [MemoryInlinePart]) async throws -> Data {
        let call = GenerateCall(system: system, prompt: prompt, parts: parts)
        let handler = locked { _generateCalls.append(call); return onGenerate }
        return try handler(call)
    }

    func embed(_ texts: [String], task: EmbedTask) async throws -> [[Float]] {
        let handler = locked { _embedCalls.append((texts, task)); return onEmbed }
        return try handler(texts, task)
    }

    /// A bag-of-words vector: each word adds 1 to a hashed slot. Texts sharing words are similar.
    static func wordVector(_ text: String, dimensions: Int) -> [Float] {
        var v = [Float](repeating: 0, count: dimensions)
        for word in TextFold.words(text) where word.count > 2 && !TextFold.stopwords.contains(word) {
            var h: UInt64 = 1469598103934665603
            for b in word.utf8 { h = (h ^ UInt64(b)) &* 1099511628211 }
            v[Int(h % UInt64(dimensions))] += 1
        }
        if v.allSatisfy({ $0 == 0 }) { v[0] = 1 }
        return v
    }
}

/// A fake HTTP transport for `GeminiMemoryAI` and `LinkFetcher`: records requests, replies from a queue.
final class FakeTransport: @unchecked Sendable {
    enum Reply {
        case http(Int, Data, [String: String])
        case failure(Error)
    }

    private let lock = NSLock()
    private var replies: [Reply] = []
    private var recorded: [URLRequest] = []

    var requests: [URLRequest] { lock.lock(); defer { lock.unlock() }; return recorded }

    func reply(status: Int = 200, json: Any) {
        reply(status: status, body: (try? JSONSerialization.data(withJSONObject: json)) ?? Data())
    }

    func reply(status: Int = 200, body: Data, headers: [String: String] = [:]) {
        lock.lock(); replies.append(.http(status, body, headers)); lock.unlock()
    }

    /// A Gemini generateContent reply whose text is `json`.
    func answer(_ json: String, finish: String = "STOP") {
        reply(json: ["candidates": [["content": ["parts": [["text": json]], "role": "model"], "finishReason": finish]]])
    }

    func fail(_ error: Error) {
        lock.lock(); replies.append(.failure(error)); lock.unlock()
    }

    private func take(_ request: URLRequest) -> Reply? {
        lock.lock()
        defer { lock.unlock() }
        recorded.append(request)
        return replies.isEmpty ? nil : replies.removeFirst()
    }

    var transport: GeminiMemoryAI.Transport {
        { [self] request in
            let next = take(request)
            switch next {
            case .http(let status, let body, let headers)?:
                return (body, HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!)
            case .failure(let error)?:
                throw error
            case nil:
                throw URLError(.notConnectedToInternet)
            }
        }
    }
}

extension URLRequest {
    /// The JSON body as a dictionary.
    var jsonBody: [String: Any] {
        (httpBody.flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any]) ?? [:]
    }
}

/// A date at noon, `days` from a fixed reference (Fri 9 Oct 2026), in the current time zone.
func day(_ days: Int, hour: Int = 12) -> Date {
    var c = DateComponents()
    c.year = 2026; c.month = 10; c.day = 9; c.hour = hour
    let base = Calendar.current.date(from: c)!
    return Calendar.current.date(byAdding: .day, value: days, to: base)!
}

/// Encodes then decodes with MemoryKit's coders.
func roundTrip<T: Codable>(_ value: T) throws -> T {
    try MemoryCoding.decoder.decode(T.self, from: MemoryCoding.encoder.encode(value))
}
