import XCTest
@testable import MemoryKit

final class GeminiMemoryAITests: XCTestCase {
    func testEmbedRequestShapeMirrorsEngram() async throws {
        let fake = FakeTransport()
        fake.reply(json: ["embedding": ["values": [0.1, 0.2, 0.3]]])
        let ai = GeminiMemoryAI(apiKey: "secret-key", transport: fake.transport)
        let vectors = try await ai.embed(["Hello world"], task: .query)
        XCTAssertEqual(vectors, [[0.1, 0.2, 0.3]])

        let request = try XCTUnwrap(fake.requests.first)
        XCTAssertEqual(request.url?.absoluteString, "https://generativelanguage.googleapis.com/v1beta/models/gemini-embedding-2:embedContent")
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.value(forHTTPHeaderField: "x-goog-api-key"), "secret-key")
        XCTAssertFalse(request.url!.absoluteString.contains("secret-key"), "the key never goes in the URL")
        let body = request.jsonBody
        XCTAssertEqual(body["outputDimensionality"] as? Int, 768)
        let parts = ((body["content"] as? [String: Any])?["parts"] as? [[String: Any]])
        XCTAssertEqual(parts?.first?["text"] as? String, "task: search result | query: Hello world")
    }

    func testBatchEmbedForManyTexts() async throws {
        let fake = FakeTransport()
        fake.reply(json: ["embeddings": [["values": [1, 0]], ["values": [0, 1]]]])
        let ai = GeminiMemoryAI(apiKey: "k", embeddingDimensions: 2, transport: fake.transport)
        let vectors = try await ai.embed(["one", "two"], task: .document)
        XCTAssertEqual(vectors, [[1, 0], [0, 1]])
        let request = try XCTUnwrap(fake.requests.first)
        XCTAssertTrue(request.url!.absoluteString.hasSuffix("gemini-embedding-2:batchEmbedContents"))
        let requests = try XCTUnwrap(request.jsonBody["requests"] as? [[String: Any]])
        XCTAssertEqual(requests.count, 2)
        XCTAssertEqual(requests[0]["model"] as? String, "models/gemini-embedding-2")
        XCTAssertEqual(requests[0]["outputDimensionality"] as? Int, 2)
        XCTAssertEqual(((requests[1]["content"] as? [String: Any])?["parts"] as? [[String: Any]])?.first?["text"] as? String,
                       "title: none | text: two")
    }

    func testBatchesAreChunkedAtOneHundred() async throws {
        let fake = FakeTransport()
        fake.reply(json: ["embeddings": Array(repeating: ["values": [1]], count: 100)])
        fake.reply(json: ["embeddings": Array(repeating: ["values": [1]], count: 50)])
        let ai = GeminiMemoryAI(apiKey: "k", embeddingDimensions: 1, transport: fake.transport)
        let vectors = try await ai.embed((0..<150).map { "t\($0)" }, task: .document)
        XCTAssertEqual(vectors.count, 150)
        XCTAssertEqual(fake.requests.count, 2)
    }

    func testGenerateRequestShape() async throws {
        let fake = FakeTransport()
        fake.answer(#"{"ok": true}"#)
        let ai = GeminiMemoryAI(apiKey: "k", model: "models/gemini-3.5-flash", transport: fake.transport)
        let image = MemoryInlinePart(mimeType: "image/png", data: Data([1, 2, 3]))
        let data = try await ai.generateJSON(system: "SYS", prompt: "PROMPT", schema: MemoryPrompts.askSchema, parts: [image])
        XCTAssertEqual(try JSONSerialization.jsonObject(with: data) as? [String: Bool], ["ok": true])

        let request = try XCTUnwrap(fake.requests.first)
        XCTAssertEqual(request.url?.absoluteString, "https://generativelanguage.googleapis.com/v1beta/models/gemini-3.5-flash:generateContent")
        let body = request.jsonBody
        let config = try XCTUnwrap(body["generationConfig"] as? [String: Any])
        XCTAssertEqual(config["responseMimeType"] as? String, "application/json")
        XCTAssertEqual((config["thinkingConfig"] as? [String: Any])?["thinkingLevel"] as? String, "low")
        let schema = try XCTUnwrap(config["responseJsonSchema"] as? [String: Any])
        XCTAssertEqual((schema["required"] as? [String])?.sorted(), ["answer", "answerable", "citations", "followUps"])
        XCTAssertEqual(((body["systemInstruction"] as? [String: Any])?["parts"] as? [[String: Any]])?.first?["text"] as? String, "SYS")
        let parts = try XCTUnwrap(((body["contents"] as? [[String: Any]])?.first?["parts"]) as? [[String: Any]])
        XCTAssertEqual(parts[0]["text"] as? String, "PROMPT")
        let inline = try XCTUnwrap(parts[1]["inlineData"] as? [String: Any])
        XCTAssertEqual(inline["mimeType"] as? String, "image/png")
        XCTAssertEqual(inline["data"] as? String, Data([1, 2, 3]).base64EncodedString())
    }

    func testErrorsInPlainWords() async {
        let fake = FakeTransport()
        fake.reply(status: 403, json: ["error": ["message": "denied"]])
        fake.reply(status: 400, json: ["error": ["message": "API key not valid. Please pass a valid API key.", "details": [["reason": "API_KEY_INVALID"]]]])
        fake.reply(status: 429, json: [:])
        fake.reply(status: 404, json: [:])
        fake.fail(URLError(.notConnectedToInternet))
        fake.answer("", finish: "SAFETY")
        let ai = GeminiMemoryAI(apiKey: "k", transport: fake.transport)

        func error(_ op: () async throws -> Void) async -> MemoryAIError? {
            do { try await op(); return nil } catch { return error as? MemoryAIError }
        }
        let gen = { _ = try await ai.generateJSON(system: "s", prompt: "p", schema: ["type": "object"]) }
        let e1 = await error(gen)
        let e2 = await error(gen)
        let e3 = await error(gen)
        let e4 = await error(gen)
        let e5 = await error(gen)
        let e6 = await error(gen)
        XCTAssertEqual(e1, .badKey)
        XCTAssertEqual(e2, .badKey)
        XCTAssertEqual(e3, .rateLimited)
        XCTAssertTrue(e4?.localizedDescription.contains("no Gemini model") == true)
        XCTAssertTrue(e4?.needsSettings == true)
        XCTAssertEqual(e5, .network("You're offline. Check your connection and try again."))
        XCTAssertTrue(e5?.isTransient == true)
        XCTAssertEqual(e6, .badResponse("Gemini declined to answer this one. Try rewording it."))
    }

    func testEmptyKeyIsNotConfigured() async {
        let ai = GeminiMemoryAI(apiKey: "  ", transport: FakeTransport().transport)
        do {
            _ = try await ai.embed(["x"], task: .query)
            XCTFail("should throw")
        } catch {
            XCTAssertEqual(error as? MemoryAIError, .notConfigured)
        }
    }

    func testOfflineUnderTestsByDefault() async {
        XCTAssertTrue(GeminiMemoryAI.isUnitTesting)
        let ai = GeminiMemoryAI(apiKey: "real-looking-key")
        do {
            _ = try await ai.embed(["x"], task: .query)
            XCTFail("tests must never reach the network")
        } catch {
            XCTAssertEqual((error as? MemoryAIError)?.isTransient, true)
        }
    }

    func testAnswerToleratesCodeFenceAndSkipsThoughts() throws {
        let envelope: [String: Any] = ["candidates": [["content": ["parts": [["text": "thinking…", "thought": true], ["text": "```json\n{\"a\":1}\n```"]]], "finishReason": "STOP"]]]
        let data = try GeminiMemoryAI.answer(from: JSONSerialization.data(withJSONObject: envelope))
        XCTAssertEqual(try JSONSerialization.jsonObject(with: data) as? [String: Int], ["a": 1])
    }
}
