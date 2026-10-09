import CryptoKit
import Foundation

/// Google sign-in for a desktop app (RFC 8252): the system browser, a loopback redirect to
/// 127.0.0.1 on a random port, PKCE (S256) and a `state` check. Docket asks for gmail.modify: it reads
/// mail, stars what the user stars, and sends or saves a draft only when they click Send or Save draft. It
/// never deletes or archives anything.
enum GoogleOAuth {
    static let authEndpoint = URL(string: "https://accounts.google.com/o/oauth2/v2/auth")!
    static let tokenEndpoint = URL(string: "https://oauth2.googleapis.com/token")!
    static let revokeEndpoint = URL(string: "https://oauth2.googleapis.com/revoke")!
    /// Reading only. Sign-ins from before stars have it, with `composeScope`; gmail.modify includes it.
    static let gmailScope = "https://www.googleapis.com/auth/gmail.readonly"
    /// One Gmail scope, gmail.modify, for reading, stars, drafts and sending (see `allows`). Sign-ins from
    /// before stars have gmail.readonly and gmail.compose instead: replying still works with those, and
    /// starring asks them to reconnect (see `GoogleSession.canModify`).
    static let scopes = ["openid", "email", modifyScope]

    /// The OAuth client ("Desktop app") the user created in Google Cloud.
    struct Client: Hashable, Sendable {
        var id: String
        var secret: String
    }

    struct Tokens: Sendable {
        var accessToken: String
        /// A minute early, so a token is never used right as it runs out.
        var expiresAt: Date
        var refreshToken: String?
        /// What the sign-in allows: the scopes Google granted, with those gmail.modify includes
        /// (`withIncludedScopes`), so a check for reading or for composing finds them.
        var scopes: Set<String>
    }

    // MARK: PKCE

    enum PKCE {
        /// 32 random bytes as base64url: 43 characters, as RFC 7636 recommends.
        static func makeVerifier() -> String { randomString(bytes: 32) }

        /// BASE64URL(SHA256(verifier)), the S256 method.
        static func challenge(for verifier: String) -> String {
            base64URL(Data(SHA256.hash(data: Data(verifier.utf8))))
        }

        /// Random, URL-safe text (for `state` and the verifier).
        static func randomString(bytes count: Int) -> String {
            var generator = SystemRandomNumberGenerator()
            return base64URL(Data((0..<count).map { _ in UInt8.random(in: .min ... .max, using: &generator) }))
        }

        static func base64URL(_ data: Data) -> String {
            data.base64EncodedString()
                .replacingOccurrences(of: "+", with: "-")
                .replacingOccurrences(of: "/", with: "_")
                .replacingOccurrences(of: "=", with: "")
        }
    }

    // MARK: Steps

    static func authorizationURL(client: Client, redirectURI: String, state: String, challenge: String) -> URL? {
        var components = URLComponents(url: authEndpoint, resolvingAgainstBaseURL: false)
        components?.percentEncodedQuery = IntegrationHTTP.encode([
            ("client_id", client.id),
            ("redirect_uri", redirectURI),
            ("response_type", "code"),
            ("scope", scopes.joined(separator: " ")),
            ("state", state),
            ("code_challenge", challenge),
            ("code_challenge_method", "S256"),
            ("access_type", "offline"),
            ("prompt", "consent"),
        ])
        return components?.url
    }

    /// Trades the code from the redirect for tokens.
    static func exchange(code: String, verifier: String, redirectURI: String, client: Client,
                         transport: @escaping IntegrationHTTP.Transport, now: Date = Date()) async throws -> Tokens {
        try await tokenRequest([
            ("code", code),
            ("client_id", client.id),
            ("client_secret", client.secret),
            ("redirect_uri", redirectURI),
            ("grant_type", "authorization_code"),
            ("code_verifier", verifier),
        ], refreshing: false, transport: transport, now: now)
    }

    /// A new access token from the refresh token (saved on this Mac).
    static func refresh(_ refreshToken: String, client: Client, transport: @escaping IntegrationHTTP.Transport, now: Date = Date()) async throws -> Tokens {
        var tokens = try await tokenRequest([
            ("client_id", client.id),
            ("client_secret", client.secret),
            ("refresh_token", refreshToken),
            ("grant_type", "refresh_token"),
        ], refreshing: true, transport: transport, now: now)
        if tokens.refreshToken == nil { tokens.refreshToken = refreshToken }
        return tokens
    }

    /// Tells Google to forget the sign-in. Best effort: Docket forgets it either way.
    static func revoke(_ token: String, transport: @escaping IntegrationHTTP.Transport) async {
        _ = try? await transport(IntegrationHTTP.formPost(revokeEndpoint, [("token", token)]))
    }

    private static func tokenRequest(_ form: [(String, String)], refreshing: Bool, transport: @escaping IntegrationHTTP.Transport,
                                     now: Date) async throws -> Tokens {
        let (data, response) = try await IntegrationHTTP.send(IntegrationHTTP.formPost(tokenEndpoint, form), via: transport, service: .google)
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        if (200..<300).contains(response.statusCode), let reply = try? decoder.decode(TokenReply.self, from: data),
           let access = reply.accessToken, !access.isEmpty {
            let lifetime = TimeInterval(max(120, reply.expiresIn ?? 3600))
            return Tokens(accessToken: access, expiresAt: now.addingTimeInterval(lifetime - 60),
                          refreshToken: reply.refreshToken.flatMap { $0.isEmpty ? nil : $0 },
                          scopes: withIncludedScopes(Set((reply.scope ?? "").split(separator: " ").map(String.init))))
        }
        let failure = try? decoder.decode(TokenFailure.self, from: data)
        switch failure?.error {
        case "invalid_grant":
            throw refreshing ? IntegrationError.signedOut(.gmail) : IntegrationError.api(.google, "Google didn't accept the sign-in. Try connecting again.")
        case "invalid_client", "unauthorized_client":
            throw IntegrationError.api(.google, "Google didn't accept the OAuth client ID or secret. Check them in Settings → Connections.")
        case "access_denied":
            throw IntegrationError.signInDenied
        default:
            if response.statusCode == 429 { throw IntegrationError.rateLimited(.google, retryAfter: 60) }
            throw IntegrationError.unexpected(.google, failure?.error ?? "HTTP \(response.statusCode)")
        }
    }

    private struct TokenReply: Decodable {
        let accessToken: String?
        let expiresIn: Int?
        let refreshToken: String?
        let scope: String?
    }

    private struct TokenFailure: Decodable {
        let error: String?
    }

    // MARK: The whole sign-in

    /// Starts the loopback server, opens Google's consent page in the default browser, waits (up to
    /// 5 minutes) for the redirect, and trades its code for tokens. Cancelling the task stops it.
    @MainActor
    static func signIn(client: Client, transport: @escaping IntegrationHTTP.Transport, open: (URL) -> Void,
                       timeout: TimeInterval = 300) async throws -> Tokens {
        let state = PKCE.randomString(bytes: 24)
        let verifier = PKCE.makeVerifier()
        let server = LoopbackServer(expectedState: state, timeout: timeout)
        defer { server.stop() }
        let port = try await server.start()
        let redirectURI = "http://127.0.0.1:\(port)"
        guard let url = authorizationURL(client: client, redirectURI: redirectURI, state: state, challenge: PKCE.challenge(for: verifier)) else {
            throw IntegrationError.unexpected(.google, "a bad sign-in address")
        }
        // Cancelled while the listener started: don't send the browser to a page nobody waits for.
        if Task.isCancelled { throw IntegrationError.signInCancelled }
        open(url)
        let redirect = try await withTaskCancellationHandler {
            try await server.waitForRedirect()
        } onCancel: {
            server.stop()
        }
        switch redirect {
        case .code(let code):
            return try await exchange(code: code, verifier: verifier, redirectURI: redirectURI, client: client, transport: transport)
        case .denied:
            throw IntegrationError.signInDenied
        }
    }
}

extension GoogleOAuth {
    /// Creating drafts and sending mail, for replying from the Email tab. Docket only sends or saves a draft
    /// when the user clicks Send or Save draft.
    static let composeScope = "https://www.googleapis.com/auth/gmail.compose"
    /// Reading, starring (labels), drafts and sending. Docket never deletes or archives anything with it.
    static let modifyScope = "https://www.googleapis.com/auth/gmail.modify"

    /// `granted`, plus what gmail.modify includes: it allows all that gmail.readonly and gmail.compose do
    /// (reading; drafts and sending), so a sign-in with it passes a check for either.
    static func withIncludedScopes(_ granted: Set<String>) -> Set<String> {
        granted.contains(modifyScope) ? granted.union([gmailScope, composeScope]) : granted
    }

    /// Whether a sign-in with `granted` can do what `scope` allows: it was granted, or gmail.modify was.
    static func allows(_ scope: String, granted: Set<String>) -> Bool {
        withIncludedScopes(granted).contains(scope)
    }
}

/// Hands out a valid Gmail access token, refreshing it from the refresh token when it runs out.
/// The access token lives only in memory.
actor GoogleSession {
    let client: GoogleOAuth.Client
    private let refreshToken: String
    private let transport: IntegrationHTTP.Transport
    private var current: (token: String, expires: Date)?
    private var pending: Task<GoogleOAuth.Tokens, Error>?
    /// What Google says the sign-in allows, from its latest token reply. Nil until one arrives: a session
    /// restored at launch learns it with its first access token.
    private(set) var grantedScopes: Set<String>?

    init(client: GoogleOAuth.Client, refreshToken: String, transport: @escaping IntegrationHTTP.Transport, tokens: GoogleOAuth.Tokens? = nil) {
        self.client = client
        self.refreshToken = refreshToken
        self.transport = transport
        current = tokens.map { ($0.accessToken, $0.expiresAt) }
        grantedScopes = tokens.flatMap { $0.scopes.isEmpty ? nil : $0.scopes }
    }

    func accessToken(now: Date = Date()) async throws -> String {
        if let current, current.expires > now { return current.token }
        return try await refreshAccessToken()
    }

    /// A fresh token now (after a 401). Concurrent callers share one refresh.
    func refreshAccessToken() async throws -> String {
        if let pending { return try await pending.value.accessToken }
        let task = Task { [client, refreshToken, transport] in
            try await GoogleOAuth.refresh(refreshToken, client: client, transport: transport)
        }
        pending = task
        defer { pending = nil }
        let tokens = try await task.value
        current = (tokens.accessToken, tokens.expiresAt)
        // A reply without a scope list says nothing new about them.
        if !tokens.scopes.isEmpty { grantedScopes = tokens.scopes }
        return tokens.accessToken
    }
}

extension GoogleSession {
    /// Whether the sign-in allows sending replies and saving drafts: gmail.compose, or gmail.modify, which
    /// includes it. False while the scopes aren't known (see `checkCanCompose`): sign-ins from before
    /// replies only ever had read access.
    var canCompose: Bool {
        grantedScopes.map { GoogleOAuth.allows(GoogleOAuth.composeScope, granted: $0) } ?? false
    }

    /// `canCompose`, asking Google first when the scopes aren't known yet (one token refresh).
    func checkCanCompose() async throws -> Bool {
        if grantedScopes == nil { _ = try await refreshAccessToken() }
        return canCompose
    }

    /// Whether the sign-in allows starring: gmail.modify, which covers reading, drafts and sending too.
    /// False while the scopes aren't known, and for sign-ins from before stars (gmail.readonly and
    /// gmail.compose): those reconnect to star.
    var canModify: Bool {
        grantedScopes.map { GoogleOAuth.allows(GoogleOAuth.modifyScope, granted: $0) } ?? false
    }
}
