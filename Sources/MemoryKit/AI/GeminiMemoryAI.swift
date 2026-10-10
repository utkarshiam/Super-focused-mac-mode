import Foundation

/// Google Gemini for memory: structured answers (`generateContent` with a JSON schema, optional files)
/// and embeddings (`embedContent` / `batchEmbedContents`). The key travels in the `x-goog-api-key` header
/// (never in the URL) and is never logged. Stateless; make a new one when the key or model changes.
///
/// Files ride inline (base64) while they fit `MemoryInlinePart.inlineBudget`; bigger ones (a long
/// recording) go up through the Files API first (resumable upload, wait until ACTIVE), are referenced as
/// `fileData`, and are deleted again once Gemini has answered. Callers don't see the difference.
public struct GeminiMemoryAI: MemoryAI {
    /// Sends one HTTP request. The apps use an ephemeral URLSession; tests pass a fake, so they never
    /// touch the network.
    public typealias Transport = @Sendable (URLRequest) async throws -> (Data, URLResponse)

    public static let baseURL = "https://generativelanguage.googleapis.com/v1beta/models/"
    /// Files API: `POST` starts a resumable upload; files live at `<filesBaseURL>files/<id>`.
    public static let uploadURL = "https://generativelanguage.googleapis.com/upload/v1beta/files"
    public static let filesBaseURL = "https://generativelanguage.googleapis.com/v1beta/"
    /// How long an uploaded file may stay PROCESSING before giving up.
    public static let activationTimeout: TimeInterval = 120
    public static let defaultModel = "gemini-3.5-flash"
    public static let defaultEmbeddingModel = "gemini-embedding-2"
    public static let defaultDimensions = 768
    /// Media and long pages take longer than a short prompt.
    public static let timeout: TimeInterval = 90
    /// Embedding models have a limited input window; longer texts are cut (like ENGRAM).
    public static let maxEmbedCharacters = 8000
    /// `batchEmbedContents` takes at most 100 requests.
    public static let batchSize = 100

    public var apiKey: String
    public var model: String
    public var embeddingModel: String
    public var embeddingDimensions: Int
    public var transport: Transport
    /// Seconds between checks while an uploaded file is PROCESSING (tests use 0).
    public var filePollInterval: TimeInterval

    public init(apiKey: String, model: String = GeminiMemoryAI.defaultModel,
                embeddingModel: String = GeminiMemoryAI.defaultEmbeddingModel,
                embeddingDimensions: Int = GeminiMemoryAI.defaultDimensions,
                transport: Transport? = nil, filePollInterval: TimeInterval = 1.5) {
        self.apiKey = apiKey
        self.model = model
        self.embeddingModel = embeddingModel
        self.embeddingDimensions = embeddingDimensions
        self.transport = transport ?? Self.defaultTransport
        self.filePollInterval = filePollInterval
    }

    /// No cache, cookies or stored credentials: nothing sent or received is written to disk.
    static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = timeout
        // Per request; an upload of a long recording on a slow connection needs minutes overall, while
        // `timeoutIntervalForRequest` still catches a stalled connection.
        config.timeoutIntervalForResource = 15 * 60
        config.urlCache = nil
        config.httpShouldSetCookies = false
        config.waitsForConnectivity = false
        return URLSession(configuration: config)
    }()

    public static let liveTransport: Transport = { request in try await session.data(for: request) }

    /// The network, except inside unit tests, where nothing may reach Gemini (not even with
    /// GEMINI_API_KEY set in the shell). Tests that need answers pass a fake.
    public static let defaultTransport: Transport = isUnitTesting ? offlineTransport : liveTransport

    /// Fails at once, as if offline.
    public static let offlineTransport: Transport = { _ in throw URLError(.notConnectedToInternet) }

    /// XCTest is loaded.
    public static var isUnitTesting: Bool { NSClassFromString("XCTestCase") != nil }

    /// "models/gemini-3.5-flash" → "gemini-3.5-flash"; empty → the default.
    static func modelID(_ name: String, fallback: String) -> String {
        var id = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if id.hasPrefix("models/") { id.removeFirst("models/".count) }
        return id.isEmpty ? fallback : id
    }

    var generationModelID: String { Self.modelID(model, fallback: Self.defaultModel) }
    var embeddingModelID: String { Self.modelID(embeddingModel, fallback: Self.defaultEmbeddingModel) }

    // MARK: Requests

    /// `<base><model>:<method>`, the model as one path segment so a stray "/", "?" or "#" can't change the endpoint.
    func endpoint(model: String, method: String) throws -> URL {
        let allowed = CharacterSet.urlPathAllowed.subtracting(CharacterSet(charactersIn: "/?#:;"))
        guard let segment = model.addingPercentEncoding(withAllowedCharacters: allowed),
              let url = URL(string: Self.baseURL + segment + ":" + method) else {
            throw MemoryAIError.badResponse("“\(model)” isn't a Gemini model name. \(MemoryAIError.settingsHint)")
        }
        return url
    }

    private func post(_ url: URL, body: MemoryJSON) throws -> URLRequest {
        var request = try keyed(url, method: "POST")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try Self.encoder.encode(body)
        return request
    }

    /// A request carrying the key in its header (never the URL).
    private func keyed(_ url: URL, method: String) throws -> URLRequest {
        guard !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw MemoryAIError.notConfigured }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: Self.timeout)
        request.httpMethod = method
        request.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")
        return request
    }

    /// One piece of the user turn after the text: a file inline, or one already uploaded.
    public enum FilePart: Hashable, Sendable {
        case inline(MemoryInlinePart)
        case uploaded(mimeType: String, uri: String)
    }

    /// System instruction, one user turn (text, then the files inline), JSON output that follows
    /// `schema`, and a low thinking level so answers come back quickly. Files over `maxBytes` are left out.
    public func generateRequest(system: String, prompt: String, schema: MemoryJSON, parts: [MemoryInlinePart] = []) throws -> URLRequest {
        try generateRequest(system: system, prompt: prompt, schema: schema,
                            files: parts.filter { $0.data.count <= MemoryInlinePart.maxBytes }.map { .inline($0) })
    }

    /// The same with each file inline (`inlineData`) or by reference (`fileData`). MIME types are sent
    /// the way Gemini names them (`MimeType.forGemini`: an .m4a goes as audio/m4a).
    public func generateRequest(system: String, prompt: String, schema: MemoryJSON, files: [FilePart]) throws -> URLRequest {
        var userParts: [MemoryJSON] = [["text": .string(prompt)]]
        for file in files {
            switch file {
            case .inline(let part):
                userParts.append(["inlineData": ["mimeType": .string(MimeType.forGemini(part.mimeType)),
                                                 "data": .string(part.data.base64EncodedString())]])
            case .uploaded(let mimeType, let uri):
                userParts.append(["fileData": ["mimeType": .string(MimeType.forGemini(mimeType)), "fileUri": .string(uri)]])
            }
        }
        let body: MemoryJSON = [
            "systemInstruction": ["parts": [["text": .string(system)]]],
            "contents": [["role": "user", "parts": .array(userParts)]],
            "generationConfig": [
                "responseMimeType": "application/json",
                "responseJsonSchema": schema,
                "thinkingConfig": ["thinkingLevel": "low"],
            ],
        ]
        return try post(endpoint(model: generationModelID, method: "generateContent"), body: body)
    }

    /// The text that gets embedded. gemini-embedding-2 takes the retrieval task as a prefix in the text
    /// (rather than a `taskType` field), so documents and queries land in comparable places.
    public static func embeddingInput(_ text: String, task: EmbedTask) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let cut = trimmed.count > maxEmbedCharacters ? String(trimmed.prefix(maxEmbedCharacters)) : trimmed
        switch task {
        case .query: return "task: search result | query: \(cut)"
        case .document: return "title: none | text: \(cut)"
        }
    }

    /// One text: ENGRAM's shape, `{content: {parts: [{text}]}, outputDimensionality}` to `:embedContent`.
    public func embedRequest(_ text: String, task: EmbedTask) throws -> URLRequest {
        let body: MemoryJSON = [
            "content": ["parts": [["text": .string(Self.embeddingInput(text, task: task))]]],
            "outputDimensionality": .int(embeddingDimensions),
        ]
        return try post(endpoint(model: embeddingModelID, method: "embedContent"), body: body)
    }

    /// Up to 100 texts: `{requests: [{model: "models/…", content, outputDimensionality}]}` to `:batchEmbedContents`.
    public func batchEmbedRequest(_ texts: [String], task: EmbedTask) throws -> URLRequest {
        let requests: [MemoryJSON] = texts.map {
            [
                "model": .string("models/" + embeddingModelID),
                "content": ["parts": [["text": .string(Self.embeddingInput($0, task: task))]]],
                "outputDimensionality": .int(embeddingDimensions),
            ]
        }
        return try post(endpoint(model: embeddingModelID, method: "batchEmbedContents"), body: ["requests": .array(requests)])
    }

    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return e
    }()

    // MARK: MemoryAI

    public func generateJSON(system: String, prompt: String, schema: MemoryJSON, parts: [MemoryInlinePart]) async throws -> Data {
        let usable = parts.filter { $0.data.count <= MemoryInlinePart.maxBytes }
        let toUpload = Self.partsToUpload(usable)
        var files: [FilePart] = []
        var uploaded: [UploadedFile] = []
        do {
            for (index, part) in usable.enumerated() {
                if toUpload.contains(index) {
                    let file = try await upload(part)
                    uploaded.append(file)
                    files.append(.uploaded(mimeType: part.mimeType, uri: file.uri))
                } else {
                    files.append(.inline(part))
                }
            }
            let data = try await send(generateRequest(system: system, prompt: prompt, schema: schema, files: files), model: generationModelID)
            await deleteFiles(uploaded)
            return try Self.answer(from: data)
        } catch {
            await deleteFiles(uploaded)
            throw error
        }
    }

    /// Which parts (by index) to upload so the rest fit `inlineBudget`: the biggest first, as few as possible.
    static func partsToUpload(_ parts: [MemoryInlinePart], budget: Int = MemoryInlinePart.inlineBudget) -> Set<Int> {
        var total = parts.reduce(0) { $0 + $1.data.count }
        var chosen = Set<Int>()
        for index in parts.indices.sorted(by: { parts[$0].data.count > parts[$1].data.count }) where total > budget {
            chosen.insert(index)
            total -= parts[index].data.count
        }
        return chosen
    }

    public func embed(_ texts: [String], task: EmbedTask) async throws -> [[Float]] {
        guard !texts.isEmpty else { return [] }
        if texts.count == 1 {
            let data = try await send(embedRequest(texts[0], task: task), model: embeddingModelID)
            return [try Self.vector(from: data)]
        }
        var out: [[Float]] = []
        out.reserveCapacity(texts.count)
        var start = 0
        while start < texts.count {
            let chunk = Array(texts[start ..< min(start + Self.batchSize, texts.count)])
            let data = try await send(batchEmbedRequest(chunk, task: task), model: embeddingModelID)
            let vectors = try Self.vectors(from: data)
            guard vectors.count == chunk.count else { throw MemoryAIError.badResponse(MemoryAIError.unexpectedFormat) }
            out += vectors
            start += Self.batchSize
        }
        return out
    }

    // MARK: Files API

    /// A file Gemini holds for us: `name` "files/abc123", `uri` to reference it by.
    struct UploadedFile: Hashable, Sendable {
        var name: String
        var uri: String
    }

    /// Step 1 of a resumable upload: announce the size and type; the reply's `x-goog-upload-url` header
    /// says where the bytes go.
    func uploadStartRequest(byteCount: Int, mimeType: String) throws -> URLRequest {
        guard let url = URL(string: Self.uploadURL) else { throw MemoryAIError.badResponse(MemoryAIError.unexpectedFormat) }
        var request = try keyed(url, method: "POST")
        request.setValue("resumable", forHTTPHeaderField: "X-Goog-Upload-Protocol")
        request.setValue("start", forHTTPHeaderField: "X-Goog-Upload-Command")
        request.setValue(String(byteCount), forHTTPHeaderField: "X-Goog-Upload-Header-Content-Length")
        request.setValue(MimeType.forGemini(mimeType), forHTTPHeaderField: "X-Goog-Upload-Header-Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try Self.encoder.encode(["file": ["display_name": "docket-upload"]] as MemoryJSON)
        return request
    }

    /// Step 2: all the bytes in one go, finalizing the upload.
    func uploadBytesRequest(to url: URL, data: Data) throws -> URLRequest {
        var request = try keyed(url, method: "POST")
        request.timeoutInterval = Self.timeout * 2
        request.setValue(String(data.count), forHTTPHeaderField: "Content-Length")
        request.setValue("0", forHTTPHeaderField: "X-Goog-Upload-Offset")
        request.setValue("upload, finalize", forHTTPHeaderField: "X-Goog-Upload-Command")
        request.httpBody = data
        return request
    }

    /// `GET`/`DELETE` on "files/abc123".
    func fileRequest(_ name: String, method: String) throws -> URLRequest {
        let allowed = CharacterSet.urlPathAllowed.subtracting(CharacterSet(charactersIn: "?#:;"))
        guard name.hasPrefix("files/"), !name.contains(".."),
              let path = name.addingPercentEncoding(withAllowedCharacters: allowed),
              let url = URL(string: Self.filesBaseURL + path) else {
            throw MemoryAIError.badResponse(MemoryAIError.unexpectedFormat)
        }
        return try keyed(url, method: method)
    }

    /// Uploads one file and waits until Gemini can use it.
    func upload(_ part: MemoryInlinePart) async throws -> UploadedFile {
        let (_, startResponse) = try await sendForResponse(uploadStartRequest(byteCount: part.data.count, mimeType: part.mimeType),
                                                           model: generationModelID)
        guard let location = startResponse.value(forHTTPHeaderField: "x-goog-upload-url"), let uploadURL = URL(string: location),
              uploadURL.scheme == "https" else {
            throw MemoryAIError.badResponse("Gemini didn't accept the upload. Try again.")
        }
        let (body, _) = try await sendForResponse(uploadBytesRequest(to: uploadURL, data: part.data), model: generationModelID)
        var file = try Self.fileInfo(from: body)
        let deadline = Date().addingTimeInterval(Self.activationTimeout)
        while file.state != "ACTIVE" {
            if file.state == "FAILED" {
                await deleteFiles([file.uploaded])
                throw MemoryAIError.badResponse("Gemini couldn't read that file.")
            }
            guard Date() < deadline else {
                await deleteFiles([file.uploaded])
                throw MemoryAIError.network("Gemini took too long to take in the file. Try again.")
            }
            if filePollInterval > 0 { try await Task.sleep(nanoseconds: UInt64(filePollInterval * 1_000_000_000)) }
            let (data, _) = try await sendForResponse(fileRequest(file.uploaded.name, method: "GET"), model: generationModelID)
            file = try Self.fileInfo(from: data, keepingURI: file.uploaded.uri)
        }
        return file.uploaded
    }

    /// Best effort: Gemini would delete them after 48 hours anyway.
    private func deleteFiles(_ files: [UploadedFile]) async {
        for file in files {
            guard let request = try? fileRequest(file.name, method: "DELETE") else { continue }
            _ = try? await transport(request)
        }
    }

    /// `{"file": {name, uri, state}}` (upload) or the bare File (GET).
    static func fileInfo(from data: Data, keepingURI: String? = nil) throws -> (uploaded: UploadedFile, state: String) {
        let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        let file = (root?["file"] as? [String: Any]) ?? root
        guard let name = file?["name"] as? String, !name.isEmpty,
              let uri = (file?["uri"] as? String) ?? keepingURI, !uri.isEmpty else {
            throw MemoryAIError.badResponse("Gemini didn't accept the upload. Try again.")
        }
        // Audio is usually ACTIVE at once; a missing state means it's ready.
        let state = (file?["state"] as? String) ?? "ACTIVE"
        return (UploadedFile(name: name, uri: uri), state == "STATE_UNSPECIFIED" ? "ACTIVE" : state)
    }

    // MARK: Sending

    private func send(_ request: URLRequest, model: String) async throws -> Data {
        try await sendForResponse(request, model: model).data
    }

    private func sendForResponse(_ request: URLRequest, model: String) async throws -> (data: Data, response: HTTPURLResponse) {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await transport(request)
        } catch {
            throw Self.transportError(error)
        }
        try Task.checkCancellation()
        guard let http = response as? HTTPURLResponse else {
            throw MemoryAIError.badResponse("Gemini didn't answer. Try again.")
        }
        guard (200..<300).contains(http.statusCode) else {
            throw Self.error(status: http.statusCode, body: data, model: model)
        }
        return (data, http)
    }

    // MARK: Errors

    /// Network failures in plain words. Cancelling isn't an error the user needs to see.
    public static func transportError(_ error: Error) -> Error {
        if error is CancellationError || error is MemoryAIError { return error }
        guard let urlError = error as? URLError else { return MemoryAIError.network(error.localizedDescription) }
        switch urlError.code {
        case .cancelled:
            return CancellationError()
        case .notConnectedToInternet, .networkConnectionLost, .dataNotAllowed, .internationalRoamingOff:
            return MemoryAIError.network("You're offline. Check your connection and try again.")
        case .timedOut:
            return MemoryAIError.network("The request timed out. Try again.")
        case .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed:
            return MemoryAIError.network("Google's servers can't be reached right now.")
        case .secureConnectionFailed, .serverCertificateUntrusted, .serverCertificateHasBadDate,
             .serverCertificateNotYetValid, .serverCertificateHasUnknownRoot, .clientCertificateRejected:
            return MemoryAIError.network("The secure connection to Google failed.")
        default:
            return MemoryAIError.network(urlError.localizedDescription)
        }
    }

    /// An HTTP error status as a `MemoryAIError`. 400 is a bad key only when Google says so; 401/403 always are.
    public static func error(status: Int, body: Data, model: String) -> MemoryAIError {
        let google = GoogleError(body)
        switch status {
        case 401, 403:
            return .badKey
        case 400:
            if google.isAboutTheKey { return .badKey }
            return .badResponse(google.message.map { "Gemini couldn't handle the request: \($0)" }
                ?? "Gemini couldn't handle the request (HTTP 400).")
        case 404:
            return .badResponse("There's no Gemini model called “\(model)”. \(MemoryAIError.settingsHint)")
        case 413:
            return .badResponse("That file is too big for Gemini.")
        case 429, 500...599:
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

    // MARK: Answers

    /// Finish reasons that mean the model refused rather than ran out of room.
    private static let refusals: Set<String> = ["SAFETY", "RECITATION", "BLOCKLIST", "PROHIBITED_CONTENT", "SPII", "LANGUAGE", "OTHER"]

    /// The JSON text in `candidates[0].content.parts[*].text` (thought summaries skipped), checked to parse.
    public static func answer(from data: Data) throws -> Data {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw MemoryAIError.badResponse("Gemini's reply wasn't readable. Try again.")
        }
        guard let candidate = (root["candidates"] as? [Any])?.first as? [String: Any] else {
            if let feedback = root["promptFeedback"] as? [String: Any], feedback["blockReason"] != nil {
                throw MemoryAIError.badResponse(declined)
            }
            throw MemoryAIError.badResponse(empty)
        }
        let parts = ((candidate["content"] as? [String: Any])?["parts"] as? [Any] ?? []).compactMap { $0 as? [String: Any] }
        let text = parts.filter { ($0["thought"] as? Bool) != true }.compactMap { $0["text"] as? String }.joined()
        let finish = candidate["finishReason"] as? String ?? ""
        let json = stripCodeFence(text)

        guard !json.isEmpty else {
            if finish == "MAX_TOKENS" { throw MemoryAIError.badResponse(cutOff) }
            if refusals.contains(finish) { throw MemoryAIError.badResponse(declined) }
            throw MemoryAIError.badResponse(empty)
        }
        let payload = Data(json.utf8)
        guard (try? JSONSerialization.jsonObject(with: payload)) is [String: Any] else {
            if finish == "MAX_TOKENS" { throw MemoryAIError.badResponse(cutOff) }
            throw MemoryAIError.badResponse(MemoryAIError.unexpectedFormat)
        }
        return payload
    }

    /// `{"embedding": {"values": [...]}}`
    static func vector(from data: Data) throws -> [Float] {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let embedding = root["embedding"] as? [String: Any],
              let values = numbers(embedding["values"]), !values.isEmpty else {
            throw MemoryAIError.badResponse(MemoryAIError.unexpectedFormat)
        }
        return values
    }

    /// `{"embeddings": [{"values": [...]}, …]}`
    static func vectors(from data: Data) throws -> [[Float]] {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let list = root["embeddings"] as? [Any] else {
            throw MemoryAIError.badResponse(MemoryAIError.unexpectedFormat)
        }
        return try list.map {
            guard let values = numbers(($0 as? [String: Any])?["values"]), !values.isEmpty else {
                throw MemoryAIError.badResponse(MemoryAIError.unexpectedFormat)
            }
            return values
        }
    }

    private static func numbers(_ value: Any?) -> [Float]? {
        (value as? [Any])?.compactMap { ($0 as? NSNumber)?.floatValue }
    }

    private static let declined = "Gemini declined to answer this one. Try rewording it."
    private static let empty = "Gemini's answer was empty. Try again."
    private static let cutOff = "Gemini's answer got cut off. Try with less text."

    /// JSON mode answers are bare JSON, but tolerate a ```json fence around it.
    private static func stripCodeFence(_ text: String) -> String {
        var s = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard s.hasPrefix("```") else { return s }
        s = String(s.drop { $0 != "\n" }.dropFirst())
        if s.hasSuffix("```") { s = String(s.dropLast(3)) }
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
