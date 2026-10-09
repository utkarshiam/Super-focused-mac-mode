import Foundation

// "Check setup" on the Connections page (and from Messages' ⋯): real checks on demand, so the user can see
// that everything works. Slack: the token (auth.test) and its permissions. Gmail: the sign-in (a token
// refresh), the account (profile) and its permissions. AI: a tiny request to Gemini. Each result is ✓ or ✗
// with the fix in plain words and a button for it.

/// One result line.
struct SetupCheckItem: Identifiable, Equatable, Sendable {
    enum Service: String, Sendable { case slack = "Slack", gmail = "Gmail", ai = "AI" }

    /// What the Fix button does.
    enum Fix: Equatable, Sendable {
        /// The Slack steps on the Connections page (paste a token).
        case setUpSlack
        /// Create the Docket app in Slack again with every permission.
        case updateSlack
        /// The Gmail steps on the Connections page (the OAuth client).
        case setUpGmail
        /// Sign in to Google (again).
        case signInGmail
        /// Settings → AI.
        case aiSettings

        var title: String {
            switch self {
            case .setUpSlack: "Set up Slack"
            case .updateSlack: "Update the app"
            case .setUpGmail: "Set up Gmail"
            case .signInGmail: "Sign in again"
            case .aiSettings: "Open AI settings"
            }
        }
    }

    var id: String
    var service: Service
    /// What was checked and how it went, in a few words: "Slack token works".
    var title: String
    var ok: Bool
    /// The detail (who it's connected as), or for a ✗ the fix in plain English.
    var detail: String?
    var fix: Fix?
}

/// What each check found, turned into result lines. Pure, so it's easy to test.
enum SetupCheck {
    /// Slack: `identity` is auth.test's answer (the account, as "@maya in Acme", and the permissions Slack
    /// listed), or what went wrong; nil when there was nothing to ask with.
    static func slack(connected: Bool, tokenReadable: Bool,
                      identity: Result<(account: String, scopes: Set<String>?), IntegrationError>?) -> [SetupCheckItem] {
        guard connected else {
            return [SetupCheckItem(id: "slack.connected", service: .slack, title: "Slack isn't connected", ok: false,
                                   detail: "Follow the Slack steps on this page: create the app, then paste its token.", fix: .setUpSlack)]
        }
        guard tokenReadable, let identity else {
            return [SetupCheckItem(id: "slack.token", service: .slack, title: "Docket can't read the Slack token", ok: false,
                                   detail: "Paste the User OAuth Token again (it starts with xoxp-).", fix: .setUpSlack)]
        }
        switch identity {
        case .failure(let e):
            return [SetupCheckItem(id: "slack.token", service: .slack, title: problemTitle(e, service: "Slack"), ok: false,
                                   detail: slackFix(e).text, fix: slackFix(e).fix)]
        case .success(let found):
            var items = [SetupCheckItem(id: "slack.token", service: .slack, title: "Slack token works", ok: true,
                                        detail: "Connected as \(found.account).")]
            if let scopes = found.scopes {
                let missing = SlackManifest.userScopes.filter { !scopes.contains($0) }
                if missing.isEmpty {
                    items.append(SetupCheckItem(id: "slack.permissions", service: .slack, title: "Slack permissions complete", ok: true))
                } else {
                    let features = InboxItemText.slackPermissionBanner(missing: Set(missing))
                    items.append(SetupCheckItem(id: "slack.permissions", service: .slack, title: "Slack is missing \(Fmt.plural(missing.count, "permission"))",
                                                ok: false,
                                                detail: (features.map { $0 + " " } ?? "") + "Create the Docket app again (it opens with every permission ticked), paste its new token, then delete the old app.",
                                                fix: .updateSlack))
                }
            }
            return items
        }
    }

    /// Gmail: `signIn` is the token refresh, `profile` the address Gmail gave (or what went wrong), `scopes`
    /// what Google says the sign-in allows (nil: it didn't say).
    static func gmail(hasClient: Bool, connected: Bool, tokenReadable: Bool, signIn: IntegrationError?,
                      profile: Result<String, IntegrationError>?, scopes: Set<String>?) -> [SetupCheckItem] {
        guard hasClient else {
            return [SetupCheckItem(id: "gmail.client", service: .gmail, title: "No Google OAuth client yet", ok: false,
                                   detail: "Follow the Gmail steps on this page to create one (about 5 minutes), then paste its client ID and secret.",
                                   fix: .setUpGmail)]
        }
        guard connected else {
            return [SetupCheckItem(id: "gmail.client", service: .gmail, title: "Google OAuth client saved", ok: true),
                    SetupCheckItem(id: "gmail.signIn", service: .gmail, title: "Gmail isn't connected", ok: false,
                                   detail: "Sign in with Google. If Google says “Access blocked”, add your address under Test users first.",
                                   fix: .signInGmail)]
        }
        guard tokenReadable else {
            return [SetupCheckItem(id: "gmail.signIn", service: .gmail, title: "Docket can't read the Gmail sign-in", ok: false,
                                   detail: "Sign in with Google again.", fix: .signInGmail)]
        }
        if let signIn {
            return [SetupCheckItem(id: "gmail.signIn", service: .gmail, title: problemTitle(signIn, service: "Google"), ok: false,
                                   detail: gmailFix(signIn).text, fix: gmailFix(signIn).fix)]
        }
        var items = [SetupCheckItem(id: "gmail.signIn", service: .gmail, title: "Google sign-in works", ok: true)]
        switch profile {
        case .failure(let e)?:
            items.append(SetupCheckItem(id: "gmail.profile", service: .gmail, title: problemTitle(e, service: "Gmail"), ok: false,
                                        detail: gmailFix(e).text, fix: gmailFix(e).fix))
            return items
        case .success(let address)?:
            items.append(SetupCheckItem(id: "gmail.profile", service: .gmail, title: "Gmail reads your mail", ok: true,
                                        detail: "Signed in as \(address)."))
        case nil:
            break
        }
        if let scopes {
            if GoogleOAuth.allows(GoogleOAuth.modifyScope, granted: scopes) {
                items.append(SetupCheckItem(id: "gmail.permissions", service: .gmail, title: "Gmail permissions complete", ok: true,
                                            detail: "Docket can star emails, send your replies and save drafts."))
            } else {
                items.append(SetupCheckItem(id: "gmail.permissions", service: .gmail, title: "Gmail can't star or reply yet", ok: false,
                                            detail: "Sign in again and tick every box Google shows.", fix: .signInGmail))
            }
        }
        return items
    }

    /// AI: on or off, a key or none, and how the test request went.
    static func ai(enabled: Bool, hasKey: Bool, test: Result<String, Error>?) -> SetupCheckItem {
        guard enabled else {
            return SetupCheckItem(id: "ai", service: .ai, title: "AI is off", ok: false,
                                  detail: "Turn on Use AI in Settings → AI for suggested tasks, summaries and drafted replies.", fix: .aiSettings)
        }
        guard hasKey else {
            return SetupCheckItem(id: "ai", service: .ai, title: "No Gemini API key", ok: false,
                                  detail: "Paste a Gemini API key in Settings → AI (free from Google AI Studio).", fix: .aiSettings)
        }
        switch test {
        case .success(let line)?:
            return SetupCheckItem(id: "ai", service: .ai, title: "AI works", ok: true, detail: line)
        case .failure(let error)?:
            let ai = error as? AIError
            let text = (error as? LocalizedError)?.errorDescription ?? "Gemini didn't answer. Try again."
            return SetupCheckItem(id: "ai", service: .ai, title: ai.map(aiTitle) ?? "AI didn't answer", ok: false, detail: text,
                                  fix: ai?.needsSettings == true ? .aiSettings : nil)
        case nil:
            return SetupCheckItem(id: "ai", service: .ai, title: "AI wasn't checked", ok: false, detail: "Try again.")
        }
    }

    // MARK: Words

    private static func problemTitle(_ e: IntegrationError, service: String) -> String {
        switch e {
        case .signedOut: "\(service) signed Docket out"
        case .offline: "Couldn't reach \(service)"
        case .rateLimited: "\(service) asked Docket to slow down"
        case .missingPermission: "\(service) is missing a permission"
        default: "\(service) didn't answer as expected"
        }
    }

    private static func slackFix(_ e: IntegrationError) -> (text: String, fix: SetupCheckItem.Fix?) {
        switch e {
        case .signedOut, .notConnected:
            ("Slack no longer accepts the token. Paste a new User OAuth Token (it starts with xoxp-).", .setUpSlack)
        case .missingPermission:
            ("Create the Docket app again with every permission, then paste its new token.", .updateSlack)
        case .offline(_, let detail):
            (detail + " Then check again.", nil)
        case .rateLimited:
            ("Wait a minute, then check again.", nil)
        default:
            ((e.errorDescription ?? "Something went wrong.") + " Check again in a minute.", nil)
        }
    }

    private static func gmailFix(_ e: IntegrationError) -> (text: String, fix: SetupCheckItem.Fix?) {
        switch e {
        case .signedOut, .notConnected:
            ("Sign in with Google again. Apps in testing are signed out after 7 days.", .signInGmail)
        case .missingPermission:
            ("Sign in again and tick every box Google shows.", .signInGmail)
        case .offline(_, let detail):
            (detail + " Then check again.", nil)
        case .rateLimited:
            ("Wait a minute, then check again.", nil)
        case .api(_, let message) where message.lowercased().contains("client"):
            (message + " Check the client ID and secret in the Gmail steps.", .setUpGmail)
        default:
            ((e.errorDescription ?? "Something went wrong.") + " Check again in a minute.", nil)
        }
    }

    private static func aiTitle(_ e: AIError) -> String {
        switch e {
        case .notConfigured: "No Gemini API key"
        case .badKey: "Gemini didn't accept the key"
        case .rateLimited: "Gemini is busy"
        case .network: "Couldn't reach Gemini"
        case .badResponse: "AI didn't answer as expected"
        }
    }
}

// MARK: - Running the checks

/// Checks AI. Tests swap in a fake.
struct AISetupCheck {
    var isEnabled: @MainActor () -> Bool
    var hasKey: @MainActor () -> Bool
    var test: @MainActor () async throws -> String

    static var gemini: AISetupCheck {
        AISetupCheck(isEnabled: { Prefs.aiEnabled }, hasKey: { Secrets.geminiAPIKey != nil },
                     test: { try await AIService.shared.testConnection() })
    }
}

extension Integrations {
    /// Runs every check, Slack, Gmail and AI at the same time, and returns their results in that order.
    /// What's learned along the way is kept (Slack's and Google's permissions), and a sign-out disconnects, as
    /// a check for new messages would. Tokens never leave this Mac except to Slack or Google.
    func checkSetup(ai: AISetupCheck = .gemini) async -> [SetupCheckItem] {
        async let slack = checkSlackSetup()
        async let gmail = checkGmailSetup()
        async let aiItem = checkAI(ai)
        let (s, g, a) = await (slack, gmail, aiItem)
        return s + g + [a]
    }

    private func checkSlackSetup() async -> [SetupCheckItem] {
        // Screenshot mode never calls out: its sample account, as connected.
        if DebugSnapshot.isActive {
            return SetupCheck.slack(connected: isSlackConnected, tokenReadable: true, identity: .success((slackAccountName, grantedSlackScopes)))
        }
        guard isSlackConnected else { return SetupCheck.slack(connected: false, tokenReadable: true, identity: nil) }
        guard let token = slackToken() else { return SetupCheck.slack(connected: true, tokenReadable: false, identity: nil) }
        do {
            let (account, scopes) = try await SlackClient(token: token, transport: transport, sleep: sleep).identity()
            // Kept, as a launch's check would: the banners and Connections follow.
            noteSlackIdentity(account, scopes: scopes)
            return SetupCheck.slack(connected: true, tokenReadable: true,
                                    identity: .success(("@\(account.userName) in \(account.teamName)", scopes)))
        } catch {
            return SetupCheck.slack(connected: true, tokenReadable: true, identity: .failure(inboxFailure(error, .slack)))
        }
    }

    private var slackAccountName: String {
        slackAccount.map { "@\($0.userName) in \($0.teamName)" } ?? "your workspace"
    }

    private func checkGmailSetup() async -> [SetupCheckItem] {
        let hasClient = googleClient != nil
        if DebugSnapshot.isActive || !isGmailConnected {
            return SetupCheck.gmail(hasClient: hasClient || DebugSnapshot.isActive, connected: isGmailConnected, tokenReadable: true,
                                    signIn: nil, profile: gmailAddress.map { .success($0) }, scopes: grantedGmailScopes)
        }
        guard let client = googleClient, let refreshToken = Keychain.string(Keychain.Account.googleRefreshToken) else {
            return SetupCheck.gmail(hasClient: hasClient, connected: true, tokenReadable: false, signIn: nil, profile: nil, scopes: nil)
        }
        // A session of its own: a fresh token, so Google says what the sign-in allows now.
        let session = GoogleSession(client: client, refreshToken: refreshToken, transport: transport)
        do {
            _ = try await session.refreshAccessToken()
        } catch {
            return SetupCheck.gmail(hasClient: true, connected: true, tokenReadable: true, signIn: inboxFailure(error, .gmail),
                                    profile: nil, scopes: nil)
        }
        let profile: Result<String, IntegrationError>
        do {
            profile = .success(try await GmailClient(session: session, transport: transport).profileEmail())
        } catch {
            profile = .failure(inboxFailure(error, .gmail))
        }
        let scopes = await session.grantedScopes
        if let scopes, isGmailConnected {
            // What Google says now, for the views (Reconnect to star and reply).
            let gmail = scopes.intersection([GoogleOAuth.gmailScope, GoogleOAuth.composeScope, GoogleOAuth.modifyScope])
            if !gmail.isEmpty, grantedGmailScopes != scopes {
                grantedGmailScopes = scopes
                save()
            }
        }
        return SetupCheck.gmail(hasClient: true, connected: true, tokenReadable: true, signIn: nil, profile: profile, scopes: scopes)
    }

    private func checkAI(_ ai: AISetupCheck) async -> SetupCheckItem {
        let enabled = ai.isEnabled(), hasKey = ai.hasKey()
        guard enabled, hasKey else { return SetupCheck.ai(enabled: enabled, hasKey: hasKey, test: nil) }
        do {
            return SetupCheck.ai(enabled: true, hasKey: true, test: .success(try await ai.test()))
        } catch {
            return SetupCheck.ai(enabled: true, hasKey: true, test: .failure(error))
        }
    }
}
