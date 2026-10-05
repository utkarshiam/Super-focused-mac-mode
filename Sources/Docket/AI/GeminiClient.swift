import Foundation

/// Google Gemini's `generateContent` with JSON-schema output: one request in, the model's JSON answer out.
/// The key travels in a header (never in the URL) and is never logged. Stateless: `AIService` makes one
/// per call with the current key and model.
struct GeminiClient {
    /// Sends one HTTP request. The app uses an ephemeral URLSession; tests pass a fake, so they never
    /// touch the network.
    typealias Transport = @Sendable (URLRequest) async throws -> (Data, URLResponse)

    static let baseURL = "https://generativelanguage.googleapis.com/v1beta/models/"
    /// Gemini usually answers in a few seconds; a long note can take longer.
    static let timeout: TimeInterval = 45

    var apiKey: String
    var model: String
    var transport: Transport = GeminiClient.defaultTransport

    /// No cache, cookies or stored credentials: nothing sent or received is written to disk.
    static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = timeout
        config.timeoutIntervalForResource = timeout + 15
        config.urlCache = nil
        config.httpShouldSetCookies = false
        config.waitsForConnectivity = false
        return URLSession(configuration: config)
    }()

    static let liveTransport: Transport = { request in try await session.data(for: request) }

    /// What `AIService` uses unless told otherwise: the network, except inside unit tests, where nothing
    /// may reach Gemini (not even with GEMINI_API_KEY set in the shell). Tests that need answers pass a fake.
    static let defaultTransport: Transport = isUnitTesting ? offlineTransport : liveTransport

    /// Fails at once, as if offline.
    static let offlineTransport: Transport = { _ in throw URLError(.notConnectedToInternet) }

    /// XCTest is loaded: the same check the keychain uses to keep tests away from real secrets.
    static var isUnitTesting: Bool { NSClassFromString("XCTestCase") != nil }

    /// The model id as the URL wants it ("models/gemini-3.5-flash" → "gemini-3.5-flash").
    var modelID: String {
        var id = model.trimmingCharacters(in: .whitespacesAndNewlines)
        if id.hasPrefix("models/") { id.removeFirst("models/".count) }
        return id.isEmpty ? Secrets.defaultGeminiModel : id
    }

    // MARK: Request

    /// The verified request shape: system instruction, one user turn, JSON output that follows
    /// `schema`, and a low thinking budget so answers come back quickly.
    func request(system: String, prompt: String, schema: JSON) throws -> URLRequest {
        // One path segment: a stray "/", "?" or "#" in a typed model name can't change the endpoint.
        let allowed = CharacterSet.urlPathAllowed.subtracting(CharacterSet(charactersIn: "/?#:;"))
        guard let segment = modelID.addingPercentEncoding(withAllowedCharacters: allowed),
              let url = URL(string: Self.baseURL + segment + ":generateContent") else {
            throw AIError.badResponse("“\(modelID)” isn't a Gemini model name. \(AIError.settingsHint)")
        }
        let body: JSON = [
            "systemInstruction": ["parts": [["text": .string(system)]]],
            "contents": [["role": "user", "parts": [["text": .string(prompt)]]]],
            "generationConfig": [
                "responseMimeType": "application/json",
                "responseJsonSchema": schema,
                "thinkingConfig": ["thinkingLevel": "low"],
            ],
        ]
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: Self.timeout)
        request.httpMethod = "POST"
        request.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try Self.encoder.encode(body)
        return request
    }

    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return e
    }()

    // MARK: Sending

    /// Sends the prompt and returns the JSON the model wrote (checked to be valid JSON).
    /// Throws `AIError` (or `CancellationError` when the caller gave up).
    func generate(system: String, prompt: String, schema: JSON) async throws -> Data {
        let request = try request(system: system, prompt: prompt, schema: schema)
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await transport(request)
        } catch {
            throw Self.transportError(error)
        }
        try Task.checkCancellation()
        guard let http = response as? HTTPURLResponse else {
            throw AIError.badResponse("Gemini didn't answer. Try again.")
        }
        guard (200..<300).contains(http.statusCode) else {
            throw Self.error(status: http.statusCode, body: data, model: modelID)
        }
        return try Self.answer(from: data)
    }

    // MARK: Errors

    /// Network failures in plain words. Cancelling isn't an error the user needs to see.
    static func transportError(_ error: Error) -> Error {
        if error is CancellationError || error is AIError { return error }
        guard let urlError = error as? URLError else { return AIError.network(error.localizedDescription) }
        switch urlError.code {
        case .cancelled:
            return CancellationError()
        case .notConnectedToInternet, .networkConnectionLost, .dataNotAllowed, .internationalRoamingOff:
            return AIError.network("You're offline. Check your connection and try again.")
        case .timedOut:
            return AIError.network("The request timed out. Try again.")
        case .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed:
            return AIError.network("Google's servers can't be reached right now.")
        case .secureConnectionFailed, .serverCertificateUntrusted, .serverCertificateHasBadDate,
             .serverCertificateNotYetValid, .serverCertificateHasUnknownRoot, .clientCertificateRejected:
            return AIError.network("The secure connection to Google failed.")
        default:
            return AIError.network(urlError.localizedDescription)
        }
    }

    /// An HTTP error status as an `AIError`. 400 is a bad key only when Google says so (it also means
    /// a request it can't serve, like an unsupported region); 401/403 always are.
    static func error(status: Int, body: Data, model: String) -> AIError {
        let google = GoogleError(body)
        switch status {
        case 401, 403:
            return .badKey
        case 400:
            if google.isAboutTheKey { return .badKey }
            return .badResponse(google.message.map { "Gemini couldn't handle the request: \($0)" }
                ?? "Gemini couldn't handle the request (HTTP 400).")
        case 404:
            return .badResponse("There's no Gemini model called “\(model)”. \(AIError.settingsHint)")
        case 429:
            return .rateLimited
        case 500...599:
            // Overloaded or a hiccup on Google's side: the advice is the same, wait and retry.
            return .rateLimited
        default:
            return .badResponse(google.message.map { "Gemini answered with an error: \($0)" }
                ?? "Gemini answered with an error (HTTP \(status)).")
        }
    }

    /// Google's error body: {"error": {"message", "status", "details": [{"reason"}]}}, sometimes wrapped in an array.
    private struct GoogleError {
        var message: String?
        var reasons: [String] = []

        init(_ data: Data) {
            let root = try? JSONSerialization.jsonObject(with: data)
            let wrapper = (root as? [String: Any]) ?? ((root as? [Any])?.first as? [String: Any])
            guard let error = wrapper?["error"] as? [String: Any] else { return }
            if let text = (error["message"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty {
                message = text.count > 240 ? String(text.prefix(240)) + "…" : text
            }
            reasons = (error["details"] as? [Any] ?? []).compactMap { ($0 as? [String: Any])?["reason"] as? String }
        }

        var isAboutTheKey: Bool {
            reasons.contains { $0.hasPrefix("API_KEY") } || message?.localizedCaseInsensitiveContains("API key") == true
        }
    }

    // MARK: Answer

    /// Finish reasons that mean the model refused rather than ran out of room.
    private static let refusals: Set<String> = ["SAFETY", "RECITATION", "BLOCKLIST", "PROHIBITED_CONTENT", "SPII", "LANGUAGE", "OTHER"]

    /// The JSON text in `candidates[0].content.parts[*].text` (thought summaries skipped), checked to parse.
    static func answer(from data: Data) throws -> Data {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw AIError.badResponse("Gemini's reply wasn't readable. Try again.")
        }
        guard let candidate = (root["candidates"] as? [Any])?.first as? [String: Any] else {
            if let feedback = root["promptFeedback"] as? [String: Any], feedback["blockReason"] != nil {
                throw AIError.badResponse(declined)
            }
            throw AIError.badResponse(empty)
        }
        let parts = ((candidate["content"] as? [String: Any])?["parts"] as? [Any] ?? []).compactMap { $0 as? [String: Any] }
        let text = parts.filter { ($0["thought"] as? Bool) != true }.compactMap { $0["text"] as? String }.joined()
        let finish = candidate["finishReason"] as? String ?? ""
        let json = stripCodeFence(text)

        guard !json.isEmpty else {
            if finish == "MAX_TOKENS" { throw AIError.badResponse(cutOff) }
            if refusals.contains(finish) { throw AIError.badResponse(declined) }
            throw AIError.badResponse(empty)
        }
        let payload = Data(json.utf8)
        guard (try? JSONSerialization.jsonObject(with: payload)) is [String: Any] else {
            if finish == "MAX_TOKENS" { throw AIError.badResponse(cutOff) }
            throw AIError.badResponse(unexpectedFormat)
        }
        return payload
    }

    private static let declined = "Gemini declined to answer this one. Try rewording it."
    private static let empty = "Gemini's answer was empty. Try again."
    private static let cutOff = "Gemini's answer got cut off. Try with less text."
    /// Also used when the JSON parses but isn't the shape that was asked for.
    static let unexpectedFormat = "Gemini's answer wasn't in the expected format. Try again."

    /// JSON mode answers are bare JSON, but tolerate a ```json fence around it.
    private static func stripCodeFence(_ text: String) -> String {
        var s = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard s.hasPrefix("```") else { return s }
        s = String(s.drop { $0 != "\n" }.dropFirst())
        if s.hasSuffix("```") { s = String(s.dropLast(3)) }
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// MARK: - JSON built in code

extension GeminiClient {
    /// A JSON value written as a Swift literal: request bodies and the answer schemas.
    enum JSON: Encodable, Equatable, Sendable, ExpressibleByStringLiteral, ExpressibleByIntegerLiteral,
        ExpressibleByBooleanLiteral, ExpressibleByArrayLiteral, ExpressibleByDictionaryLiteral, ExpressibleByNilLiteral {
        case string(String)
        case int(Int)
        case bool(Bool)
        case null
        case array([JSON])
        case object([String: JSON])

        init(stringLiteral value: String) { self = .string(value) }
        init(integerLiteral value: Int) { self = .int(value) }
        init(booleanLiteral value: Bool) { self = .bool(value) }
        init(nilLiteral: ()) { self = .null }
        init(arrayLiteral elements: JSON...) { self = .array(elements) }
        init(dictionaryLiteral elements: (String, JSON)...) {
            self = .object(Dictionary(elements, uniquingKeysWith: { _, last in last }))
        }

        func encode(to encoder: Encoder) throws {
            var c = encoder.singleValueContainer()
            switch self {
            case .string(let s): try c.encode(s)
            case .int(let i): try c.encode(i)
            case .bool(let b): try c.encode(b)
            case .null: try c.encodeNil()
            case .array(let a): try c.encode(a)
            case .object(let o): try c.encode(o)
            }
        }
    }
}
