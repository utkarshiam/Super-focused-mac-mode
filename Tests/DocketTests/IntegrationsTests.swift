import XCTest
@testable import Docket

// Slack and Gmail without the network: a fake server answers from canned JSON (made-up people and
// companies), the keychain is in memory, and nothing opens a browser.

// MARK: - A fake Slack and Google

/// Stands in for slack.com, gmail.googleapis.com and oauth2.googleapis.com. Each route answers with its
/// replies in turn (the last one repeats) and every request is recorded.
final class FakeIntegrationServer: @unchecked Sendable {
    struct Reply {
        var status = 200
        var body: String
        var headers: [String: String] = [:]
    }

    private struct Route {
        let matches: (URLRequest) -> Bool
        var replies: [Reply]
    }

    private let lock = NSLock()
    private var routes: [Route] = []
    private var recorded: [URLRequest] = []

    var requests: [URLRequest] {
        lock.lock()
        defer { lock.unlock() }
        return recorded
    }

    func on(_ matches: @escaping (URLRequest) -> Bool, _ replies: [Reply]) {
        lock.lock()
        routes.append(Route(matches: matches, replies: replies))
        lock.unlock()
    }

    /// A Slack Web API method, optionally only for one value of a form field (say `user=U0PRIYA`).
    func slack(_ method: String, where field: (String, String)? = nil, _ bodies: String..., status: Int = 200, headers: [String: String] = [:]) {
        slack(method, where: field, replies: bodies, status: status, headers: headers)
    }

    func slack(_ method: String, where field: (String, String)? = nil, replies bodies: [String], status: Int = 200, headers: [String: String] = [:]) {
        on({ request in
            guard request.url?.host == "slack.com", request.url?.path == "/api/\(method)" else { return false }
            guard let field else { return true }
            return Self.form(request)[field.0] == field.1
        }, bodies.map { Reply(status: status, body: $0, headers: headers) })
    }

    /// A Gmail API path under users/me ("profile", "messages", "messages/m1"), optionally for one search.
    func gmail(_ path: String, query: String? = nil, _ replies: Reply...) {
        on({ request in
            guard request.url?.host == "gmail.googleapis.com", request.url?.path == "/gmail/v1/users/me/\(path)" else { return false }
            guard let query else { return true }
            return Self.query(request)["q"] == query
        }, replies)
    }

    func gmail(_ path: String, query: String? = nil, _ body: String) {
        gmail(path, query: query, Reply(body: body))
    }

    /// Google's OAuth endpoints ("/token", "/revoke").
    func google(_ path: String, _ replies: Reply...) {
        on({ $0.url?.host == "oauth2.googleapis.com" && $0.url?.path == path }, replies)
    }

    var transport: IntegrationHTTP.Transport {
        { [self] request in try self.respond(to: request) }
    }

    private func respond(to request: URLRequest) throws -> (Data, HTTPURLResponse) {
        lock.lock()
        defer { lock.unlock() }
        recorded.append(request)
        guard let index = routes.firstIndex(where: { $0.matches(request) }) else { throw URLError(.cannotConnectToHost) }
        let reply = routes[index].replies.count > 1 ? routes[index].replies.removeFirst() : routes[index].replies[0]
        var headers = reply.headers
        headers["Content-Type"] = headers["Content-Type"] ?? "application/json; charset=utf-8"
        let response = HTTPURLResponse(url: request.url ?? URL(fileURLWithPath: "/"), statusCode: reply.status,
                                       httpVersion: "HTTP/1.1", headerFields: headers)
        guard let response else { throw URLError(.badServerResponse) }
        return (Data(reply.body.utf8), response)
    }

    /// Requests to one Slack method, in order.
    func calls(_ method: String) -> [URLRequest] {
        requests.filter { $0.url?.host == "slack.com" && $0.url?.path == "/api/\(method)" }
    }

    func requests(toPath path: String) -> [URLRequest] {
        requests.filter { $0.url?.path == path }
    }

    /// The fields of a form-encoded body.
    static func form(_ request: URLRequest) -> [String: String] {
        guard let body = request.httpBody, let text = String(data: body, encoding: .utf8), !text.isEmpty else { return [:] }
        var fields: [String: String] = [:]
        for pair in text.split(separator: "&") {
            let parts = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            let key = String(parts[0]).removingPercentEncoding ?? ""
            fields[key] = parts.count > 1 ? String(parts[1]).removingPercentEncoding ?? "" : ""
        }
        return fields
    }

    static func query(_ request: URLRequest) -> [String: String] {
        guard let url = request.url, let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems else { return [:] }
        return Dictionary(items.map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { first, _ in first })
    }
}

/// Collects what the fake AI was asked.
@MainActor
private final class TriageLog {
    var batches: [[IncomingMessage]] = []
}

/// How long a client was told to wait.
private actor SleepLog {
    var seconds: [TimeInterval] = []
    func add(_ s: TimeInterval) { seconds.append(s) }
}

// MARK: - Fixtures (made-up workspace: Acme Test; people: Maya Chen, Priya Shah, Sam Lee)

private enum Fixture {
    static let token = "xoxp-1111-2222-3333-test"
    static let me = "U0MAYA"
    static let account = SlackAccount(userID: me, userName: "maya", teamID: "T0ACME", teamName: "Acme Test",
                                      teamURL: URL(string: "https://acme-test.slack.com/"))
    static let allScopes = SlackManifest.userScopes.joined(separator: ",")

    static func ts(_ date: Date) -> String { String(format: "%.6f", date.timeIntervalSince1970) }

    static let authTest = #"{"ok":true,"url":"https://acme-test.slack.com/","team":"Acme Test","user":"maya","team_id":"T0ACME","user_id":"U0MAYA"}"#

    static func user(_ id: String, _ handle: String, _ name: String, status: (String, String, Int) = ("", "", 0)) -> String {
        #"{"ok":true,"user":{"id":"\#(id)","name":"\#(handle)","real_name":"\#(name)","profile":{"real_name":"\#(name)","display_name":"\#(handle)","status_text":"\#(status.0)","status_emoji":"\#(status.1)","status_expiration":\#(status.2)}}}"#
    }

    static func channel(_ id: String, _ name: String) -> String {
        #"{"ok":true,"channel":{"id":"\#(id)","name":"\#(name)","is_channel":true,"is_private":false,"is_member":true}}"#
    }

    static let directMessage = #"{"ok":true,"channel":{"id":"D0DM","is_im":true,"user":"U0SAM"}}"#

    /// What Maya reacted to: a 📌 on a request in #leadership, 👀 on something else, a file, an old 📌, a 📌 on a
    /// shared file in #general, and one item Docket can't read.
    static func reactions(now: Date, extra: String = "") -> String {
        """
        {"ok":true,"items":[
          {"type":"message","channel":"C0LEAD","message":{"type":"message","ts":"\(ts(now.addingTimeInterval(-3600)))","user":"U0PRIYA",
            "text":"Can you send the <https://docs.example.com/q3|Q3 deck> to <@U0SAM> by Friday? &amp; thanks",
            "reactions":[{"name":"pushpin","users":["U0MAYA"],"count":1},{"name":"eyes","users":["U0SAM"],"count":1}],
            "permalink":"https://acme-test.slack.com/archives/C0LEAD/p1000"}},
          {"type":"message","channel":"C0LEAD","message":{"ts":"\(ts(now.addingTimeInterval(-7200)))","user":"U0SAM","text":"Lunch?",
            "reactions":[{"name":"eyes","users":["U0MAYA"],"count":1}]}},
          {"type":"file","file":{"id":"F0FILE","name":"notes.txt"}},
          {"type":"message","channel":"C0GEN","message":{"ts":"\(ts(now.addingTimeInterval(-40 * 86_400)))","user":"U0SAM","text":"An old one",
            "reactions":[{"name":"pushpin","users":["U0MAYA"],"count":1}]}},
          {"type":"message","channel":"C0GEN","message":{"ts":"\(ts(now.addingTimeInterval(-5400)))","user":"U0SAM","text":"",
            "files":[{"name":"offsite.pdf","title":"Offsite plan"}],
            "reactions":[{"name":"pushpin::skin-tone-2","users":["U0MAYA"],"count":1}]}},
          \(extra)
          {"bogus":true}
        ],"response_metadata":{"next_cursor":""}}
        """
    }

    /// The DM about hiring, saved with 📌 later.
    static func savedHiringDM(now: Date) -> String {
        #"{"type":"message","channel":"D0DM","message":{"ts":"\#(ts(now.addingTimeInterval(-1800)))","user":"U0SAM","text":"<@U0MAYA> quick question about hiring","reactions":[{"name":"pushpin","users":["U0MAYA"],"count":1}],"permalink":"https://acme-test.slack.com/archives/D0DM/p3000"}},"#
    }

    /// Messages that mention Maya: a request in #leadership, a DM, her own message, a join, an old one.
    static func mentions(now: Date) -> String {
        """
        {"ok":true,"query":"<@U0MAYA>","messages":{"total":5,"matches":[
          {"type":"message","channel":{"id":"C0LEAD","name":"leadership","is_private":false},"user":"U0PRIYA","username":"priya",
            "ts":"\(ts(now.addingTimeInterval(-600)))","text":"<@U0MAYA> can you approve the Q4 budget today?",
            "permalink":"https://acme-test.slack.com/archives/C0LEAD/p2000"},
          {"type":"message","channel":{"id":"D0DM","is_im":true},"user":"U0SAM","username":"sam",
            "ts":"\(ts(now.addingTimeInterval(-1800)))","text":"<@U0MAYA> quick question about hiring",
            "permalink":"https://acme-test.slack.com/archives/D0DM/p3000"},
          {"type":"message","channel":{"id":"C0GEN","name":"general"},"user":"U0MAYA","ts":"\(ts(now.addingTimeInterval(-900)))",
            "text":"Thanks <@U0MAYA>"},
          {"type":"message","subtype":"channel_join","channel":{"id":"C0GEN","name":"general"},"user":"U0NEW",
            "ts":"\(ts(now.addingTimeInterval(-300)))","text":"<@U0MAYA> has joined"},
          {"type":"message","channel":{"id":"C0GEN","name":"general"},"user":"U0SAM","ts":"\(ts(now.addingTimeInterval(-5 * 86_400)))",
            "text":"<@U0MAYA> from last week"}
        ]}}
        """
    }

    /// The people and channels the messages above mention.
    static func names(on server: FakeIntegrationServer) {
        server.slack("users.info", where: ("user", "U0PRIYA"), user("U0PRIYA", "priya", "Priya Shah"))
        server.slack("users.info", where: ("user", "U0SAM"), user("U0SAM", "sam", "Sam Lee"))
        server.slack("users.info", where: ("user", "U0MAYA"), user("U0MAYA", "maya", "Maya Chen"))
        server.slack("conversations.info", where: ("channel", "C0LEAD"), channel("C0LEAD", "leadership"))
        server.slack("conversations.info", where: ("channel", "C0GEN"), channel("C0GEN", "general"))
        server.slack("conversations.info", where: ("channel", "D0DM"), directMessage)
    }

    // Gmail
    static let address = "maya@acme.example"
    static let accessToken = #"{"access_token":"ya29.test-access","expires_in":3599,"scope":"openid https://www.googleapis.com/auth/gmail.readonly","token_type":"Bearer"}"#

    static func list(_ refs: [(String, String)]) -> String {
        let items = refs.map { #"{"id":"\#($0.0)","threadId":"\#($0.1)"}"# }.joined(separator: ",")
        return #"{"messages":[\#(items)],"resultSizeEstimate":\#(refs.count)}"#
    }

    static func email(_ id: String, thread: String, from: String, subject: String, snippet: String, at date: Date) -> String {
        let from = from.replacingOccurrences(of: "\"", with: "\\\"")
        return """
        {"id":"\(id)","threadId":"\(thread)","labelIds":["INBOX","IMPORTANT"],"snippet":"\(snippet)",
         "internalDate":"\(Int64(date.timeIntervalSince1970 * 1000))",
         "payload":{"headers":[{"name":"From","value":"\(from)"},{"name":"Subject","value":"\(subject)"},
           {"name":"Date","value":"Mon, 5 Oct 2026 09:12:00 -0700"}]}}
        """
    }
}

// MARK: - Sign-in pieces (pure)

final class GoogleSignInTests: XCTestCase {
    func testPKCEChallengeMatchesRFC7636() {
        // RFC 7636, appendix B: these 32 octets are the verifier, and S256 of it is the challenge.
        let octets: [UInt8] = [116, 24, 223, 180, 151, 153, 224, 37, 79, 250, 96, 125, 216, 173, 187, 186,
                               22, 212, 37, 77, 105, 214, 191, 240, 91, 88, 5, 88, 83, 132, 141, 121]
        XCTAssertEqual(GoogleOAuth.PKCE.base64URL(Data(octets)), "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk")
        XCTAssertEqual(GoogleOAuth.PKCE.challenge(for: "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"),
                       "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")

        let verifier = GoogleOAuth.PKCE.makeVerifier()
        XCTAssertEqual(verifier.count, 43, "32 random bytes as base64url")
        XCTAssertTrue(verifier.unicodeScalars.allSatisfy { CharacterSet.alphanumerics.contains($0) || $0 == "-" || $0 == "_" })
        XCTAssertNotEqual(verifier, GoogleOAuth.PKCE.makeVerifier())
        XCTAssertEqual(GoogleOAuth.PKCE.base64URL(Data([0xFB, 0xFF, 0xFE])), "-__-", "URL-safe alphabet, no padding")
    }

    func testAuthorizationURLAsksForReadOnlyGmailWithPKCE() throws {
        let client = GoogleOAuth.Client(id: "1234-test.apps.googleusercontent.com", secret: "test-client-secret")
        let url = try XCTUnwrap(GoogleOAuth.authorizationURL(client: client, redirectURI: "http://127.0.0.1:49152",
                                                             state: "st4te_x-1", challenge: "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM"))
        XCTAssertEqual(url.scheme, "https")
        XCTAssertEqual(url.host, "accounts.google.com")
        let items = Dictionary(uniqueKeysWithValues: (URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        XCTAssertEqual(items["client_id"], client.id)
        XCTAssertEqual(items["redirect_uri"], "http://127.0.0.1:49152")
        XCTAssertEqual(items["response_type"], "code")
        XCTAssertEqual(items["scope"], "openid email https://www.googleapis.com/auth/gmail.readonly")
        XCTAssertEqual(items["state"], "st4te_x-1")
        XCTAssertEqual(items["code_challenge"], "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
        XCTAssertEqual(items["code_challenge_method"], "S256")
        XCTAssertEqual(items["access_type"], "offline")
        XCTAssertEqual(items["prompt"], "consent")
        XCTAssertFalse(url.absoluteString.contains(client.secret), "the client secret never goes to the browser")
    }

    func testLoopbackAcceptsOnlyTheRedirectCarryingItsState() {
        let state = "Zx9_state-123"
        func parse(_ line: String) -> LoopbackServer.Redirect? {
            LoopbackServer.parse(requestHead: line + "\r\nHost: 127.0.0.1:49152\r\nAccept: text/html", expectedState: state)
        }
        // Google's redirect: the code is percent-encoded ("4/0Ab…").
        XCTAssertEqual(parse("GET /?state=\(state)&code=4%2F0AbCd-xyz&scope=email%20openid HTTP/1.1"), .code("4/0AbCd-xyz"))
        XCTAssertEqual(parse("GET /?code=abc&state=\(state) HTTP/1.1"), .code("abc"))
        XCTAssertEqual(parse("GET /?error=access_denied&state=\(state) HTTP/1.1"), .denied("access_denied"))

        XCTAssertNil(parse("GET /?state=wrong&code=abc HTTP/1.1"), "another state")
        XCTAssertNil(parse("GET /?state=\(state)x&code=abc HTTP/1.1"))
        XCTAssertNil(parse("GET /?code=abc HTTP/1.1"), "no state")
        XCTAssertNil(parse("GET /?state=\(state)&state=\(state)&code=abc HTTP/1.1"), "state twice")
        XCTAssertNil(parse("GET /?state=\(state)&code=abc&code=def HTTP/1.1"), "code twice")
        XCTAssertNil(parse("GET /?state=\(state) HTTP/1.1"), "neither a code nor an error")
        XCTAssertNil(parse("GET /?state=\(state)&code= HTTP/1.1"), "an empty code")
        XCTAssertNil(parse("POST /?state=\(state)&code=abc HTTP/1.1"))
        XCTAssertNil(parse("GET /favicon.ico HTTP/1.1"))
        XCTAssertNil(parse("GET /callback?state=\(state)&code=abc HTTP/1.1"))
        XCTAssertNil(parse("GET /?state=\(state)&code=abc"), "not HTTP")
        XCTAssertNil(parse("GET http://evil.example/?state=\(state)&code=abc HTTP/1.1"))
        XCTAssertNil(parse(""))
    }

    func testLoopbackWaitsForTheWholeHeadAndAnswersWithASmallPage() {
        XCTAssertNil(LoopbackServer.requestHead(in: Data("GET /?code=1 HTTP/1.1\r\nHost: x\r\n".utf8)))
        XCTAssertEqual(LoopbackServer.requestHead(in: Data("GET / HTTP/1.1\r\nHost: x\r\n\r\n".utf8)), "GET / HTTP/1.1\r\nHost: x")
        XCTAssertTrue(LoopbackServer.constantTimeEquals("abc", "abc"))
        XCTAssertFalse(LoopbackServer.constantTimeEquals("abc", "abd"))
        XCTAssertFalse(LoopbackServer.constantTimeEquals("abc", "abcd"))

        let reply = String(decoding: LoopbackServer.response("200 OK", page: LoopbackServer.signedInPage), as: UTF8.self)
        let parts = reply.components(separatedBy: "\r\n\r\n")
        XCTAssertEqual(parts.count, 2)
        XCTAssertTrue(parts[0].hasPrefix("HTTP/1.1 200 OK\r\n"))
        XCTAssertTrue(parts[0].contains("Content-Length: \(Data(parts[1].utf8).count)"))
        XCTAssertTrue(parts[0].contains("Connection: close"))
        XCTAssertTrue(parts[0].contains("Cache-Control: no-store"))
        XCTAssertTrue(parts[1].contains("You can close this tab"))
    }

    func testCodeExchangeSendsTheVerifierAndReadsTheTokens() async throws {
        let server = FakeIntegrationServer()
        server.google("/token", .init(body: #"{"access_token":"ya29.first","expires_in":3599,"refresh_token":"1//refresh","scope":"openid https://www.googleapis.com/auth/gmail.readonly email","token_type":"Bearer","id_token":"x.y.z"}"#))
        let client = GoogleOAuth.Client(id: "1234-test.apps.googleusercontent.com", secret: "test-client-secret")
        let now = Date()
        let tokens = try await GoogleOAuth.exchange(code: "4/0AbCd", verifier: "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk",
                                                    redirectURI: "http://127.0.0.1:49152", client: client, transport: server.transport, now: now)
        XCTAssertEqual(tokens.accessToken, "ya29.first")
        XCTAssertEqual(tokens.refreshToken, "1//refresh")
        XCTAssertTrue(tokens.scopes.contains(GoogleOAuth.gmailScope))
        XCTAssertEqual(tokens.expiresAt.timeIntervalSince(now), 3599 - 60, accuracy: 1, "a minute early")

        let request = try XCTUnwrap(server.requests.first)
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.url?.absoluteString, "https://oauth2.googleapis.com/token")
        let form = FakeIntegrationServer.form(request)
        XCTAssertEqual(form["grant_type"], "authorization_code")
        XCTAssertEqual(form["code"], "4/0AbCd")
        XCTAssertEqual(form["code_verifier"], "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk")
        XCTAssertEqual(form["redirect_uri"], "http://127.0.0.1:49152")
        XCTAssertEqual(form["client_id"], client.id)
        XCTAssertEqual(form["client_secret"], client.secret)
    }

    func testRefreshKeepsTheRefreshTokenAndARevokedOneSignsOut() async throws {
        let server = FakeIntegrationServer()
        server.google("/token",
                      .init(body: #"{"access_token":"ya29.second","expires_in":3599,"token_type":"Bearer"}"#),
                      .init(status: 400, body: #"{"error":"invalid_grant","error_description":"Token has been expired or revoked."}"#))
        let client = GoogleOAuth.Client(id: "1234-test.apps.googleusercontent.com", secret: "test-client-secret")
        let tokens = try await GoogleOAuth.refresh("1//refresh", client: client, transport: server.transport)
        XCTAssertEqual(tokens.accessToken, "ya29.second")
        XCTAssertEqual(tokens.refreshToken, "1//refresh", "Google doesn't always send a new one")
        XCTAssertEqual(FakeIntegrationServer.form(server.requests[0])["grant_type"], "refresh_token")

        do {
            _ = try await GoogleOAuth.refresh("1//refresh", client: client, transport: server.transport)
            XCTFail("a revoked sign-in must fail")
        } catch {
            XCTAssertEqual(error as? IntegrationError, .signedOut(.gmail))
        }
    }

    func testGmailRetriesOnceWithAFreshAccessToken() async throws {
        let server = FakeIntegrationServer()
        server.gmail("profile",
                     .init(status: 401, body: #"{"error":{"code":401,"message":"Request had invalid authentication credentials.","status":"UNAUTHENTICATED"}}"#),
                     .init(body: #"{"emailAddress":"maya@acme.example","messagesTotal":12}"#))
        server.google("/token", .init(body: #"{"access_token":"ya29.second","expires_in":3599,"token_type":"Bearer"}"#))
        let client = GoogleOAuth.Client(id: "1234-test.apps.googleusercontent.com", secret: "test-client-secret")
        let first = GoogleOAuth.Tokens(accessToken: "ya29.first", expiresAt: Date().addingTimeInterval(3000), refreshToken: "1//refresh", scopes: [])
        let session = GoogleSession(client: client, refreshToken: "1//refresh", transport: server.transport, tokens: first)

        let email = try await GmailClient(session: session, transport: server.transport).profileEmail()
        XCTAssertEqual(email, "maya@acme.example")
        let profileCalls = server.requests(toPath: "/gmail/v1/users/me/profile")
        XCTAssertEqual(profileCalls.map { $0.value(forHTTPHeaderField: "Authorization") }, ["Bearer ya29.first", "Bearer ya29.second"])
        XCTAssertEqual(server.requests(toPath: "/token").count, 1)

        // An expired token is refreshed before the call.
        let stale = GoogleSession(client: client, refreshToken: "1//refresh", transport: server.transport,
                                  tokens: GoogleOAuth.Tokens(accessToken: "ya29.old", expiresAt: Date().addingTimeInterval(-5), refreshToken: nil, scopes: []))
        let token = try await stale.accessToken()
        XCTAssertEqual(token, "ya29.second")
    }

    func testGoogleErrorsInPlainWords() {
        let disabled = Data(#"{"error":{"code":403,"message":"Gmail API has not been used in project 123 before or it is disabled.","errors":[{"reason":"accessNotConfigured"}],"status":"PERMISSION_DENIED"}}"#.utf8)
        guard case .api(.gmail, let message) = GmailClient.error(status: 403, data: disabled) else { return XCTFail("expected a readable error") }
        XCTAssertTrue(message.contains("Gmail API is turned off"))
        XCTAssertEqual(GmailClient.error(status: 429, data: Data()), .rateLimited(.gmail, retryAfter: 60))
        XCTAssertEqual(GmailClient.error(status: 401, data: Data("not json".utf8)), .signedOut(.gmail))
        let scope = Data(#"{"error":{"code":403,"message":"Request had insufficient authentication scopes.","details":[{"reason":"ACCESS_TOKEN_SCOPE_INSUFFICIENT"}]}}"#.utf8)
        XCTAssertEqual(GmailClient.error(status: 403, data: scope), .missingPermission(.gmail, "read your email"))
        XCTAssertEqual(GmailClient.error(status: 500, data: Data()), .unexpected(.gmail, "HTTP 500"))
    }
}

// MARK: - Slack, piece by piece

final class SlackClientTests: XCTestCase {
    func testManifestURLCarriesTheWholeManifest() throws {
        let prefix = "https://api.slack.com/apps?new_app=1&manifest_json="
        let url = SlackManifest.createAppURL
        XCTAssertTrue(url.absoluteString.hasPrefix(prefix))
        let encoded = url.absoluteString.dropFirst(prefix.count)
        XCTAssertFalse(encoded.contains { "{}\"' :,&+#[]/?=".contains($0) }, "every reserved character is escaped")

        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        XCTAssertEqual(items.first { $0.name == "new_app" }?.value, "1")
        let json = try XCTUnwrap(items.first { $0.name == "manifest_json" }?.value)
        XCTAssertEqual(json, SlackManifest.json, "decodes back to exactly the manifest")

        let manifest = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        let display = try XCTUnwrap(manifest["display_information"] as? [String: Any])
        XCTAssertEqual(display["name"] as? String, "Docket")
        let description = try XCTUnwrap(display["description"] as? String)
        XCTAssertFalse(description.isEmpty)
        XCTAssertLessThanOrEqual(description.count, 140, "Slack's limit")
        let scopes = try XCTUnwrap((manifest["oauth_config"] as? [String: Any])?["scopes"] as? [String: Any])
        XCTAssertEqual(Set(scopes["user"] as? [String] ?? []),
                       ["reactions:read", "search:read", "users:read", "users.profile:write", "dnd:write",
                        "chat:write", "channels:read", "groups:read", "im:read", "mpim:read"])
        XCTAssertNil(scopes["bot"], "no bot scopes")
        XCTAssertNil(manifest["features"], "no bot user")
    }

    func testEscapingForQueriesAndForms() {
        XCTAssertEqual(IntegrationHTTP.encode([("q", "a b&c=d+e#f/ü"), ("x", "-._~")]), "q=a%20b%26c%3Dd%2Be%23f%2F%C3%BC&x=-._~")
    }

    func testIdentityReadsTheAccountAndItsScopes() async throws {
        let server = FakeIntegrationServer()
        server.slack("auth.test", Fixture.authTest, headers: ["x-oauth-scopes": "reactions:read, search:read,users:read"])
        let (account, scopes) = try await SlackClient(token: Fixture.token, transport: server.transport).identity()
        XCTAssertEqual(account, Fixture.account)
        XCTAssertEqual(scopes, ["reactions:read", "search:read", "users:read"])

        // Every call is an HTTPS form POST with the token in the header, never in the address.
        let request = try XCTUnwrap(server.requests.first)
        XCTAssertEqual(request.url?.absoluteString, "https://slack.com/api/auth.test")
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer \(Fixture.token)")
        XCTAssertTrue(request.value(forHTTPHeaderField: "Content-Type")?.hasPrefix("application/x-www-form-urlencoded") == true)
        XCTAssertFalse(request.url?.absoluteString.contains("xoxp") == true)
    }

    func testSavedMessagesAreTheOnesYouReactedToRecently() async throws {
        let now = Date()
        let server = FakeIntegrationServer()
        server.slack("reactions.list", Fixture.reactions(now: now))
        let saved = try await SlackClient(token: Fixture.token, transport: server.transport)
            .savedMessages(by: Fixture.me, emoji: "pushpin", since: now.addingTimeInterval(-30 * 86_400))

        XCTAssertEqual(saved.map(\.channelID), ["C0LEAD", "C0GEN"], "👀, files, old saves and unreadable items are left out")
        XCTAssertEqual(saved[0].externalID, "slack:C0LEAD/\(Fixture.ts(now.addingTimeInterval(-3600)))")
        XCTAssertEqual(saved[0].permalink?.absoluteString, "https://acme-test.slack.com/archives/C0LEAD/p1000")
        XCTAssertEqual(saved[0].userID, "U0PRIYA")
        XCTAssertEqual(saved[0].date.timeIntervalSince1970, now.addingTimeInterval(-3600).timeIntervalSince1970, accuracy: 0.001)
        XCTAssertEqual(saved[1].text, "Shared a file: Offsite plan")

        let form = FakeIntegrationServer.form(try XCTUnwrap(server.requests.first))
        XCTAssertEqual(form["user"], Fixture.me)
        XCTAssertEqual(form["full"], "true")
    }

    func testMentionsSkipYourOwnMessagesJoinsAndOldOnes() async throws {
        let now = Date()
        let server = FakeIntegrationServer()
        server.slack("search.messages", Fixture.mentions(now: now))
        let since = now.addingTimeInterval(-3 * 86_400)
        let mentions = try await SlackClient(token: Fixture.token, transport: server.transport).mentions(of: Fixture.me, since: since)

        XCTAssertEqual(mentions.map(\.channelID), ["C0LEAD", "D0DM"])
        XCTAssertEqual(mentions[0].channelName, "leadership")
        XCTAssertTrue(mentions[1].isDirect)
        XCTAssertNil(mentions[1].channelName)

        let form = FakeIntegrationServer.form(try XCTUnwrap(server.requests.first))
        XCTAssertEqual(form["query"], "<@U0MAYA> after:\(Fmt.dayKey(since.addingTimeInterval(-86_400)))")
        XCTAssertEqual(form["sort"], "timestamp")
    }

    func testChannelsAreYoursSortedByName() async throws {
        let server = FakeIntegrationServer()
        server.slack("users.conversations", """
        {"ok":true,"channels":[
          {"id":"C0LEAD","name":"leadership","is_channel":true,"is_private":false},
          {"id":"G0BOARD","name":"board-prep","is_group":true,"is_private":true,"is_member":true},
          {"id":"C0OLD","name":"old-project","is_archived":true},
          {"id":"C0GEN","name":"general"},
          {"name":"no-id"}
        ],"response_metadata":{"next_cursor":"page2"}}
        """, """
        {"ok":true,"channels":[{"id":"C0ALL","name":"all-hands"},{"id":"C0GEN","name":"general"}],"response_metadata":{"next_cursor":""}}
        """)
        let channels = try await SlackClient(token: Fixture.token, transport: server.transport).channels()
        XCTAssertEqual(channels.map(\.name), ["all-hands", "board-prep", "general", "leadership"])
        XCTAssertTrue(channels[1].isPrivate)
        XCTAssertEqual(FakeIntegrationServer.form(server.requests[1])["cursor"], "page2")
    }

    func testSlackErrorsInPlainWords() async {
        let server = FakeIntegrationServer()
        server.slack("auth.test", #"{"ok":false,"error":"invalid_auth"}"#)
        server.slack("reactions.list", #"{"ok":false,"error":"missing_scope","needed":"reactions:read","provided":"chat:write"}"#)
        let client = SlackClient(token: Fixture.token, transport: server.transport)
        do {
            _ = try await client.identity()
            XCTFail("a revoked token must fail")
        } catch {
            XCTAssertEqual(error as? IntegrationError, .signedOut(.slack))
        }
        do {
            _ = try await client.savedMessages(by: Fixture.me, emoji: "pushpin", since: Date())
            XCTFail("a missing scope must fail")
        } catch {
            XCTAssertEqual(error as? IntegrationError, .missingPermission(.slack, "reactions:read"))
        }
    }

    func testShortRateLimitsAreWaitedOutLongOnesReported() async throws {
        let waits = SleepLog()
        let server = FakeIntegrationServer()
        server.on({ $0.url?.path == "/api/auth.test" }, [
            .init(status: 429, body: "", headers: ["Retry-After": "2"]),
            .init(body: Fixture.authTest),
        ])
        server.on({ $0.url?.path == "/api/users.info" }, [.init(status: 429, body: "", headers: ["Retry-After": "120"])])
        server.on({ $0.url?.path == "/api/dnd.endSnooze" }, [.init(status: 429, body: "", headers: ["Retry-After": "1e400"])])
        let client = SlackClient(token: Fixture.token, transport: server.transport, sleep: { await waits.add($0) })

        _ = try await client.identity()
        let waited = await waits.seconds
        XCTAssertEqual(waited, [2])

        do {
            _ = try await client.user("U0SAM")
            XCTFail("a long wait is reported, not slept through")
        } catch {
            XCTAssertEqual(error as? IntegrationError, .rateLimited(.slack, retryAfter: 120))
            XCTAssertEqual((error as? IntegrationError)?.errorDescription, "Slack asked Docket to slow down. It will try again in 2m.")
        }

        // A nonsense Retry-After never traps: it counts as the longest short wait.
        do {
            try await client.endSnooze()
            XCTFail("still limited")
        } catch {
            XCTAssertEqual(error as? IntegrationError, .rateLimited(.slack, retryAfter: SlackClient.longestWait))
        }
        XCTAssertFalse(IntegrationError.rateLimited(.slack, retryAfter: .infinity).errorDescription?.isEmpty ?? true)
        XCTAssertFalse(IntegrationError.rateLimited(.gmail, retryAfter: .nan).errorDescription?.isEmpty ?? true)
    }

    func testSlackMarkupAsPlainText() {
        XCTAssertEqual(SlackText.plain("<@U1|sam> see <#C1|general> &amp; <https://x.example/doc|the doc>"), "@sam see #general & the doc")
        XCTAssertEqual(SlackText.plain("<@U0SAM> ping <#C0LEAD>", users: ["U0SAM": "Sam Lee"], channels: ["C0LEAD": "leadership"]),
                       "@Sam Lee ping #leadership")
        XCTAssertEqual(SlackText.plain("<!here> <!subteam^S1|@design> <mailto:sam@northwind.example> <https://x.example>"),
                       "@here @design sam@northwind.example https://x.example")
        XCTAssertEqual(SlackText.plain("1 &lt; 2 &gt; 0"), "1 < 2 > 0")
        XCTAssertEqual(SlackText.mentionedUserIDs(in: "<@U0SAM> and <@W0PRIYA|priya> but not <#C0LEAD>"), ["U0SAM", "W0PRIYA"])
        XCTAssertEqual(SlackText.firstLine("\n\n  First   line \nSecond"), "First line")
        XCTAssertEqual(SlackText.firstLine("Please review the hiring plan for the platform team before Thursday", limit: 30),
                       "Please review the hiring plan…")
        XCTAssertEqual(SlackText.firstLine("(Draft) Board deck, budget and hiring plan", limit: 30), "(Draft) Board deck, budget…")
        XCTAssertEqual(SlackText.firstLine("Q3 numbers, please!", limit: 30), "Q3 numbers, please!", "short lines stay as they are")
    }

    func testPlanMessageUsesRealDatesTimesAndDurations() {
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        let now = cal.date(bySettingHour: 8, minute: 0, second: 0, of: today)!
        let ten = cal.date(bySettingHour: 10, minute: 0, second: 0, of: today)!
        let yesterday = cal.date(byAdding: .day, value: -1, to: today)!

        var board = TaskItem(title: "Board prep")
        board.dueDate = ten
        board.dueHasTime = true
        board.estimateMinutes = 30
        var reply = TaskItem(title: "Reply to <Northwind> & co")
        reply.scheduledDate = today
        reply.estimateMinutes = 15
        reply.waitingOn = "Sam"
        var ship = TaskItem(title: "Ship v2")
        ship.dueDate = yesterday
        var done = TaskItem(title: "Send the agenda")
        done.scheduledDate = today
        done.completedAt = now

        let message = SlackShare.message(for: [ship, done, reply, board], now: now)
        XCTAssertEqual(message, """
        *Plan for \(Fmt.absoluteDay(today, now: now))*
        • Board prep — \(Fmt.time(ten)) · 30m
        • Reply to &lt;Northwind&gt; &amp; co — 15m · waiting on Sam
        • ~Send the agenda~ ✓
        • Ship v2 — was due \(Fmt.absoluteDay(yesterday, now: now))
        """)

        var later = TaskItem(title: "Offsite logistics")
        later.scheduledDate = cal.date(byAdding: .day, value: 2, to: today)
        let twoDays = SlackShare.message(for: [board, later], now: now)
        XCTAssertTrue(twoDays.hasPrefix("*Plan for \(Fmt.absoluteDay(today, now: now)) – \(Fmt.absoluteDay(later.scheduledDate!, now: now))*\n"))
        XCTAssertTrue(twoDays.contains("• Offsite logistics — \(Fmt.absoluteDay(later.scheduledDate!, now: now))"))
        XCTAssertEqual(SlackShare.message(for: [TaskItem(title: "Someday")], now: now), "*Plan*\n• Someday")
    }
}

// MARK: - Gmail, piece by piece

final class GmailParsingTests: XCTestCase {
    func testSendersSubjectsAndSnippets() {
        let quoted = MailSender(header: #""Lee, Sam" <sam.lee@northwind.example>"#)
        XCTAssertEqual(quoted.name, "Lee, Sam")
        XCTAssertEqual(quoted.address, "sam.lee@northwind.example")
        XCTAssertEqual(quoted.firstName, "Sam")
        XCTAssertEqual(quoted.full, "Lee, Sam <sam.lee@northwind.example>")

        let encoded = MailSender(header: "=?UTF-8?B?\(Data("Priya Shah".utf8).base64EncodedString())?= <priya@contoso.example>")
        XCTAssertEqual(encoded.displayName, "Priya Shah")
        XCTAssertEqual(encoded.firstName, "Priya")

        XCTAssertEqual(MailSender(header: "=?ISO-8859-1?Q?Andr=E9_Dubois?= <andre@fabrikam.example>").name, "André Dubois")
        XCTAssertEqual(MailSender(header: "sam.lee@northwind.example (Sam Lee)").name, "Sam Lee")
        let bare = MailSender(header: "sam.lee@northwind.example")
        XCTAssertNil(bare.name)
        XCTAssertEqual(bare.displayName, "sam.lee@northwind.example")
        XCTAssertEqual(bare.firstName, "Sam")
        XCTAssertEqual(MailSender(header: "").displayName, "Someone")

        XCTAssertEqual(MailText.cleanSubject("Re: Fwd: RE:  Q3   numbers"), "Q3 numbers")
        XCTAssertEqual(MailText.cleanSubject("Intro: Contoso"), "Intro: Contoso")
        XCTAssertEqual(MailText.decodeEntities("Friday&#39;s call &amp; the &quot;deck&quot; &#x1F4C8; &bogus;"), "Friday's call & the \"deck\" 📈 &bogus;")

        let date = MailText.date(fromHeader: "Mon, 5 Oct 2026 10:42:00 -0700 (PDT)")
        XCTAssertEqual(date?.timeIntervalSince1970, 1_791_222_120)
        XCTAssertNil(MailText.date(fromHeader: "yesterday"))
    }

    func testLinksAndIDs() {
        XCTAssertEqual(GmailClient.threadLink(account: Fixture.address, threadID: "18c2f0a1b2")?.absoluteString,
                       "https://mail.google.com/mail/u/maya@acme.example/#all/18c2f0a1b2")
        XCTAssertNil(GmailClient.threadLink(account: Fixture.address, threadID: "../evil"))
        let id = GmailMessage.externalID(thread: "t1", message: "m9")
        XCTAssertEqual(id, "gmail:t1/m9")
        XCTAssertEqual(GmailMessage.threadID(fromExternalID: id), "t1")
        XCTAssertNil(GmailMessage.threadID(fromExternalID: "slack:C0LEAD/1712345678.000100"))
        XCTAssertNil(GmailMessage.threadID(fromExternalID: "gmail:noslash"))
    }

    func testMessageMetadataBecomesAMessage() async throws {
        let server = FakeIntegrationServer()
        let sent = Date(timeIntervalSince1970: 1_791_222_120)
        server.gmail("messages/m1", Fixture.email("m1", thread: "t1", from: #""Lee, Sam" <sam.lee@northwind.example>"#,
                                                  subject: "Re: Q3 numbers", snippet: "Can you send the final numbers before Friday&#39;s call?", at: sent))
        server.gmail("messages/gone", .init(status: 404, body: #"{"error":{"code":404,"message":"Requested entity was not found."}}"#))
        let session = GoogleSession(client: .init(id: "id", secret: "secret"), refreshToken: "1//refresh", transport: server.transport,
                                    tokens: .init(accessToken: "ya29.first", expiresAt: Date().addingTimeInterval(3000), refreshToken: nil, scopes: []))
        let messages = try await GmailClient(session: session, transport: server.transport)
            .messages([GmailRef(id: "m1", threadID: "t1"), GmailRef(id: "gone", threadID: "t9")])

        XCTAssertEqual(messages.count, 1, "a message deleted since it was listed is skipped")
        let m = try XCTUnwrap(messages.first)
        XCTAssertEqual(m.externalID, "gmail:t1/m1")
        XCTAssertEqual(m.sender.firstName, "Sam")
        XCTAssertEqual(m.subject, "Re: Q3 numbers")
        XCTAssertEqual(m.snippet, "Can you send the final numbers before Friday's call?")
        XCTAssertEqual(m.date, sent)

        let query = FakeIntegrationServer.query(try XCTUnwrap(server.requests(toPath: "/gmail/v1/users/me/messages/m1").first))
        XCTAssertEqual(query["format"], "metadata", "never the body")
    }
}

// MARK: - Suggestions: de-duplication, drafts, persistence

@MainActor
final class SuggestionInboxTests: XCTestCase {
    private func suggestion(_ id: String, _ kind: TaskSource.Kind = .slack, minutesAgo: Double, trigger: SuggestionTrigger = .reaction) -> Suggestion {
        Suggestion(source: TaskSource(kind: kind, externalID: id, url: nil, label: "#leadership · Priya Shah"),
                   from: "Priya Shah", subject: nil, snippet: "Text \(id)", receivedAt: Date().addingTimeInterval(-minutesAgo * 60),
                   draft: nil, trigger: trigger)
    }

    func testMergeKeepsNewestFirstWithoutRepeats() {
        let pending = [suggestion("slack:C/1", minutesAgo: 30)]
        let incoming = [suggestion("slack:C/2", minutesAgo: 10), suggestion("slack:C/1", minutesAgo: 30),
                        suggestion("slack:C/3", minutesAgo: 50), suggestion("slack:C/2", minutesAgo: 10), suggestion("slack:C/4", minutesAgo: 5)]
        let merged = SuggestionInbox.merge(incoming, into: pending, blocked: ["slack:C/4"])
        XCTAssertEqual(merged.map(\.id), ["slack:C/2", "slack:C/1", "slack:C/3"])

        let many = (0..<150).map { suggestion("slack:C/\($0)", minutesAgo: Double($0)) }
        let capped = SuggestionInbox.merge(many, into: [], blocked: [])
        XCTAssertEqual(capped.count, SuggestionInbox.limit)
        XCTAssertEqual(capped.last?.id, "slack:C/99", "the oldest go first")
    }

    func testHandledWaitingAndTaskMessagesNeverComeBackButASaveBeatsAnAISkip() {
        let blocked = SuggestionInbox.blockedIDs(pending: [suggestion("slack:C/1", minutesAgo: 1)],
                                                 handled: ["slack:C/2": Date()], taskSourceIDs: ["gmail:t/m"])
        XCTAssertEqual(blocked, ["slack:C/1", "slack:C/2", "gmail:t/m"])
        let skipped = ["slack:C/9": Date()]
        for trigger in [SuggestionTrigger.reaction, .mention, .starred, .needsReply] {
            XCTAssertFalse(SuggestionInbox.isNew("slack:C/2", trigger: trigger, blocked: blocked, skipped: skipped))
            XCTAssertTrue(SuggestionInbox.isNew("slack:C/5", trigger: trigger, blocked: blocked, skipped: skipped))
        }
        // AI saw nothing to do in it: only a reaction or a star (flagging it on purpose) brings it back.
        XCTAssertFalse(SuggestionInbox.isNew("slack:C/9", trigger: .mention, blocked: blocked, skipped: skipped))
        XCTAssertFalse(SuggestionInbox.isNew("slack:C/9", trigger: .needsReply, blocked: blocked, skipped: skipped))
        XCTAssertTrue(SuggestionInbox.isNew("slack:C/9", trigger: .reaction, blocked: blocked, skipped: skipped))
        XCTAssertTrue(SuggestionInbox.isNew("slack:C/9", trigger: .starred, blocked: blocked, skipped: skipped))

        let now = Date()
        let pruned = SuggestionInbox.pruned(["old": now.addingTimeInterval(-SuggestionInbox.memory - 1), "new": now.addingTimeInterval(-60)], now: now)
        XCTAssertEqual(Array(pruned.keys), ["new"])
    }

    func testFallbackDraftsWithoutAI() {
        let email = Suggestion(source: TaskSource(kind: .gmail, externalID: "gmail:t1/m1", url: nil, label: "Lee, Sam · Re: Q3 numbers"),
                               from: "Lee, Sam", subject: "Re: Q3 numbers", snippet: "Can you send the final numbers?",
                               receivedAt: Date(), draft: nil, trigger: .starred)
        let draft = SuggestionDrafts.draft(for: email)
        XCTAssertEqual(draft.title, "Reply to Sam: Q3 numbers")
        XCTAssertEqual(draft.notes, "Lee, Sam · Re: Q3 numbers:\nCan you send the final numbers?")
        XCTAssertEqual(draft.source, email.source)
        XCTAssertEqual(SuggestionDrafts.emailTitle(from: "sam.lee@northwind.example", subject: nil, snippet: "Quick question\nabout pricing"),
                       "Reply to Sam: Quick question")
        XCTAssertEqual(SuggestionDrafts.emailTitle(from: "Priya Shah", subject: "", snippet: ""), "Reply to Priya")

        let slack = Suggestion(source: TaskSource(kind: .slack, externalID: "slack:C0LEAD/1", url: nil, label: "#leadership · Priya Shah"),
                               from: "Priya Shah", subject: nil, snippet: "Can you approve the Q4 budget today?\nThanks",
                               receivedAt: Date(), draft: nil, trigger: .mention)
        XCTAssertEqual(SuggestionDrafts.draft(for: slack).title, "Slack: Can you approve the Q4 budget today?")
        XCTAssertEqual(SuggestionDrafts.draft(for: slack).notes, "#leadership · Priya Shah:\nCan you approve the Q4 budget today?\nThanks")

        // AI's draft wins, keeps its own notes, and always carries the source.
        var ai = TaskDraft(title: "Approve the Q4 budget")
        ai.notes = "Budget is in the shared folder"
        var withAI = slack
        withAI.draft = ai
        let prepared = SuggestionDrafts.draft(for: withAI)
        XCTAssertEqual(prepared.title, "Approve the Q4 budget")
        XCTAssertEqual(prepared.notes, "Budget is in the shared folder")
        XCTAssertEqual(prepared.source, slack.source)

        let task = Integrations.task(for: withAI, lists: [])
        XCTAssertEqual(task.title, "Approve the Q4 budget")
        XCTAssertEqual(task.source, slack.source)
    }

    func testSavedFileSurvivesOddEntriesAndOlderVersions() throws {
        var good = suggestion("slack:C/1", minutesAgo: 5)
        good.receivedAt = Date(timeIntervalSince1970: 1_791_200_000) // the file keeps whole seconds
        good.draft = TaskDraft(title: "Send Priya the deck")
        var file = IntegrationsFile()
        file.suggestions = [good]
        file.handled = ["gmail:t/m": Date(timeIntervalSince1970: 1_790_000_000)]
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: file.encoded()) as? [String: Any])
        var list = try XCTUnwrap(object["suggestions"] as? [Any])
        list.append(["source": ["kind": "carrier-pigeon", "externalID": "x"]]) // from a newer version
        list.append(42)
        object["suggestions"] = list
        object["futureField"] = ["anything": true]
        let decoded = try Persistence.decoder.decode(IntegrationsFile.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertEqual(decoded.suggestions, [good])
        XCTAssertEqual(decoded.handled, file.handled)

        let empty = try Persistence.decoder.decode(IntegrationsFile.self, from: Data("{}".utf8))
        XCTAssertTrue(empty.suggestions.isEmpty)
        XCTAssertNil(empty.slack)
        XCTAssertNil(empty.lastRefresh)
    }
}

// MARK: - The whole loop: refresh, act, undo, save, focus

@MainActor
final class IntegrationsFlowTests: XCTestCase {
    var dir: URL!
    var server: FakeIntegrationServer!
    /// Integrations holds the store weakly (the app delegate owns it); the test owns it here.
    private var stores: [Store] = []

    override func setUp() async throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("docket-integrations-\(UUID().uuidString)")
        server = FakeIntegrationServer()
        Keychain.useInMemoryStore()
    }

    override func tearDown() async throws {
        stores = []
        Keychain.useInMemoryStore()
        try? FileManager.default.removeItem(at: dir)
    }

    /// A store and an Integrations reading `file` from the test folder. No AI unless `triage` says so.
    private func make(_ file: IntegrationsFile? = nil, triage: SuggestionTriage = .none,
                      settings: IntegrationSettings = IntegrationSettings(), app: AppState? = nil) throws -> (Integrations, Store) {
        let store = Store(persistence: Persistence(directory: dir), seedIfEmpty: false)
        stores.append(store)
        if let file { try file.encoded().write(to: dir.appendingPathComponent("integrations.json")) }
        let integrations = Integrations(transport: server.transport, triage: triage, sleep: { _ in })
        integrations.settings = { settings }
        integrations.openURL = { _ in XCTFail("tests never open a browser") }
        integrations.attach(store: store, app: app, directory: dir)
        return (integrations, store)
    }

    private func slackConnected() -> IntegrationsFile {
        Keychain.set(Fixture.token, for: Keychain.Account.slackUserToken)
        var file = IntegrationsFile()
        file.slack = Fixture.account
        return file
    }

    private func gmailConnected() -> IntegrationsFile {
        Keychain.set("1234-test.apps.googleusercontent.com", for: Keychain.Account.googleClientID)
        Keychain.set("test-client-secret", for: Keychain.Account.googleClientSecret)
        Keychain.set("1//test-refresh", for: Keychain.Account.googleRefreshToken)
        var file = IntegrationsFile()
        file.gmailAddress = Fixture.address
        return file
    }

    /// Slack's answers for a refresh; `reactions` in turn when given (the last one repeats).
    private func slackAnswers(now: Date, reactions: String...) {
        server.slack("reactions.list", replies: reactions.isEmpty ? [Fixture.reactions(now: now)] : reactions)
        server.slack("search.messages", Fixture.mentions(now: now))
        Fixture.names(on: server)
    }

    /// One user action: the window's undo manager groups by event.
    private func step<T>(_ undo: UndoManager, _ body: () -> T) -> T {
        undo.beginUndoGrouping()
        defer { undo.endUndoGrouping() }
        return body()
    }

    func testConnectingSlackChecksTheTokenKeepsItInTheKeychainAndRefreshes() async throws {
        let now = Date()
        server.slack("auth.test", Fixture.authTest, headers: ["x-oauth-scopes": "reactions:read,search:read,users:read,chat:write"])
        slackAnswers(now: now)
        let (integrations, _) = try make()

        for bad in ["xoxb-1234-bot", "hello", ""] {
            do {
                try await integrations.connectSlack(token: bad)
                XCTFail("\(bad) isn't a user token")
            } catch {
                XCTAssertFalse(error.localizedDescription.isEmpty)
            }
        }
        XCTAssertTrue(server.requests.isEmpty, "bad tokens never reach Slack")

        try await integrations.connectSlack(token: "  \(Fixture.token)\n")
        await integrations.waitForRefresh()
        XCTAssertTrue(integrations.isSlackConnected)
        XCTAssertEqual(integrations.slackAccount?.userID, Fixture.me)
        XCTAssertEqual(integrations.slackAccount?.teamName, "Acme Test")
        XCTAssertEqual(Keychain.string(Keychain.Account.slackUserToken), Fixture.token)
        XCTAssertFalse(integrations.suggestions.isEmpty, "connecting checks for messages")
        XCTAssertNil(integrations.slackProblem)
        // The app was made without every permission: that's said, and a successful check doesn't hide it.
        XCTAssertEqual(integrations.slackAccount?.missingScopes,
                       ["users.profile:write", "dnd:write", "channels:read", "groups:read", "im:read", "mpim:read"])
        XCTAssertTrue(integrations.slackScopeWarning?.contains("users.profile:write, dnd:write") == true)

        integrations.disconnectSlack()
        XCTAssertFalse(integrations.isSlackConnected)
        XCTAssertNil(Keychain.string(Keychain.Account.slackUserToken))
        XCTAssertTrue(integrations.suggestions.isEmpty, "a manual disconnect clears Slack's cards")
        XCTAssertNil(integrations.slackProblem)
        XCTAssertNil(integrations.slackScopeWarning)
    }

    func testAnAppWithEveryPermissionConnectsWithoutAWarning() async throws {
        server.slack("auth.test", Fixture.authTest, headers: ["x-oauth-scopes": Fixture.allScopes])
        slackAnswers(now: Date())
        let (integrations, _) = try make()
        try await integrations.connectSlack(token: Fixture.token)
        await integrations.waitForRefresh()
        XCTAssertTrue(integrations.isSlackConnected)
        XCTAssertNil(integrations.slackAccount?.missingScopes)
        XCTAssertNil(integrations.slackScopeWarning)
        XCTAssertNotNil(integrations.lastRefresh)
    }

    func testSlackRefreshSuggestsSavedMessagesAndMentionsOnce() async throws {
        let now = Date()
        slackAnswers(now: now)
        let (integrations, store) = try make(slackConnected())

        await integrations.refreshNow(now: now)
        XCTAssertNil(integrations.slackProblem)
        XCTAssertEqual(integrations.lastRefresh, now)
        let byID = Dictionary(uniqueKeysWithValues: integrations.suggestions.map { ($0.id, $0) })
        let budget = try XCTUnwrap(byID["slack:C0LEAD/\(Fixture.ts(now.addingTimeInterval(-600)))"])
        let deck = try XCTUnwrap(byID["slack:C0LEAD/\(Fixture.ts(now.addingTimeInterval(-3600)))"])
        let hiring = try XCTUnwrap(byID["slack:D0DM/\(Fixture.ts(now.addingTimeInterval(-1800)))"])
        let file = try XCTUnwrap(byID["slack:C0GEN/\(Fixture.ts(now.addingTimeInterval(-5400)))"])
        XCTAssertEqual(integrations.suggestions.count, 4)
        XCTAssertEqual(integrations.suggestions.map(\.id), [budget, hiring, deck, file].map(\.id), "newest first")

        XCTAssertEqual(deck.trigger, .reaction)
        XCTAssertEqual(deck.source.label, "#leadership · Priya Shah")
        XCTAssertEqual(deck.from, "Priya Shah")
        XCTAssertEqual(deck.snippet, "Can you send the Q3 deck to @Sam Lee by Friday? & thanks")
        XCTAssertEqual(deck.source.url?.absoluteString, "https://acme-test.slack.com/archives/C0LEAD/p1000")
        XCTAssertEqual(deck.draft?.title, "Slack: Can you send the Q3 deck to @Sam Lee by Friday? & thanks")
        XCTAssertEqual(budget.trigger, .mention)
        XCTAssertEqual(hiring.source.label, "Direct message · Sam Lee")
        XCTAssertEqual(file.snippet, "Shared a file: Offsite plan")
        XCTAssertEqual(file.source.url?.absoluteString,
                       "https://acme-test.slack.com/archives/C0GEN/p\(Fixture.ts(now.addingTimeInterval(-5400)).replacingOccurrences(of: ".", with: ""))",
                       "built from the workspace address when Slack sent no permalink")

        // Every request carried the token in its header only.
        XCTAssertTrue(server.requests.allSatisfy { $0.value(forHTTPHeaderField: "Authorization") == "Bearer \(Fixture.token)" })
        XCTAssertFalse(server.requests.contains { $0.url?.absoluteString.contains(Fixture.token) == true })

        // A second check finds the same messages: nothing new, and names aren't looked up again.
        let lookups = server.calls("users.info").count
        await integrations.refreshNow(now: now)
        XCTAssertEqual(integrations.suggestions.count, 4)
        XCTAssertEqual(server.calls("users.info").count, lookups)

        // Dismissed and added ones stay gone.
        integrations.dismiss(hiring)
        let task = try XCTUnwrap(integrations.add(deck, toast: false))
        XCTAssertEqual(task.source, deck.source)
        XCTAssertEqual(task.title, deck.draft?.title)
        XCTAssertEqual(store.tasks.count, 1)
        await integrations.refreshNow(now: now)
        XCTAssertEqual(Set(integrations.suggestions.map(\.id)), [budget.id, file.id])

        // A message that's already on a task (made some other way) isn't suggested either.
        var manual = TaskItem(title: "Approve the budget")
        manual.source = budget.source
        store.addTask(manual)
        XCTAssertEqual(integrations.suggestions.map(\.id), [file.id], "the card goes as soon as the task exists")
        await integrations.refreshNow(now: now)
        XCTAssertEqual(integrations.suggestions.map(\.id), [file.id])
    }

    func testMentionsCanBeTurnedOffAndProblemsBecomeAStatusLine() async throws {
        let now = Date()
        slackAnswers(now: now, reactions: Fixture.reactions(now: now), #"{"ok":false,"error":"ratelimited"}"#)
        var settings = IntegrationSettings()
        settings.mentions = false
        let (integrations, _) = try make(slackConnected(), settings: settings)

        await integrations.refreshNow(now: now)
        XCTAssertEqual(integrations.suggestions.map(\.trigger), [.reaction, .reaction])
        XCTAssertTrue(server.calls("search.messages").isEmpty, "mentions are off")
        XCTAssertEqual(integrations.lastRefresh, now)

        // Slack asks Docket to slow down: a status line, and "Updated" stays at the last real check.
        let later = now.addingTimeInterval(60)
        await integrations.refreshNow(now: later)
        XCTAssertEqual(integrations.slackProblem, IntegrationError.rateLimited(.slack, retryAfter: 60).errorDescription)
        XCTAssertEqual(integrations.lastRefresh, now)
        XCTAssertEqual(integrations.suggestions.count, 2, "what was found stays")

        // Paused meanwhile: the next check doesn't call Slack at all.
        let calls = server.requests.count
        await integrations.refreshNow(now: later.addingTimeInterval(10))
        XCTAssertEqual(server.requests.count, calls)
    }

    func testAIKeepsOnlyMentionsThatNeedYouAndASaveBringsOneBack() async throws {
        let now = Date()
        slackAnswers(now: now, reactions: Fixture.reactions(now: now), Fixture.reactions(now: now, extra: Fixture.savedHiringDM(now: now)))
        let log = TriageLog()
        let triage = SuggestionTriage(isAvailable: { true }, run: { messages, _, _ in
            log.batches.append(messages)
            var drafts: [String: TaskDraft] = [:]
            for m in messages where m.text.contains("budget") {
                var d = TaskDraft(title: "Approve the Q4 budget")
                d.estimateMinutes = 15
                d.reason = "Priya asked for it today"
                drafts[m.source.externalID] = d
            }
            return drafts
        })
        let (integrations, _) = try make(slackConnected(), triage: triage)

        await integrations.refreshNow(now: now)
        XCTAssertEqual(log.batches.count, 1)
        XCTAssertEqual(log.batches[0].count, 4, "saved messages and mentions go to AI together")
        XCTAssertTrue(log.batches[0].contains { $0.text == "@Maya Chen can you approve the Q4 budget today?" }, "AI reads plain text")
        let hiringID = "slack:D0DM/\(Fixture.ts(now.addingTimeInterval(-1800)))"
        XCTAssertFalse(integrations.suggestions.contains { $0.id == hiringID }, "AI saw nothing to do")
        let budget = try XCTUnwrap(integrations.suggestions.first { $0.trigger == .mention })
        XCTAssertEqual(budget.draft?.title, "Approve the Q4 budget")
        XCTAssertEqual(budget.draft?.estimateMinutes, 15)
        XCTAssertEqual(budget.draft?.source, budget.source)
        XCTAssertEqual(integrations.suggestions.filter { $0.trigger == .reaction }.count, 2, "saved ones stay, with a plain draft")
        XCTAssertNil(integrations.aiProblem)

        // Maya saves the DM with 📌 afterwards: flagged on purpose, it shows up.
        await integrations.refreshNow(now: now.addingTimeInterval(60))
        let hiring = try XCTUnwrap(integrations.suggestions.first { $0.id == hiringID })
        XCTAssertEqual(hiring.trigger, .reaction)
        XCTAssertEqual(hiring.draft?.title, "Slack: @Maya Chen quick question about hiring")
    }

    func testAIFailureLeavesMentionsForNextTimeAndSaysSoOnce() async throws {
        let now = Date()
        slackAnswers(now: now)
        let triage = SuggestionTriage(isAvailable: { true }, run: { _, _, _ in throw AIError.rateLimited })
        let (integrations, _) = try make(slackConnected(), triage: triage)

        await integrations.refreshNow(now: now)
        XCTAssertEqual(integrations.suggestions.map(\.trigger), [.reaction, .reaction], "explicit saves still show, mentions wait")
        let problem = try XCTUnwrap(integrations.aiProblem)
        XCTAssertTrue(problem.contains(AIError.rateLimited.localizedDescription))
        XCTAssertNil(integrations.slackProblem, "Slack itself was fine")

        integrations.triage = .none
        await integrations.refreshNow(now: now)
        XCTAssertEqual(integrations.suggestions.count, 4, "the mentions were looked at again")
        XCTAssertNil(integrations.aiProblem)
    }

    func testGmailSuggestsStarredAndUnansweredMailOnePerConversation() async throws {
        let now = Date()
        server.google("/token", .init(body: Fixture.accessToken))
        server.gmail("messages", query: GmailClient.starredQuery, Fixture.list([("m1", "t1")]))
        // m3 is a later message in the starred conversation: one card per conversation.
        server.gmail("messages", query: GmailClient.needsReplyQuery, Fixture.list([("m2", "t2"), ("m3", "t1")]))
        server.gmail("messages/m1", Fixture.email("m1", thread: "t1", from: #""Lee, Sam" <sam.lee@northwind.example>"#,
                                                  subject: "Re: Q3 numbers", snippet: "Can you send the final numbers before Friday&#39;s call?",
                                                  at: now.addingTimeInterval(-7200)))
        server.gmail("messages/m2", Fixture.email("m2", thread: "t2", from: "Priya Shah <priya@contoso.example>",
                                                  subject: "Intro: Contoso", snippet: "Are you free to meet the team next week?",
                                                  at: now.addingTimeInterval(-600)))
        let (integrations, store) = try make(gmailConnected())

        await integrations.refreshNow(now: now)
        XCTAssertNil(integrations.gmailProblem)
        XCTAssertEqual(integrations.suggestions.map(\.id), ["gmail:t2/m2", "gmail:t1/m1"])
        let starred = integrations.suggestions[1]
        XCTAssertEqual(starred.trigger, .starred)
        XCTAssertEqual(starred.from, "Lee, Sam")
        XCTAssertEqual(starred.subject, "Re: Q3 numbers")
        XCTAssertEqual(starred.snippet, "Can you send the final numbers before Friday's call?")
        XCTAssertEqual(starred.source.url?.absoluteString, "https://mail.google.com/mail/u/maya@acme.example/#all/t1")
        XCTAssertEqual(starred.source.label, "Lee, Sam · Re: Q3 numbers")
        XCTAssertEqual(starred.draft?.title, "Reply to Sam: Q3 numbers")
        XCTAssertEqual(integrations.suggestions[0].trigger, .needsReply)
        XCTAssertEqual(integrations.suggestions[0].draft?.title, "Reply to Priya: Intro: Contoso")
        XCTAssertTrue(server.requests(toPath: "/gmail/v1/users/me/messages/m3").isEmpty)
        XCTAssertTrue(server.requests(toPath: "/gmail/v1/users/me/messages").allSatisfy {
            $0.value(forHTTPHeaderField: "Authorization") == "Bearer ya29.test-access"
        })
        XCTAssertEqual(FakeIntegrationServer.query(server.requests(toPath: "/gmail/v1/users/me/messages")[0])["maxResults"], "25")

        // While its task is open, unread mail in that conversation waits; once it's done, a later message counts.
        server.gmail("messages/m3", Fixture.email("m3", thread: "t1", from: #""Lee, Sam" <sam.lee@northwind.example>"#,
                                                  subject: "Re: Q3 numbers", snippet: "One more thing: the appendix",
                                                  at: now.addingTimeInterval(-300)))
        let task = try XCTUnwrap(integrations.add(starred, toast: false))
        XCTAssertEqual(task.source?.externalID, "gmail:t1/m1")
        await integrations.refreshNow(now: now)
        XCTAssertEqual(integrations.suggestions.map(\.id), ["gmail:t2/m2"])
        XCTAssertTrue(server.requests(toPath: "/gmail/v1/users/me/messages/m3").isEmpty)

        store.setCompleted(task.id, true)
        await integrations.refreshNow(now: now)
        XCTAssertEqual(integrations.suggestions.map(\.id), ["gmail:t1/m3", "gmail:t2/m2"])
        XCTAssertEqual(integrations.suggestions[0].trigger, .needsReply)
        XCTAssertNil(integrations.gmailProblem)
    }

    func testAnUnreadableKeychainNeverDisconnects() async throws {
        // Connected, but the keychain gives nothing back right now (locked, or access refused at a prompt).
        var file = IntegrationsFile()
        file.slack = Fixture.account
        file.gmailAddress = Fixture.address
        let (integrations, _) = try make(file)

        await integrations.refreshNow(now: Date())
        XCTAssertTrue(integrations.isSlackConnected)
        XCTAssertTrue(integrations.isGmailConnected)
        XCTAssertTrue(integrations.slackProblem?.contains("keychain") == true)
        XCTAssertTrue(integrations.gmailProblem?.contains("OAuth client") == true)
        XCTAssertTrue(server.requests.isEmpty)
        XCTAssertNil(integrations.lastRefresh)

        // Once it can be read again, everything carries on.
        Keychain.set(Fixture.token, for: Keychain.Account.slackUserToken)
        slackAnswers(now: Date())
        await integrations.refreshNow(now: Date())
        XCTAssertNil(integrations.slackProblem)
        XCTAssertEqual(integrations.suggestions.count, 4)
    }

    func testRevokedGmailSignInDisconnectsAndKeepsTheCards() async throws {
        let now = Date()
        server.google("/token", .init(status: 400, body: #"{"error":"invalid_grant"}"#))
        var file = gmailConnected()
        file.suggestions = [Suggestion(source: TaskSource(kind: .gmail, externalID: "gmail:t1/m1", url: nil, label: "Sam Lee · Pricing"),
                                       from: "Sam Lee", subject: "Pricing", snippet: "", receivedAt: now, draft: nil, trigger: .starred)]
        let (integrations, _) = try make(file)

        await integrations.refreshNow(now: now)
        XCTAssertFalse(integrations.isGmailConnected)
        XCTAssertNil(Keychain.string(Keychain.Account.googleRefreshToken))
        XCTAssertEqual(integrations.gmailProblem, IntegrationError.signedOut(.gmail).errorDescription)
        XCTAssertEqual(integrations.suggestions.count, 1, "signed out by Google: what was found stays")
    }

    func testUndoBringsCardsBackAndRedoTakesThemAway() async throws {
        let now = Date()
        slackAnswers(now: now)
        let app = AppState()
        let (integrations, store) = try make(slackConnected(), app: app)
        await integrations.refreshNow(now: now)
        XCTAssertEqual(integrations.suggestions.count, 4)
        let undo = UndoManager()
        undo.groupsByEvent = false
        store.undoManager = undo

        // Add task: one step takes the task away and brings the card back.
        let first = integrations.suggestions[0]
        integrations.add(first, toast: false)
        XCTAssertEqual(store.tasks.count, 1)
        XCTAssertNil(integrations.add(first, toast: false), "a second click as the card goes adds nothing")
        XCTAssertEqual(store.tasks.count, 1)
        XCTAssertFalse(integrations.suggestions.contains(first))
        XCTAssertEqual(undo.undoActionName, "Add Task")
        undo.undo()
        XCTAssertTrue(store.tasks.isEmpty)
        XCTAssertEqual(integrations.suggestions.first, first)
        undo.redo()
        XCTAssertEqual(store.tasks.count, 1)
        XCTAssertFalse(integrations.suggestions.contains(first))
        undo.undo()

        // Dismiss is undoable too.
        integrations.dismiss(first)
        XCTAssertEqual(undo.undoActionName, "Dismiss Suggestion")
        XCTAssertEqual(integrations.suggestions.count, 3)
        undo.undo()
        XCTAssertEqual(integrations.suggestions.count, 4)
        await integrations.refreshNow(now: now)
        XCTAssertEqual(integrations.suggestions.count, 4, "an undone dismiss isn't remembered as handled")

        // Add all: one step.
        integrations.addAll()
        XCTAssertEqual(store.tasks.count, 4)
        XCTAssertTrue(integrations.suggestions.isEmpty)
        XCTAssertEqual(Set(store.tasks.compactMap { $0.source?.externalID }).count, 4)
        undo.undo()
        XCTAssertTrue(store.tasks.isEmpty)
        XCTAssertEqual(integrations.suggestions.count, 4)

        // Edit… hands the draft to the planner, and the task it makes takes the card in the same step.
        let second = integrations.suggestions[1]
        integrations.edit(second)
        let draft = try XCTUnwrap(app.aiPlanner?.drafts.first)
        XCTAssertEqual(draft.source, second.source)
        var edited = draft
        edited.title = "Hire a platform lead"
        // The planner's own way of adding (AIPlanSheet → Store.addPlannedTasks), so the card's return
        // is checked on the path the app really takes.
        step(undo) { _ = store.addPlannedTasks([edited.makeTask(lists: store.lists)]) }
        XCTAssertFalse(integrations.suggestions.contains(second))
        undo.undo()
        XCTAssertTrue(store.tasks.isEmpty)
        XCTAssertTrue(integrations.suggestions.contains(second), "⌘Z after Edit… brings the card back")
        undo.redo()
        XCTAssertEqual(store.tasks.map(\.title), ["Hire a platform lead"])
        XCTAssertFalse(integrations.suggestions.contains(second))
    }

    func testEverythingIsSavedButNeverATokenAndComesBackOnTheNextLaunch() async throws {
        let now = Date()
        slackAnswers(now: now)
        let (integrations, store) = try make(slackConnected())
        await integrations.refreshNow(now: now)
        integrations.dismiss(integrations.suggestions[0])
        let kept = integrations.suggestions
        XCTAssertEqual(kept.count, 3)
        integrations.flushSaves()

        let data = try Data(contentsOf: dir.appendingPathComponent("integrations.json"))
        let text = String(decoding: data, as: UTF8.self)
        XCTAssertFalse(text.contains("xoxp-"), "tokens live in the keychain only")
        XCTAssertFalse(text.contains("1//"))

        // Next launch.
        let again = Integrations(transport: server.transport, triage: .none, sleep: { _ in })
        again.settings = { IntegrationSettings() }
        again.attach(store: store, app: nil, directory: dir)
        XCTAssertEqual(again.suggestions.map(\.id), kept.map(\.id))
        for (loaded, original) in zip(again.suggestions, kept) {
            XCTAssertEqual(loaded.source, original.source)
            XCTAssertEqual(loaded.from, original.from)
            XCTAssertEqual(loaded.snippet, original.snippet)
            XCTAssertEqual(loaded.trigger, original.trigger)
            XCTAssertEqual(loaded.draft?.title, original.draft?.title)
            XCTAssertEqual(loaded.draft?.source, original.source)
            XCTAssertEqual(loaded.receivedAt.timeIntervalSince1970, original.receivedAt.timeIntervalSince1970, accuracy: 1)
        }
        XCTAssertEqual(again.slackAccount, Fixture.account)
        XCTAssertTrue(again.isSlackConnected)
        XCTAssertFalse(again.isGmailConnected)
        XCTAssertEqual(again.lastRefresh?.timeIntervalSince1970 ?? 0, now.timeIntervalSince1970, accuracy: 1)
        // The dismissed one is remembered as handled.
        await again.refreshNow(now: now)
        XCTAssertEqual(again.suggestions.map(\.id), kept.map(\.id))
    }

    func testFocusSessionSetsHeadsDownAndPutsTheOldStatusBack() async throws {
        let until = Date().addingTimeInterval(25 * 60)
        let ours = (SlackStatus.focusText, SlackStatus.focusEmoji, Int(until.timeIntervalSince1970.rounded(.up)))
        server.slack("users.info", where: ("user", Fixture.me),
                     Fixture.user(Fixture.me, "maya", "Maya Chen", status: ("Working from home", ":house:", 0)),
                     Fixture.user(Fixture.me, "maya", "Maya Chen", status: ours))
        server.slack("users.profile.set", #"{"ok":true}"#)
        server.slack("dnd.setSnooze", #"{"ok":true,"snooze_enabled":true,"snooze_endtime":\#(Int(until.timeIntervalSince1970)),"snooze_remaining":1500}"#)
        server.slack("dnd.endSnooze", #"{"ok":true,"dnd_enabled":true,"snooze_enabled":false}"#)
        let (integrations, _) = try make(slackConnected())

        integrations.focusStarted(until: until, taskTitle: "Draft the confidential board memo")
        await integrations.waitForFocusUpdates()
        let set = try XCTUnwrap(server.calls("users.profile.set").first)
        let profile = try XCTUnwrap(JSONSerialization.jsonObject(with: Data((FakeIntegrationServer.form(set)["profile"] ?? "").utf8)) as? [String: Any])
        XCTAssertEqual(profile["status_text"] as? String, "Heads down")
        XCTAssertEqual(profile["status_emoji"] as? String, ":dart:")
        XCTAssertEqual(profile["status_expiration"] as? Int, ours.2)
        XCTAssertEqual(FakeIntegrationServer.form(try XCTUnwrap(server.calls("dnd.setSnooze").first))["num_minutes"], "25")
        XCTAssertFalse(server.requests.contains { String(decoding: $0.httpBody ?? Data(), as: UTF8.self).contains("board") },
                       "the task title never goes to Slack")

        integrations.focusEnded()
        await integrations.waitForFocusUpdates()
        let restore = try XCTUnwrap(server.calls("users.profile.set").last)
        let restored = try XCTUnwrap(JSONSerialization.jsonObject(with: Data((FakeIntegrationServer.form(restore)["profile"] ?? "").utf8)) as? [String: Any])
        XCTAssertEqual(restored["status_text"] as? String, "Working from home")
        XCTAssertEqual(restored["status_emoji"] as? String, ":house:")
        XCTAssertEqual(server.calls("users.profile.set").count, 2)
        XCTAssertEqual(server.calls("dnd.endSnooze").count, 1)

        // Nothing left to undo: ending again changes nothing.
        integrations.focusEnded()
        await integrations.waitForFocusUpdates()
        XCTAssertEqual(server.calls("users.profile.set").count, 2)
    }

    func testFocusEndLeavesAStatusTheUserChangedAlone() async throws {
        let until = Date().addingTimeInterval(25 * 60)
        server.slack("users.info", where: ("user", Fixture.me),
                     Fixture.user(Fixture.me, "maya", "Maya Chen"),
                     Fixture.user(Fixture.me, "maya", "Maya Chen", status: ("In a meeting", ":calendar:", 0)))
        server.slack("users.profile.set", #"{"ok":true}"#)
        server.slack("dnd.setSnooze", #"{"ok":true,"snooze_enabled":true,"snooze_endtime":\#(Int(until.timeIntervalSince1970))}"#)
        server.slack("dnd.endSnooze", #"{"ok":true}"#)
        var settings = IntegrationSettings()
        let (integrations, _) = try make(slackConnected(), settings: settings)

        integrations.focusStarted(until: until, taskTitle: "Focus")
        integrations.focusEnded()
        await integrations.waitForFocusUpdates()
        XCTAssertEqual(server.calls("users.profile.set").count, 1, "only Heads down was set; the user's own status stays")
        XCTAssertTrue(server.calls("dnd.endSnooze").isEmpty)

        // With the switch off, nothing goes to Slack at all.
        settings.focusStatus = false
        integrations.settings = { settings }
        let before = server.requests.count
        integrations.focusStarted(until: until, taskTitle: "Focus")
        await integrations.waitForFocusUpdates()
        XCTAssertEqual(server.requests.count, before)
    }

    func testSharingPostsThePlanAsYouToTheChannelYouPick() async throws {
        let now = Date()
        server.slack("users.conversations", #"{"ok":true,"channels":[{"id":"C0LEAD","name":"leadership"}],"response_metadata":{"next_cursor":""}}"#)
        server.slack("chat.postMessage", #"{"ok":true,"channel":"C0LEAD","ts":"1791222120.000200"}"#)
        let (integrations, store) = try make(slackConnected())
        var task = TaskItem(title: "Board prep")
        task.scheduledDate = Calendar.current.startOfDay(for: now)
        task.estimateMinutes = 45
        let added = store.addTask(task)

        let channels = try await integrations.slackChannels()
        XCTAssertEqual(channels.map(\.name), ["leadership"])
        _ = try await integrations.slackChannels()
        XCTAssertEqual(server.calls("users.conversations").count, 1, "the channel list is cached")

        try await integrations.share(taskIDs: [added.id], to: channels[0], now: now)
        let form = FakeIntegrationServer.form(try XCTUnwrap(server.calls("chat.postMessage").first))
        XCTAssertEqual(form["channel"], "C0LEAD")
        XCTAssertEqual(form["text"], SlackShare.message(for: [added], now: now))
        XCTAssertEqual(form["unfurl_links"], "false")
    }
}
