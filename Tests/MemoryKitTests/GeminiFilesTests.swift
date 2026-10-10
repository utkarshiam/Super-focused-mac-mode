import XCTest
@testable import MemoryKit

/// Big files go through the Files API, small ones inline, audio MIME types as Gemini names them.
/// Everything runs against `FakeTransport`; nothing reaches the network.
final class GeminiFilesTests: XCTestCase {
    private func userParts(_ request: URLRequest) throws -> [[String: Any]] {
        try XCTUnwrap(((request.jsonBody["contents"] as? [[String: Any]])?.first?["parts"]) as? [[String: Any]])
    }

    func testAudioMimeTypesAreTheOnesGeminiLists() {
        XCTAssertEqual(MimeType.forExtension("m4a"), "audio/mp4", "stored attachments keep the standard name")
        XCTAssertEqual(MimeType.forGemini("audio/mp4"), "audio/m4a")
        XCTAssertEqual(MimeType.forGemini("audio/x-m4a"), "audio/m4a")
        XCTAssertEqual(MimeType.forGemini("audio/x-wav"), "audio/wav")
        XCTAssertEqual(MimeType.forGemini("audio/x-aiff"), "audio/aiff")
        XCTAssertEqual(MimeType.forGemini("audio/mpeg"), "audio/mpeg")
        XCTAssertEqual(MimeType.forGemini("image/png"), "image/png")
        // Every audio type MemoryKit maps an extension to, except CAF (Gemini has no CAF), is on Gemini's list.
        let listed: Set<String> = ["audio/wav", "audio/mp3", "audio/aiff", "audio/aac", "audio/ogg", "audio/flac", "audio/mpeg",
                                   "audio/m4a", "audio/l16", "audio/opus", "audio/alaw", "audio/mulaw", "audio/webm"]
        for ext in ["m4a", "mp3", "wav", "aac", "aif", "aiff", "ogg", "opus", "flac"] {
            XCTAssertTrue(listed.contains(MimeType.forGemini(MimeType.forExtension(ext))), ext)
        }
    }

    func testSmallAudioGoesInlineAsM4A() async throws {
        let fake = FakeTransport()
        fake.answer(#"{"ok": true}"#)
        let ai = GeminiMemoryAI(apiKey: "k", transport: fake.transport)
        let audio = MemoryInlinePart(mimeType: "audio/mp4", data: Data(repeating: 7, count: 2048))
        _ = try await ai.generateJSON(system: "s", prompt: "p", schema: ["type": "object"], parts: [audio])

        XCTAssertEqual(fake.requests.count, 1, "no upload for a small file")
        let parts = try userParts(fake.requests[0])
        let inline = try XCTUnwrap(parts[1]["inlineData"] as? [String: Any])
        XCTAssertEqual(inline["mimeType"] as? String, "audio/m4a")
        XCTAssertEqual(inline["data"] as? String, audio.data.base64EncodedString())
    }

    func testOnlyTheBiggestPartsAreUploaded() {
        let budget = 100
        let parts = [MemoryInlinePart(mimeType: "image/png", data: Data(count: 30)),
                     MemoryInlinePart(mimeType: "audio/mp4", data: Data(count: 90)),
                     MemoryInlinePart(mimeType: "image/png", data: Data(count: 40))]
        XCTAssertEqual(GeminiMemoryAI.partsToUpload(parts, budget: budget), [1])
        XCTAssertEqual(GeminiMemoryAI.partsToUpload(Array(parts.prefix(1)), budget: budget), [])
        XCTAssertEqual(GeminiMemoryAI.partsToUpload(parts, budget: 20), [0, 1, 2])
        XCTAssertEqual(GeminiMemoryAI.partsToUpload(parts, budget: 70), [1])
    }

    func testLargeAudioIsUploadedThenReferencedThenDeleted() async throws {
        let fake = FakeTransport()
        let uploadURL = "https://generativelanguage.googleapis.com/upload/v1beta/files?upload_id=abc&upload_protocol=resumable"
        fake.reply(body: Data("{}".utf8), headers: ["X-Goog-Upload-URL": uploadURL])
        fake.reply(json: ["file": ["name": "files/rec1", "uri": "https://generativelanguage.googleapis.com/v1beta/files/rec1",
                                   "mimeType": "audio/m4a", "state": "PROCESSING"]])
        fake.reply(json: ["name": "files/rec1", "uri": "https://generativelanguage.googleapis.com/v1beta/files/rec1", "state": "ACTIVE"])
        fake.answer(#"{"ok": true}"#)
        fake.reply(json: [:]) // delete

        let ai = GeminiMemoryAI(apiKey: "secret", transport: fake.transport, filePollInterval: 0)
        let big = MemoryInlinePart(mimeType: "audio/mp4", data: Data(repeating: 1, count: MemoryInlinePart.inlineBudget + 1))
        let small = MemoryInlinePart(mimeType: "image/png", data: Data([1, 2, 3]))
        let data = try await ai.generateJSON(system: "s", prompt: "p", schema: ["type": "object"], parts: [small, big])
        XCTAssertEqual(try JSONSerialization.jsonObject(with: data) as? [String: Bool], ["ok": true])

        let requests = fake.requests
        XCTAssertEqual(requests.count, 5)
        for request in requests {
            XCTAssertEqual(request.value(forHTTPHeaderField: "x-goog-api-key"), "secret")
            XCTAssertFalse(request.url!.absoluteString.contains("secret"))
        }

        // 1. Start the resumable upload.
        let start = requests[0]
        XCTAssertEqual(start.url?.absoluteString, "https://generativelanguage.googleapis.com/upload/v1beta/files")
        XCTAssertEqual(start.httpMethod, "POST")
        XCTAssertEqual(start.value(forHTTPHeaderField: "X-Goog-Upload-Protocol"), "resumable")
        XCTAssertEqual(start.value(forHTTPHeaderField: "X-Goog-Upload-Command"), "start")
        XCTAssertEqual(start.value(forHTTPHeaderField: "X-Goog-Upload-Header-Content-Length"), String(big.data.count))
        XCTAssertEqual(start.value(forHTTPHeaderField: "X-Goog-Upload-Header-Content-Type"), "audio/m4a")
        XCTAssertNotNil((start.jsonBody["file"] as? [String: Any])?["display_name"])

        // 2. The bytes, to the URL the first reply named.
        let bytes = requests[1]
        XCTAssertEqual(bytes.url?.absoluteString, uploadURL)
        XCTAssertEqual(bytes.value(forHTTPHeaderField: "X-Goog-Upload-Command"), "upload, finalize")
        XCTAssertEqual(bytes.value(forHTTPHeaderField: "X-Goog-Upload-Offset"), "0")
        XCTAssertEqual(bytes.httpBody?.count, big.data.count)

        // 3. Wait for ACTIVE.
        XCTAssertEqual(requests[2].httpMethod, "GET")
        XCTAssertEqual(requests[2].url?.absoluteString, "https://generativelanguage.googleapis.com/v1beta/files/rec1")

        // 4. generateContent: the small file inline, the big one by reference, in the order given.
        XCTAssertTrue(requests[3].url!.absoluteString.hasSuffix(":generateContent"))
        let parts = try userParts(requests[3])
        XCTAssertEqual(parts.count, 3)
        XCTAssertEqual((parts[1]["inlineData"] as? [String: Any])?["mimeType"] as? String, "image/png")
        let fileData = try XCTUnwrap(parts[2]["fileData"] as? [String: Any])
        XCTAssertEqual(fileData["fileUri"] as? String, "https://generativelanguage.googleapis.com/v1beta/files/rec1")
        XCTAssertEqual(fileData["mimeType"] as? String, "audio/m4a")
        XCTAssertNil(parts[2]["inlineData"])
        XCTAssertLessThan(requests[3].httpBody!.count, 4096, "the big file isn't in the request")

        // 5. Cleaned up.
        XCTAssertEqual(requests[4].httpMethod, "DELETE")
        XCTAssertEqual(requests[4].url?.absoluteString, "https://generativelanguage.googleapis.com/v1beta/files/rec1")
    }

    func testUploadFailuresAreSentencesAndCleanUp() async {
        // No upload URL in the reply.
        let noURL = FakeTransport()
        noURL.reply(json: [:])
        let big = MemoryInlinePart(mimeType: "audio/mp4", data: Data(count: MemoryInlinePart.inlineBudget + 10))
        do {
            _ = try await GeminiMemoryAI(apiKey: "k", transport: noURL.transport, filePollInterval: 0)
                .generateJSON(system: "s", prompt: "p", schema: ["type": "object"], parts: [big])
            XCTFail("should throw")
        } catch {
            XCTAssertEqual(error as? MemoryAIError, .badResponse("Gemini didn't accept the upload. Try again."))
        }

        // Processing failed: the file is deleted and the error says so.
        let failed = FakeTransport()
        failed.reply(body: Data("{}".utf8), headers: ["x-goog-upload-url": "https://generativelanguage.googleapis.com/upload/x"])
        failed.reply(json: ["file": ["name": "files/bad", "uri": "https://example/files/bad", "state": "FAILED"]])
        failed.reply(json: [:])
        do {
            _ = try await GeminiMemoryAI(apiKey: "k", transport: failed.transport, filePollInterval: 0)
                .generateJSON(system: "s", prompt: "p", schema: ["type": "object"], parts: [big])
            XCTFail("should throw")
        } catch {
            XCTAssertEqual(error as? MemoryAIError, .badResponse("Gemini couldn't read that file."))
        }
        XCTAssertEqual(failed.requests.last?.httpMethod, "DELETE")

        // Offline during the upload: transient, so the phone keeps the recording and retries.
        let offline = FakeTransport()
        offline.fail(URLError(.notConnectedToInternet))
        do {
            _ = try await GeminiMemoryAI(apiKey: "k", transport: offline.transport, filePollInterval: 0)
                .generateJSON(system: "s", prompt: "p", schema: ["type": "object"], parts: [big])
            XCTFail("should throw")
        } catch {
            XCTAssertEqual((error as? MemoryAIError)?.isTransient, true)
        }
    }

    func testGenerateFailureAfterUploadStillDeletesTheFile() async {
        let fake = FakeTransport()
        fake.reply(body: Data("{}".utf8), headers: ["x-goog-upload-url": "https://generativelanguage.googleapis.com/upload/x"])
        fake.reply(json: ["file": ["name": "files/r", "uri": "https://example/files/r", "state": "ACTIVE"]])
        fake.reply(status: 429, json: [:])
        fake.reply(json: [:])
        let big = MemoryInlinePart(mimeType: "audio/mp4", data: Data(count: MemoryInlinePart.inlineBudget + 10))
        do {
            _ = try await GeminiMemoryAI(apiKey: "k", transport: fake.transport, filePollInterval: 0)
                .generateJSON(system: "s", prompt: "p", schema: ["type": "object"], parts: [big])
            XCTFail("should throw")
        } catch {
            XCTAssertEqual(error as? MemoryAIError, .rateLimited)
        }
        XCTAssertEqual(fake.requests.map(\.httpMethod), ["POST", "POST", "POST", "DELETE"])
    }
}
