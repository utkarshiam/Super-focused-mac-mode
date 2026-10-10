import Foundation

/// What MemoryKit needs from an AI model. `GeminiMemoryAI` is the real one; tests and previews pass fakes.
/// The processor, Ask and profile synthesis hold an optional `MemoryAI`: nil means "no key", and
/// everything except AI processing and Ask keeps working.
public protocol MemoryAI: Sendable {
    /// The embedding model's id, stamped on stored vectors ("gemini-embedding-2").
    var embeddingModel: String { get }
    /// Vector size the model returns (768).
    var embeddingDimensions: Int { get }

    /// One structured answer: `schema` is a JSON Schema the reply must follow; `parts` are files the
    /// model should look at (images, PDF, audio, video). Returns the JSON object the model wrote
    /// (already checked to parse). Throws `MemoryAIError` or `CancellationError`.
    func generateJSON(system: String, prompt: String, schema: MemoryJSON, parts: [MemoryInlinePart]) async throws -> Data

    /// One vector per text, in order. Throws `MemoryAIError` or `CancellationError`.
    func embed(_ texts: [String], task: EmbedTask) async throws -> [[Float]]
}

extension MemoryAI {
    public func generateJSON(system: String, prompt: String, schema: MemoryJSON) async throws -> Data {
        try await generateJSON(system: system, prompt: prompt, schema: schema, parts: [])
    }
}

/// What a vector is for: stored documents and search queries are embedded slightly differently.
public enum EmbedTask: String, Sendable {
    case document, query
}

/// A file sent along with a prompt. Small files travel inside the request (base64 `inlineData`); when they
/// would make the request too big, `GeminiMemoryAI` uploads them through the Files API first and sends a
/// reference instead. Callers don't need to care which.
public struct MemoryInlinePart: Hashable, Sendable {
    public var mimeType: String
    public var data: Data

    public init(mimeType: String, data: Data) {
        self.mimeType = mimeType
        self.data = data
    }

    /// The largest file worth sending at all; bigger ones are described by name only. (The Files API takes up
    /// to 2 GB, but the file is held in memory while it's sent.)
    public static let maxBytes = 100 * 1024 * 1024

    /// Raw bytes that may travel inline in one request. Gemini's audio docs cap a request at 20 MB including
    /// the prompt; base64 adds a third, so 14 MB of files ≈ 18.7 MB on the wire. Above this, files are
    /// uploaded (ai.google.dev/gemini-api/docs/audio, …/docs/files).
    public static let inlineBudget = 14 * 1024 * 1024
}

// MARK: - Errors

/// The same cases and wording as the Mac app's `AIError`, so either can be shown as is.
public enum MemoryAIError: LocalizedError, Equatable, Sendable {
    /// No key yet, or AI is switched off.
    case notConfigured
    /// Google refused the key (wrong, revoked or restricted).
    case badKey
    /// Too many requests, or Google is overloaded.
    case rateLimited
    /// Offline, timed out, no route to Google. The text says which, in a sentence.
    case network(String)
    /// Google answered, but not with something usable. The text is a full sentence for the user.
    case badResponse(String)

    public var errorDescription: String? {
        switch self {
        case .notConfigured: "Add a Google Gemini API key in Settings → AI to use this."
        case .badKey: "Google Gemini didn't accept the API key. Check it in Settings → AI."
        case .rateLimited: "Gemini is busy or the key has hit its limit. Try again in a minute."
        case .network(let detail): detail.isEmpty ? "Couldn't reach Gemini." : "Couldn't reach Gemini. \(detail)"
        case .badResponse(let detail): detail.isEmpty ? "Gemini sent back something unexpected. Try again." : detail
        }
    }

    /// Worth trying again later without the user doing anything (offline, busy).
    public var isTransient: Bool {
        switch self {
        case .network, .rateLimited: true
        case .notConfigured, .badKey, .badResponse: false
        }
    }

    /// Whether the fix is in Settings → AI (a missing or rejected key, an unknown model).
    public var needsSettings: Bool {
        switch self {
        case .notConfigured, .badKey: true
        case .badResponse(let detail): detail.contains(Self.settingsHint)
        case .rateLimited, .network: false
        }
    }

    /// Ends the messages whose fix is in Settings (an unknown model name).
    public static let settingsHint = "Check the model in Settings → AI."
    /// Also used when the JSON parses but isn't the shape that was asked for.
    public static let unexpectedFormat = "Gemini's answer wasn't in the expected format. Try again."
}

// MARK: - JSON built in code

/// A JSON value written as a Swift literal: request bodies and answer schemas.
public enum MemoryJSON: Codable, Hashable, Sendable, ExpressibleByStringLiteral, ExpressibleByIntegerLiteral,
    ExpressibleByFloatLiteral, ExpressibleByBooleanLiteral, ExpressibleByArrayLiteral, ExpressibleByDictionaryLiteral,
    ExpressibleByNilLiteral {
    case string(String)
    case int(Int)
    case double(Double)
    case bool(Bool)
    case null
    case array([MemoryJSON])
    case object([String: MemoryJSON])

    public init(stringLiteral value: String) { self = .string(value) }
    public init(integerLiteral value: Int) { self = .int(value) }
    public init(floatLiteral value: Double) { self = .double(value) }
    public init(booleanLiteral value: Bool) { self = .bool(value) }
    public init(nilLiteral: ()) { self = .null }
    public init(arrayLiteral elements: MemoryJSON...) { self = .array(elements) }
    public init(dictionaryLiteral elements: (String, MemoryJSON)...) {
        self = .object(Dictionary(elements, uniquingKeysWith: { _, last in last }))
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .string(let s): try c.encode(s)
        case .int(let i): try c.encode(i)
        case .double(let d): try c.encode(d)
        case .bool(let b): try c.encode(b)
        case .null: try c.encodeNil()
        case .array(let a): try c.encode(a)
        case .object(let o): try c.encode(o)
        }
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let b = try? c.decode(Bool.self) { self = .bool(b) }
        else if let i = try? c.decode(Int.self) { self = .int(i) }
        else if let d = try? c.decode(Double.self) { self = .double(d) }
        else if let s = try? c.decode(String.self) { self = .string(s) }
        else if let a = try? c.decode([MemoryJSON].self) { self = .array(a) }
        else { self = .object(try c.decode([String: MemoryJSON].self)) }
    }
}

extension MemoryJSON {
    /// JSON Schema shorthands, so prompts read like the JSON they ask for.
    public enum Schema {
        /// An object whose properties are all required unless `required` says otherwise.
        public static func object(_ properties: [String: MemoryJSON], required: [String]? = nil) -> MemoryJSON {
            .object(["type": "object", "properties": .object(properties),
                     "required": .array((required ?? properties.keys.sorted()).map { .string($0) })])
        }
        public static func array(_ items: MemoryJSON, maxItems: Int? = nil) -> MemoryJSON {
            var o: [String: MemoryJSON] = ["type": "array", "items": items]
            if let maxItems { o["maxItems"] = .int(maxItems) }
            return .object(o)
        }
        public static func string(_ description: String? = nil, enum values: [String]? = nil) -> MemoryJSON {
            var o: [String: MemoryJSON] = ["type": "string"]
            if let description { o["description"] = .string(description) }
            if let values { o["enum"] = .array(values.map { .string($0) }) }
            return .object(o)
        }
        public static let integer: MemoryJSON = ["type": "integer"]
        public static let boolean: MemoryJSON = ["type": "boolean"]
    }
}
