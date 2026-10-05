import XCTest
@testable import Docket

// The Slack and Email tabs without the network: stand-in Slack and Gmail clients answer, AI is a fake, and
// the keychain is in memory. Made-up workspace (Acme Test), people (Maya Chen, Priya Shah, Sam Lee, Lena
// Park) and companies (acme.example, northwind.example).

// MARK: - Stand-ins

/// Stands in for SlackClient: answers from what the test set up and records what it was asked.
private final class FakeSlackInbox: SlackInbox, @unchecked Sendable {
    struct Reply: Equatable {
        var channel: String
        var threadTS: String
        var text: String
    }

    struct ThreadCall: Equatable {
        var channel: String
        var threadTS: String
        var excluding: String
        var limit: Int
        var myUserID: String
    }

    struct State {
        var replies: [Reply] = []
        var threadCalls: [ThreadCall] = []
        /// The names each thread call was handed as already known.
        var threadNames: [[String: String]] = []
        var downloads: [URL] = []
        var lookups: [String] = []
        var replyError: Error?
        var threadAnswer: [ThreadMessage] = []
        var threadError: Error?
        var file = Data()
        var people: [String: String] = [:]
        /// How long each call takes, so a second one can arrive while the first is out.
        var delay: TimeInterval = 0
    }

    private let lock = NSLock()
    private var state = State()

    @discardableResult
    func with<T>(_ body: (inout State) throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body(&state)
    }

    var replies: [Reply] { with { $0.replies } }
    var threadCalls: [ThreadCall] { with { $0.threadCalls } }
    var threadNames: [[String: String]] { with { $0.threadNames } }
    var downloads: [URL] { with { $0.downloads } }
    var lookups: [String] { with { $0.lookups } }

    private func pause() async throws {
        let delay = with { $0.delay }
        if delay > 0 { try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000)) }
    }

    func reply(channel: String, threadTS: String, text: String) async throws {
        try await pause()
        try with { s in
            if let error = s.replyError { throw error }
            s.replies.append(Reply(channel: channel, threadTS: threadTS, text: text))
        }
    }

    func thread(channel: String, threadTS: String, excluding ts: String, limit: Int, myUserID: String,
                names: [String: String]) async throws -> [ThreadMessage] {
        try await pause()
        return try with { s in
            s.threadCalls.append(ThreadCall(channel: channel, threadTS: threadTS, excluding: ts, limit: limit, myUserID: myUserID))
            s.threadNames.append(names)
            if let error = s.threadError { throw error }
            return s.threadAnswer
        }
    }

    func download(_ url: URL) async throws -> Data {
        try await pause()
        return with { s in
            s.downloads.append(url)
            return s.file
        }
    }

    func user(_ id: String) async throws -> SlackUser {
        try with { s in
            s.lookups.append(id)
            guard let name = s.people[id] else { throw IntegrationError.api(.slack, "Slack said “user_not_found”.") }
            return SlackUser(id: id, name: name, status: SlackStatus())
        }
    }
}

/// Stands in for GmailClient.
private final class FakeMailInbox: MailInbox, @unchecked Sendable {
    struct ConversationCall: Equatable {
        var threadID: String
        var excluding: String?
        var limit: Int
        var myAddress: String
    }

    struct State {
        var full: GmailFullMessage
        var fetched: [String] = []
        var conversation: [ThreadMessage] = []
        var conversationCalls: [ConversationCall] = []
        var attachment = Data()
        var attachmentCalls: [[String]] = []
        var sent: [MailReply] = []
        var drafts: [MailReply] = []
        var sendError: Error?
        var delay: TimeInterval = 0
    }

    private let lock = NSLock()
    private var state: State

    init(full: GmailFullMessage) {
        state = State(full: full)
    }

    @discardableResult
    func with<T>(_ body: (inout State) throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body(&state)
    }

    var fetched: [String] { with { $0.fetched } }
    var conversationCalls: [ConversationCall] { with { $0.conversationCalls } }
    var attachmentCalls: [[String]] { with { $0.attachmentCalls } }
    var sent: [MailReply] { with { $0.sent } }
    var drafts: [MailReply] { with { $0.drafts } }

    private func pause() async throws {
        let delay = with { $0.delay }
        if delay > 0 { try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000)) }
    }

    func fullMessage(_ id: String) async throws -> GmailFullMessage {
        try await pause()
        return with { s in
            s.fetched.append(id)
            return s.full
        }
    }

    func conversation(threadID: String, excluding messageID: String?, limit: Int, myAddress: String) async throws -> [ThreadMessage] {
        with { s in
            s.conversationCalls.append(ConversationCall(threadID: threadID, excluding: messageID, limit: limit, myAddress: myAddress))
            return s.conversation
        }
    }

    func attachment(messageID: String, attachmentID: String) async throws -> Data {
        with { s in
            s.attachmentCalls.append([messageID, attachmentID])
            return s.attachment
        }
    }

    func sendReply(_ reply: MailReply) async throws {
        try await pause()
        try with { s in
            if let error = s.sendError { throw error }
            s.sent.append(reply)
        }
    }

    func saveDraft(_ reply: MailReply) async throws {
        try with { s in
            if let error = s.sendError { throw error }
            s.drafts.append(reply)
        }
    }
}

/// What the fake AI was asked.
@MainActor
private final class ReplyLog {
    var requests: [ReplyRequest] = []
}

// MARK: - Fixtures

private enum Sample {
    static let token = "xoxp-1111-2222-3333-test"
    static let account = SlackAccount(userID: "U0MAYA", userName: "maya", teamID: "T0ACME", teamName: "Acme Test",
                                      teamURL: URL(string: "https://acme-test.slack.com/"))
    static let address = "maya@acme.example"
    static let authTest = #"{"ok":true,"url":"https://acme-test.slack.com/","team":"Acme Test","user":"maya","team_id":"T0ACME","user_id":"U0MAYA"}"#
    static let offline: IntegrationHTTP.Transport = { _ in throw URLError(.notConnectedToInternet) }

    static let parentTS = "1791199000.000050"
    static let replyTS = "1791200000.000100"
    static let topTS = "1791203600.000200"
    /// A reply in a #leadership thread.
    static let threadReplyID = "slack:C0LEAD/\(replyTS)"
    /// A message on its own in #leadership.
    static let topID = "slack:C0LEAD/\(topTS)"
    static let emailID = "gmail:t1/m1"

    /// The permissions apps made before the inbox have.
    static let olderScopes = SlackManifest.userScopes.filter { !SlackManifest.contentScopes.contains($0) }

    static func slack(_ id: String, minutesAgo: Double = 10, threadTS: String? = nil, label: String = "#leadership · Priya Shah",
                      text: String = "Can you send the Q3 numbers?") -> Suggestion {
        var s = Suggestion(source: TaskSource(kind: .slack, externalID: id, url: nil, label: label),
                           from: label.components(separatedBy: " · ").last ?? "Priya Shah", subject: nil, snippet: text,
                           receivedAt: Date().addingTimeInterval(-minutesAgo * 60), draft: nil, trigger: .reaction)
        s.threadTS = threadTS
        return s
    }

    static func email(_ id: String = emailID, minutesAgo: Double = 20) -> Suggestion {
        Suggestion(source: TaskSource(kind: .gmail, externalID: id, url: nil, label: "Sam Lee · Contract redlines"),
                   from: "Sam Lee", subject: "Contract redlines", snippet: "Attached are the redlines.",
                   receivedAt: Date().addingTimeInterval(-minutesAgo * 60), draft: nil, trigger: .starred)
    }

    static let headers = MailReplyHeaders(messageID: "<CAF7redlines@mail.northwind.example>", references: "<CAF7msa@mail.acme.example>",
                                          subject: "Contract redlines", from: "Sam Lee <sam@northwind.example>",
                                          to: ["Maya Chen <maya@acme.example>"], cc: ["Lena Park <lena@acme.example>"])

    static let fullEmail = GmailFullMessage(
        id: "m1", threadID: "t1",
        content: MessageContent(text: "Attached are the redlines. Can you review sections 4 and 7 by Friday?",
                                html: "<p>Attached are the redlines. Can you review <b>sections 4 and 7</b> by Friday?</p>",
                                to: ["Maya Chen <maya@acme.example>"], cc: ["Lena Park <lena@acme.example>"],
                                attachments: [MessageAttachment(id: "m1/a1", name: "MSA redlines.pdf", mimeType: "application/pdf", size: 52_000,
                                                                remote: .gmail(messageID: "m1", attachmentID: "a1"))],
                                fetchedAt: Date(timeIntervalSince1970: 1_791_300_000)),
        replyHeaders: headers)

    static let deckURL = URL(string: "https://files.slack.com/files-pri/T0ACME-F0DECK/download/q3-deck.pdf")!
    static let deck = MessageAttachment(id: "F0DECK", name: "Q3 deck.pdf", mimeType: "application/pdf", size: 19,
                                        remote: .slack(url: deckURL, thumbnail: nil))
}

// MARK: - Tests

@MainActor
final class InboxTests: XCTestCase {
    var dir: URL!
    /// Integrations holds the store weakly (the app delegate owns it); the test owns it here.
    private var stores: [Store] = []

    override func setUp() async throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("docket-inbox-\(UUID().uuidString)")
        Keychain.useInMemoryStore()
    }

    override func tearDown() async throws {
        stores = []
        Keychain.useInMemoryStore()
        try? FileManager.default.removeItem(at: dir)
    }

    /// Integrations reading `file` from the test folder, with stand-in clients and no AI unless a test sets one.
    private func make(_ file: IntegrationsFile = IntegrationsFile(), slack: FakeSlackInbox? = nil, gmail: FakeMailInbox? = nil,
                      app: AppState? = nil, transport: @escaping IntegrationHTTP.Transport = Sample.offline) throws -> (Integrations, Store) {
        let store = Store(persistence: Persistence(directory: dir), seedIfEmpty: false)
        stores.append(store)
        try file.encoded().write(to: dir.appendingPathComponent("integrations.json"))
        let integrations = Integrations(transport: transport, triage: .none, sleep: { _ in })
        integrations.settings = { IntegrationSettings() }
        integrations.openURL = { _ in XCTFail("tests never open a browser") }
        integrations.inboxClients = InboxClients(slack: slack, gmail: gmail)
        integrations.replyWriter = ReplyWriter { _ in
            XCTFail("no AI unless the test sets one up")
            return ""
        }
        integrations.fullName = { "Maya Chen" }
        integrations.attach(store: store, app: app, directory: dir)
        return (integrations, store)
    }

    /// The next launch: a fresh Integrations reading what was saved.
    private func relaunch(_ store: Store) -> Integrations {
        let again = Integrations(transport: Sample.offline, triage: .none, sleep: { _ in })
        again.attach(store: store, app: nil, directory: dir)
        return again
    }

    /// Slack connected as Maya, with the token in the (in-memory) keychain.
    private func slackFile(_ items: [Suggestion] = [], scopes: [String]? = nil) -> IntegrationsFile {
        Keychain.set(Sample.token, for: Keychain.Account.slackUserToken)
        var file = IntegrationsFile()
        file.slack = Sample.account
        file.slackScopes = scopes
        file.suggestions = items
        return file
    }

    /// Gmail connected as Maya, signed in with (or without) the permission to send.
    private func gmailFile(_ items: [Suggestion] = [], canCompose: Bool = true) -> IntegrationsFile {
        Keychain.set("1234-test.apps.googleusercontent.com", for: Keychain.Account.googleClientID)
        Keychain.set("test-client-secret", for: Keychain.Account.googleClientSecret)
        Keychain.set("1//test-refresh", for: Keychain.Account.googleRefreshToken)
        var file = IntegrationsFile()
        file.gmailAddress = Sample.address
        file.gmailScopes = [GoogleOAuth.gmailScope] + (canCompose ? [GoogleOAuth.composeScope] : [])
        file.suggestions = items
        return file
    }

    // MARK: Tabs and saving

    func testEachTabListsItsOwnSourceNewestFirst() throws {
        let (integrations, _) = try make()
        integrations.suggestions = [Sample.email("gmail:t1/m1", minutesAgo: 30), Sample.slack("slack:C0LEAD/1", minutesAgo: 5),
                                    Sample.email("gmail:t2/m2", minutesAgo: 2), Sample.slack("slack:C0LEAD/2", minutesAgo: 50),
                                    Sample.slack("slack:D0DM/3", minutesAgo: 1)]
        XCTAssertEqual(integrations.items(.slack).map(\.id), ["slack:D0DM/3", "slack:C0LEAD/1", "slack:C0LEAD/2"])
        XCTAssertEqual(integrations.items(.gmail).map(\.id), ["gmail:t2/m2", "gmail:t1/m1"])
        XCTAssertTrue(integrations.items(.ai).isEmpty)
        XCTAssertEqual(integrations.suggestion("gmail:t2/m2")?.from, "Sam Lee")
        XCTAssertNil(integrations.suggestion("gmail:t9/m9"))
    }

    func testNotesRepliesAndWholeMessagesComeBackOnTheNextLaunch() throws {
        var email = Sample.email()
        email.content = Sample.fullEmail.content
        email.replyHeaders = Sample.headers
        var file = slackFile([Sample.slack(Sample.threadReplyID, threadTS: Sample.parentTS)])
        file.suggestions.append(email)
        let (integrations, store) = try make(file)

        integrations.setNote("Ask Sam for the churn numbers first.", for: Sample.threadReplyID)
        integrations.setReplyDraft("On it, by Thursday.", for: Sample.threadReplyID)
        integrations.setNote("Sections 4 and 7 only.", for: Sample.emailID)
        integrations.setNote("Nothing to keep it with", for: "slack:C0LEAD/1")
        integrations.flushSaves()

        let saved = try Data(contentsOf: dir.appendingPathComponent("integrations.json"))
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: saved) as? [String: Any])
        XCTAssertEqual(json["version"] as? Int, 2)

        let again = relaunch(store)
        let slack = try XCTUnwrap(again.suggestion(Sample.threadReplyID))
        XCTAssertEqual(slack.note, "Ask Sam for the churn numbers first.")
        XCTAssertEqual(slack.replyDraft, "On it, by Thursday.")
        XCTAssertEqual(slack.threadTS, Sample.parentTS)
        let mail = try XCTUnwrap(again.suggestion(Sample.emailID))
        XCTAssertEqual(mail.note, "Sections 4 and 7 only.")
        XCTAssertEqual(mail.content, Sample.fullEmail.content)
        XCTAssertEqual(mail.replyHeaders, Sample.headers)
        XCTAssertEqual(again.suggestions.count, 2)
    }

    func testAVersion1FileLoadsAndIsWrittenBackAsVersion2() async throws {
        let v1 = #"""
        {"version": 1, "handled": {"slack:C0GEN/1791100000.000100": "2026-10-01T09:00:00Z"},
         "slack": {"userID": "U0MAYA", "userName": "maya", "teamID": "T0ACME", "teamName": "Acme Test"},
         "suggestions": [{"source": {"kind": "slack", "externalID": "slack:C0LEAD/1791200000.000100", "label": "#leadership · Priya Shah"},
          "from": "Priya Shah", "snippet": "Can you approve the Q4 budget?", "receivedAt": "2026-10-05T09:12:00Z", "trigger": "reaction"}]}
        """#
        let store = Store(persistence: Persistence(directory: dir), seedIfEmpty: false)
        stores.append(store)
        try Data(v1.utf8).write(to: dir.appendingPathComponent("integrations.json"))
        let integrations = relaunch(store)
        let id = "slack:C0LEAD/1791200000.000100"
        XCTAssertEqual(integrations.suggestions.map(\.id), [id])
        XCTAssertTrue(integrations.isSlackConnected)
        XCTAssertTrue(integrations.missingSlackScopes.isEmpty, "not known yet: no banner")
        XCTAssertFalse(integrations.gmailCanCompose)

        // Saved before Docket kept whole messages: the text kept then stands in.
        let content = try await integrations.content(for: id)
        XCTAssertEqual(content.text, "Can you approve the Q4 budget?")
        XCTAssertNil(content.markup)

        integrations.setNote("Approve if it's under budget", for: id)
        integrations.flushSaves()
        let saved = IntegrationsFile.load(from: dir.appendingPathComponent("integrations.json"))
        XCTAssertEqual(saved.version, 2)
        XCTAssertEqual(saved.suggestions.first?.note, "Approve if it's under budget")
        XCTAssertEqual(Array(saved.handled.keys), ["slack:C0GEN/1791100000.000100"])
        XCTAssertNil(saved.slackScopes)
    }

    func testTypingWaitsForAPauseButQuittingWritesWhatsWaiting() throws {
        let url = dir.appendingPathComponent("integrations.json")
        let saver = IntegrationsSaver()
        var file = IntegrationsFile()
        file.lastRefresh = Date(timeIntervalSince1970: 1_791_200_000)
        saver.save(file, to: url, after: 60)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path), "still typing")
        saver.flush()
        XCTAssertEqual(IntegrationsFile.load(from: url).lastRefresh, file.lastRefresh)

        // The newest state wins.
        file.lastRefresh = Date(timeIntervalSince1970: 1_791_300_000)
        saver.save(file, to: url, after: 60)
        file.lastRefresh = Date(timeIntervalSince1970: 1_791_400_000)
        saver.save(file, to: url)
        saver.flush()
        XCTAssertEqual(IntegrationsFile.load(from: url).lastRefresh, Date(timeIntervalSince1970: 1_791_400_000))

        // Quitting writes what's waiting, and whatever the views save as Docket quits lands too, pause or not.
        file.lastRefresh = Date(timeIntervalSince1970: 1_791_500_000)
        saver.save(file, to: url, after: 60)
        saver.quit()
        XCTAssertEqual(IntegrationsFile.load(from: url).lastRefresh, Date(timeIntervalSince1970: 1_791_500_000))
        file.lastRefresh = Date(timeIntervalSince1970: 1_791_600_000)
        saver.save(file, to: url, after: IntegrationsSaver.typingPause)
        XCTAssertEqual(IntegrationsFile.load(from: url).lastRefresh, Date(timeIntervalSince1970: 1_791_600_000), "no pause left to wait for")
    }

    // MARK: Notes into tasks

    func testNotesGoIntoTheTaskAboveALinkBackToTheMessage() throws {
        let app = AppState()
        var slack = Sample.slack(Sample.topID)
        slack.source.url = URL(string: "https://acme-test.slack.com/archives/C0LEAD/p1791203600000200")
        var email = Sample.email()
        email.source.url = GmailClient.threadLink(account: Sample.address, threadID: "t1")
        let dm = Sample.slack("slack:D0DM/1791203000.000300", label: "Direct message · Sam Lee", text: "Quick question about hiring")
        var file = slackFile([slack, dm])
        file.suggestions.append(email)
        let (integrations, store) = try make(file, app: app)

        integrations.setNote("  Ask Sam for the churn numbers first.\n", for: slack.id)
        // Clicked with the copy the view held from before the note was saved: the note goes in all the same.
        let task = try XCTUnwrap(integrations.add(slack, toast: false))
        XCTAssertEqual(task.notes, """
            Ask Sam for the churn numbers first.

            From Slack · #leadership: https://acme-test.slack.com/archives/C0LEAD/p1791203600000200

            #leadership · Priya Shah:
            Can you send the Q3 numbers?
            """)
        XCTAssertEqual(task.source, slack.source)
        XCTAssertEqual(store.tasks.count, 1)

        // Edit… hands the planner the same notes (again from an older copy of the card).
        integrations.setNote("Sections 4 and 7 only.", for: email.id)
        integrations.edit(email)
        XCTAssertEqual(app.aiPlanner?.drafts.first?.notes, """
            Sections 4 and 7 only.

            From Gmail: https://mail.google.com/mail/u/maya@acme.example/#all/t1

            Sam Lee · Contract redlines:
            Attached are the redlines.
            """)

        // A direct message says who it's from; without a link there's no address to give.
        integrations.setNote("Say yes", for: dm.id)
        let withNote = SuggestionDrafts.draft(for: try XCTUnwrap(integrations.suggestion(dm.id)))
        XCTAssertEqual(withNote.notes, "Say yes\n\nFrom Slack · Direct message from Sam Lee\n\nDirect message · Sam Lee:\nQuick question about hiring")
        // No notes: the task is as it always was.
        integrations.setNote("  \n", for: dm.id)
        let without = SuggestionDrafts.draft(for: try XCTUnwrap(integrations.suggestion(dm.id)))
        XCTAssertEqual(without.notes, "Direct message · Sam Lee:\nQuick question about hiring")
    }

    // MARK: Replying

    func testSlackRepliesGoUnderTheMessageAsYou() async throws {
        let slack = FakeSlackInbox()
        let app = AppState()
        let (integrations, store) = try make(slackFile([Sample.slack(Sample.topID), Sample.slack(Sample.threadReplyID, threadTS: Sample.parentTS)]),
                                             slack: slack, app: app)
        integrations.setReplyDraft("Sure, by Thursday.", for: Sample.topID)

        try await integrations.sendReply("  Sure, by Thursday. Q3 < Q2 & that's fine.\n", for: Sample.topID, replyAll: false)
        XCTAssertEqual(slack.replies, [.init(channel: "C0LEAD", threadTS: Sample.topTS, text: "Sure, by Thursday. Q3 < Q2 & that's fine.")],
                       "in a thread under the message, as written (the client escapes it for Slack)")
        let top = try XCTUnwrap(integrations.suggestion(Sample.topID))
        XCTAssertNotNil(top.repliedAt)
        XCTAssertEqual(top.replyDraft, "", "the draft clears once it's sent")
        XCTAssertEqual(app.toast, "Replied in #leadership")

        // A reply in a thread answers in that thread.
        try await integrations.sendReply("Done", for: Sample.threadReplyID, replyAll: false)
        XCTAssertEqual(slack.replies.last, .init(channel: "C0LEAD", threadTS: Sample.parentTS, text: "Done"))

        // Slack has no drafts.
        do {
            try await integrations.saveReplyAsDraft("Later", for: Sample.topID, replyAll: false)
            XCTFail("Slack has no drafts")
        } catch {
            XCTAssertNotNil(error as? IntegrationError)
        }
        XCTAssertEqual(slack.replies.count, 2)

        // "Replied" is still there next launch.
        integrations.flushSaves()
        XCTAssertNotNil(relaunch(store).suggestion(Sample.topID)?.repliedAt)
    }

    func testASecondClickNeverSendsTwiceAndAFailureKeepsTheDraft() async throws {
        let slack = FakeSlackInbox()
        slack.with { $0.delay = 0.1 }
        let (integrations, _) = try make(slackFile([Sample.slack(Sample.topID), Sample.slack(Sample.threadReplyID, threadTS: Sample.parentTS)]),
                                         slack: slack)
        async let first: Void = integrations.sendReply("On it", for: Sample.topID, replyAll: false)
        async let second: Void = integrations.sendReply("On it", for: Sample.topID, replyAll: false)
        _ = try await (first, second)
        XCTAssertEqual(slack.replies.count, 1, "the second click waits for the first send")

        do {
            try await integrations.sendReply(" \n ", for: Sample.topID, replyAll: false)
            XCTFail("an empty reply never goes out")
        } catch {
            XCTAssertNotNil(error as? IntegrationError)
        }
        XCTAssertEqual(slack.replies.count, 1)

        // Slack says no: the draft stays for another try, and nothing counts as replied.
        slack.with {
            $0.delay = 0
            $0.replyError = IntegrationError.api(.slack, "That channel is archived.")
        }
        integrations.setReplyDraft("Will do", for: Sample.threadReplyID)
        do {
            try await integrations.sendReply("Will do", for: Sample.threadReplyID, replyAll: false)
            XCTFail("Slack said no")
        } catch {
            XCTAssertEqual(error as? IntegrationError, .api(.slack, "That channel is archived."))
        }
        XCTAssertEqual(integrations.suggestion(Sample.threadReplyID)?.replyDraft, "Will do")
        XCTAssertNil(integrations.suggestion(Sample.threadReplyID)?.repliedAt)

        // A revoked token disconnects, as a refresh would; the message stays.
        slack.with { $0.replyError = IntegrationError.signedOut(.slack) }
        do {
            try await integrations.sendReply("Will do", for: Sample.threadReplyID, replyAll: false)
            XCTFail("signed out")
        } catch {
            XCTAssertEqual(error as? IntegrationError, .signedOut(.slack))
        }
        XCTAssertFalse(integrations.isSlackConnected)
        XCTAssertNotNil(integrations.slackProblem)
        XCTAssertNotNil(integrations.suggestion(Sample.threadReplyID))
    }

    func testEmailRepliesUseTheOriginalsHeadersAndNeedThePermissionToSend() async throws {
        let gmail = FakeMailInbox(full: Sample.fullEmail)
        let app = AppState()
        let (integrations, _) = try make(gmailFile([Sample.email()], canCompose: false), gmail: gmail, app: app)

        // Signed in before Docket asked to send: nothing goes out.
        XCTAssertFalse(integrations.gmailCanCompose)
        do {
            try await integrations.sendReply("Thanks", for: Sample.emailID, replyAll: false)
            XCTFail("no permission to send")
        } catch {
            XCTAssertEqual(error as? IntegrationError, Integrations.cantCompose)
        }
        XCTAssertTrue(gmail.sent.isEmpty)
        XCTAssertTrue(gmail.fetched.isEmpty)

        // Signed in again with gmail.compose.
        integrations.grantedGmailScopes = [GoogleOAuth.gmailScope, GoogleOAuth.composeScope]
        XCTAssertTrue(integrations.gmailCanCompose)
        integrations.setReplyDraft("Thanks, Sam.", for: Sample.emailID)
        try await integrations.sendReply("Thanks, Sam.", for: Sample.emailID, replyAll: true)
        XCTAssertEqual(gmail.fetched, ["m1"], "the original's headers, fetched once")
        XCTAssertEqual(gmail.sent, [MailReply(threadID: "t1", headers: Sample.headers, fromAddress: Sample.address, body: "Thanks, Sam.", replyAll: true)])
        let item = try XCTUnwrap(integrations.suggestion(Sample.emailID))
        XCTAssertNotNil(item.repliedAt)
        XCTAssertEqual(item.replyDraft, "")
        XCTAssertEqual(item.replyHeaders, Sample.headers)
        XCTAssertEqual(item.content, Sample.fullEmail.content, "the whole email came with the headers")
        XCTAssertEqual(app.toast, "Reply sent")

        // Saved as a Gmail draft: the headers are known by now, the text stays, and it isn't another reply.
        let repliedAt = item.repliedAt
        integrations.setReplyDraft("One more thing", for: Sample.emailID)
        try await integrations.saveReplyAsDraft("One more thing", for: Sample.emailID, replyAll: false)
        XCTAssertEqual(gmail.drafts.map(\.body), ["One more thing"])
        XCTAssertEqual(gmail.drafts.first?.replyAll, false)
        XCTAssertEqual(gmail.drafts.first?.threadID, "t1")
        XCTAssertEqual(gmail.fetched, ["m1"])
        XCTAssertEqual(integrations.suggestion(Sample.emailID)?.replyDraft, "One more thing")
        XCTAssertEqual(integrations.suggestion(Sample.emailID)?.repliedAt, repliedAt)
        XCTAssertEqual(app.toast, "Saved as a draft in Gmail")

        // Google turns sending down after all: Docket stops offering it.
        gmail.with { $0.sendError = IntegrationError.missingPermission(.gmail, "read your email") }
        do {
            try await integrations.sendReply("Again", for: Sample.emailID, replyAll: false)
            XCTFail("Google said no")
        } catch {
            XCTAssertEqual(error as? IntegrationError, Integrations.cantCompose)
        }
        XCTAssertFalse(integrations.gmailCanCompose)
        XCTAssertEqual(Integrations.cantCompose.errorDescription,
                       "Docket needs permission to send replies and save drafts. Connect Gmail again and allow it.")
    }

    func testGmailCanReplyOnlyWithTheComposePermission() throws {
        var file = gmailFile()
        file.gmailScopes = nil
        let (integrations, store) = try make(file)
        XCTAssertFalse(integrations.gmailCanCompose, "signed in before Docket asked to send")
        integrations.grantedGmailScopes = [GoogleOAuth.gmailScope]
        XCTAssertFalse(integrations.gmailCanCompose)
        integrations.grantedGmailScopes = [GoogleOAuth.gmailScope, GoogleOAuth.composeScope]
        XCTAssertTrue(integrations.gmailCanCompose)

        // Remembered across launches.
        integrations.save()
        integrations.flushSaves()
        XCTAssertTrue(relaunch(store).gmailCanCompose)

        integrations.disconnectGmail(problem: "Google signed Docket out.")
        XCTAssertFalse(integrations.gmailCanCompose)
        XCTAssertNil(integrations.grantedGmailScopes)
    }

    // MARK: The complete message

    func testAnEmailIsFetchedOnceAndKeptWithItsItem() async throws {
        let gmail = FakeMailInbox(full: Sample.fullEmail)
        gmail.with { $0.delay = 0.1 }
        let (integrations, store) = try make(gmailFile([Sample.email()]), gmail: gmail)

        async let a = integrations.content(for: Sample.emailID)
        async let b = integrations.content(for: Sample.emailID)
        let (first, second) = try await (a, b)
        XCTAssertEqual(first, Sample.fullEmail.content)
        XCTAssertEqual(second, first)
        XCTAssertEqual(gmail.fetched, ["m1"], "two views asking at once share one fetch")
        _ = try await integrations.content(for: Sample.emailID)
        XCTAssertEqual(gmail.fetched, ["m1"], "then it's kept")

        // Still there next launch, with what a reply needs.
        integrations.flushSaves()
        let again = relaunch(store)
        XCTAssertEqual(again.suggestion(Sample.emailID)?.content, Sample.fullEmail.content)
        XCTAssertEqual(again.suggestion(Sample.emailID)?.replyHeaders, Sample.headers)

        // A body too big for integrations.json is fetched again instead; the headers stay.
        var huge = Sample.fullEmail.content
        huge.html = String(repeating: "<p>Quarterly numbers</p>", count: 20_000)
        integrations.suggestions[0].content = huge
        integrations.save()
        integrations.flushSaves()
        let third = relaunch(store)
        XCTAssertNil(third.suggestion(Sample.emailID)?.content)
        XCTAssertEqual(third.suggestion(Sample.emailID)?.replyHeaders, Sample.headers)

        // A message that's gone says so.
        do {
            _ = try await integrations.content(for: "gmail:t9/m9")
            XCTFail("no such message")
        } catch {
            XCTAssertNotNil(error as? IntegrationError)
        }
    }

    func testRefreshKeepsTheWholeSlackMessageAndFillsInOlderItems() async throws {
        let now = Date()
        func ts(_ date: Date) -> String { String(format: "%.6f", date.timeIntervalSince1970) }
        let pinned = ts(now.addingTimeInterval(-3600)), older = ts(now.addingTimeInterval(-7200))
        let server = FakeIntegrationServer()
        server.slack("reactions.list", """
            {"ok":true,"items":[
              {"type":"message","channel":"C0LEAD","message":{"ts":"\(pinned)","user":"U0PRIYA",
                "text":"Can you send the *Q3 deck* to <@U0SAM> by Friday? &amp; thanks",
                "reactions":[{"name":"pushpin","users":["U0MAYA"],"count":1}],"permalink":"https://acme-test.slack.com/archives/C0LEAD/p1"}},
              {"type":"message","channel":"C0LEAD","message":{"ts":"\(older)","user":"U0SAM","text":"The budget is *final* <#C0FIN|finance>",
                "reactions":[{"name":"pushpin","users":["U0MAYA"],"count":1}]}}
            ],"response_metadata":{"next_cursor":""}}
            """)
        server.slack("search.messages", #"{"ok":true,"messages":{"matches":[]}}"#)
        server.slack("users.info", where: ("user", "U0PRIYA"), #"{"ok":true,"user":{"id":"U0PRIYA","name":"priya","real_name":"Priya Shah"}}"#)
        server.slack("users.info", where: ("user", "U0SAM"), #"{"ok":true,"user":{"id":"U0SAM","name":"sam","real_name":"Sam Lee"}}"#)
        server.slack("conversations.info", where: ("channel", "C0LEAD"), #"{"ok":true,"channel":{"id":"C0LEAD","name":"leadership","is_member":true}}"#)
        // Saved before the inbox: no whole message yet.
        let saved = Suggestion(source: TaskSource(kind: .slack, externalID: "slack:C0LEAD/\(older)", url: nil, label: "#leadership · Sam Lee"),
                               from: "Sam Lee", subject: nil, snippet: "The budget is final", receivedAt: now.addingTimeInterval(-7200),
                               draft: nil, trigger: .reaction)
        let (integrations, store) = try make(slackFile([saved]), transport: server.transport)

        await integrations.refreshNow(now: now)
        XCTAssertNil(integrations.slackProblem)
        XCTAssertEqual(integrations.suggestions.count, 2, "filled in, not suggested twice")
        let fresh = try XCTUnwrap(integrations.suggestion("slack:C0LEAD/\(pinned)"))
        XCTAssertEqual(fresh.content?.markup, "Can you send the *Q3 deck* to <@U0SAM> by Friday? &amp; thanks", "as sent, for rich text")
        XCTAssertEqual(fresh.content?.text, "Can you send the *Q3 deck* to @Sam Lee by Friday? & thanks")
        XCTAssertEqual(fresh.content?.fetchedAt, now)
        let filled = try XCTUnwrap(integrations.suggestion(saved.id))
        XCTAssertEqual(filled.content?.markup, "The budget is *final* <#C0FIN|finance>")
        XCTAssertEqual(filled.snippet, "The budget is final", "the rest of the item is as it was")

        // The names the messages' markup refers to are saved with them, for after a relaunch.
        integrations.flushSaves()
        let file = IntegrationsFile.load(from: dir.appendingPathComponent("integrations.json"))
        XCTAssertEqual(file.slackNames["U0SAM"], "Sam Lee")
        XCTAssertEqual(file.slackNames["C0LEAD"], "leadership")
        XCTAssertNil(file.slackNames["U0PRIYA"], "only names the markup or the place needs")
        XCTAssertEqual(relaunch(store).slackNames["U0SAM"], "Sam Lee")
    }

    // MARK: Earlier messages

    func testThreadsLoadOnceAndAuthorsGetNames() async throws {
        let slack = FakeSlackInbox()
        let parent = Date(timeIntervalSince1970: 1_791_199_000)
        slack.with {
            $0.threadAnswer = [ThreadMessage(id: Sample.parentTS, from: "U0SAM", date: parent, text: "Board call is Thursday.", isMine: false),
                               ThreadMessage(id: "1791199500.000070", from: "Maya Chen", date: parent.addingTimeInterval(500), text: "Thanks!", isMine: true)]
            $0.people = ["U0SAM": "Sam Lee"]
            $0.delay = 0.05
        }
        let elsewhere = Sample.slack("slack:C0LEAD/1791201000.000400", threadTS: "1791200900.000010")
        let (integrations, _) = try make(slackFile([Sample.slack(Sample.threadReplyID, threadTS: Sample.parentTS), Sample.slack(Sample.topID),
                                                    elsewhere]), slack: slack)

        async let a = integrations.thread(for: Sample.threadReplyID)
        async let b = integrations.thread(for: Sample.threadReplyID)
        let (first, second) = try await (a, b)
        XCTAssertEqual(first.map(\.from), ["Sam Lee", "Maya Chen"], "authors by name")
        XCTAssertEqual(second, first)
        XCTAssertEqual(slack.threadCalls, [.init(channel: "C0LEAD", threadTS: Sample.parentTS, excluding: Sample.replyTS,
                                                 limit: Integrations.threadLimit, myUserID: "U0MAYA")])
        XCTAssertEqual(slack.lookups, ["U0SAM"])
        XCTAssertEqual(integrations.slackNames["U0SAM"], "Sam Lee", "remembered like the people a refresh meets")
        _ = try await integrations.thread(for: Sample.threadReplyID)
        XCTAssertEqual(slack.threadCalls.count, 1, "kept while Docket runs")

        // A message on its own has no earlier messages: Slack isn't asked.
        let none = try await integrations.thread(for: Sample.topID)
        XCTAssertTrue(none.isEmpty)
        XCTAssertEqual(slack.threadCalls.count, 1)

        // Another thread: Slack is handed the people Docket knows by now, so they aren't looked up again.
        _ = try await integrations.thread(for: elsewhere.id)
        XCTAssertEqual(slack.threadCalls.count, 2)
        XCTAssertNil(slack.threadNames.first?["U0SAM"])
        XCTAssertEqual(slack.threadNames.last?["U0SAM"], "Sam Lee")
    }

    func testAThreadWithoutTheHistoryPermissionSaysWhatsMissingInsteadOfFailing() async throws {
        let slack = FakeSlackInbox()
        slack.with { $0.threadError = IntegrationError.missingPermission(.slack, "channels:history,groups:history") }
        let other = "slack:C0LEAD/1791200500.000300"
        let (integrations, _) = try make(slackFile([Sample.slack(Sample.threadReplyID, threadTS: Sample.parentTS),
                                                    Sample.slack(other, threadTS: Sample.parentTS)]), slack: slack)
        XCTAssertTrue(integrations.missingSlackScopes.isEmpty)

        let messages = try await integrations.thread(for: Sample.threadReplyID)
        XCTAssertTrue(messages.isEmpty, "no thread context, but no error either")
        XCTAssertEqual(integrations.missingSlackScopes, ["channels:history", "groups:history"])
        XCTAssertEqual(IntegrationError.missingPermission(.slack, "channels:history,groups:history").errorDescription,
                       "Docket needs more Slack permissions to show files and threads. Update the Docket app in Settings → Connections.")

        // Not remembered as "no thread": with the permission, it's asked again.
        slack.with {
            $0.threadError = nil
            $0.threadAnswer = [ThreadMessage(id: Sample.parentTS, from: "Sam Lee", date: Date(), text: "Board call is Thursday.", isMine: false)]
        }
        let later = try await integrations.thread(for: Sample.threadReplyID)
        XCTAssertEqual(later.map(\.text), ["Board call is Thursday."])
        XCTAssertEqual(slack.threadCalls.count, 2)

        // When Slack listed the token's permissions and there's no history among them, it isn't asked at all.
        integrations.grantedSlackScopes = Set(Sample.olderScopes)
        let skipped = try await integrations.thread(for: other)
        XCTAssertTrue(skipped.isEmpty)
        XCTAssertEqual(slack.threadCalls.count, 2)
        XCTAssertTrue(integrations.missingSlackScopes.isSuperset(of: InboxScopes.slackHistory))
    }

    func testAnOlderItemsThreadIsLookedForAgainOnceACheckFillsItIn() async throws {
        let slack = FakeSlackInbox()
        slack.with { $0.threadAnswer = [ThreadMessage(id: Sample.parentTS, from: "Sam Lee", date: Date(), text: "Board call is Thursday.", isMine: false)] }
        // Saved before Docket kept whole messages: not known yet to be a reply in a thread.
        let (integrations, _) = try make(slackFile([Sample.slack(Sample.threadReplyID)]), slack: slack)
        let before = try await integrations.thread(for: Sample.threadReplyID)
        XCTAssertTrue(before.isEmpty)
        XCTAssertTrue(slack.threadCalls.isEmpty)

        // The next check fills in its whole message and its thread: opening it again shows the thread.
        integrations.suggestions[0].content = MessageContent(text: "Can you send the Q3 numbers?", fetchedAt: Date())
        integrations.suggestions[0].threadTS = Sample.parentTS
        let after = try await integrations.thread(for: Sample.threadReplyID)
        XCTAssertEqual(after.map(\.text), ["Board call is Thursday."])
        XCTAssertEqual(slack.threadCalls.count, 1)
    }

    func testEmailConversationsComeFromGmailWithoutTheMessageItself() async throws {
        let gmail = FakeMailInbox(full: Sample.fullEmail)
        gmail.with {
            $0.conversation = [ThreadMessage(id: "m0", from: "Maya Chen", date: Date(timeIntervalSince1970: 1_791_000_000),
                                             text: "Here's our MSA draft.", isMine: true)]
        }
        let (integrations, _) = try make(gmailFile([Sample.email()]), gmail: gmail)
        let earlier = try await integrations.thread(for: Sample.emailID)
        XCTAssertEqual(earlier.map(\.text), ["Here's our MSA draft."])
        XCTAssertEqual(gmail.conversationCalls, [.init(threadID: "t1", excluding: "m1", limit: Integrations.threadLimit, myAddress: Sample.address)])
        _ = try await integrations.thread(for: Sample.emailID)
        XCTAssertEqual(gmail.conversationCalls.count, 1)
    }

    // MARK: Attachments

    func testAttachmentsAreDownloadedOnceIntoTheCacheUnderTheirOwnName() async throws {
        let slack = FakeSlackInbox()
        slack.with {
            $0.file = Data("%PDF-1.7 board deck".utf8)
            $0.delay = 0.05
        }
        var item = Sample.slack(Sample.topID)
        item.content = MessageContent(text: "Deck attached", attachments: [Sample.deck], fetchedAt: Date())
        let (integrations, store) = try make(slackFile([item]), slack: slack)

        let id = item.id
        async let a = integrations.file(for: Sample.deck, messageID: id)
        async let b = integrations.file(for: Sample.deck, messageID: id)
        let (first, second) = try await (a, b)
        XCTAssertEqual(first, second)
        XCTAssertEqual(slack.downloads, [Sample.deckURL], "one download for both")
        XCTAssertEqual(first.lastPathComponent, "Q3 deck.pdf", "Quick Look shows the real name")
        XCTAssertEqual(first.deletingLastPathComponent().lastPathComponent, InboxCache.key(messageID: item.id, attachmentID: "F0DECK"))
        XCTAssertEqual(first.deletingLastPathComponent().deletingLastPathComponent().resolvingSymlinksInPath(),
                       dir.appendingPathComponent("IntegrationCache").resolvingSymlinksInPath())
        XCTAssertEqual(try Data(contentsOf: first), Data("%PDF-1.7 board deck".utf8))
        let permissions = try FileManager.default.attributesOfItem(atPath: first.path)[.posixPermissions] as? Int
        XCTAssertEqual(permissions, 0o600, "the user's alone, never executable")
        XCTAssertNotNil(try first.resourceValues(forKeys: [.quarantinePropertiesKey]).quarantineProperties,
                        "macOS checks it like any download before opening it")

        // Kept: asking again, even after a relaunch, doesn't download it again.
        _ = try await integrations.file(for: Sample.deck, messageID: item.id)
        let again = relaunch(store)
        again.inboxClients = InboxClients(slack: slack)
        _ = try await again.file(for: Sample.deck, messageID: item.id)
        XCTAssertEqual(slack.downloads.count, 1)

        // Disconnecting forgets the files with the messages.
        integrations.disconnectSlack()
        XCTAssertFalse(FileManager.default.fileExists(atPath: first.path))
    }

    func testEmailAttachmentsComeFromTheirMessage() async throws {
        let gmail = FakeMailInbox(full: Sample.fullEmail)
        gmail.with { $0.attachment = Data("png".utf8) }
        let (integrations, _) = try make(gmailFile([Sample.email()]), gmail: gmail)
        let inline = MessageAttachment(id: "m1/a2", name: "", mimeType: "image/png", size: 3, remote: .gmail(messageID: "m1", attachmentID: "a2"),
                                       contentID: "chart@acme.example")
        let url = try await integrations.file(for: inline, messageID: Sample.emailID)
        XCTAssertEqual(url.lastPathComponent, "Image.png")
        XCTAssertEqual(gmail.attachmentCalls, [["m1", "a2"]])
        XCTAssertEqual(try Data(contentsOf: url), Data("png".utf8))
    }

    func testFilesThatCantOrShouldntBeDownloaded() async throws {
        let slack = FakeSlackInbox()
        let (integrations, _) = try make(slackFile([Sample.slack(Sample.topID)], scopes: Sample.olderScopes), slack: slack)

        let big = MessageAttachment(id: "F0BIG", name: "launch.mov", mimeType: "video/quicktime", size: 400 * 1024 * 1024,
                                    remote: .slack(url: Sample.deckURL, thumbnail: nil))
        do {
            _ = try await integrations.file(for: big, messageID: Sample.topID)
            XCTFail("too big")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("too big to open in Docket. Open it in Slack."), error.localizedDescription)
        }

        // The token only goes to Slack.
        let elsewhere = MessageAttachment(id: "F0ELSE", name: "deck.pdf", mimeType: "application/pdf",
                                          remote: .slack(url: try XCTUnwrap(URL(string: "https://files.example.com/deck.pdf")), thumbnail: nil))
        do {
            _ = try await integrations.file(for: elsewhere, messageID: Sample.topID)
            XCTFail("not a Slack address")
        } catch {
            XCTAssertEqual(error as? IntegrationError, .api(.slack, "That file isn't stored in Slack, so Docket can't download it."))
        }

        // Without files:read Slack can't hand it over: the views offer Open in Slack instead.
        XCTAssertTrue(integrations.missingSlackScopes.contains("files:read"))
        do {
            _ = try await integrations.file(for: Sample.deck, messageID: Sample.topID)
            XCTFail("no permission")
        } catch {
            XCTAssertEqual(error as? IntegrationError, .missingPermission(.slack, "files:read"))
        }
        XCTAssertTrue(slack.downloads.isEmpty)
    }

    func testCacheFoldersAreHashesAndFileNamesAreSafe() throws {
        let key = InboxCache.key(messageID: "slack:C0LEAD/1", attachmentID: "F1")
        XCTAssertEqual(key.count, 32)
        XCTAssertTrue(key.allSatisfy { $0.isHexDigit && !$0.isUppercase })
        XCTAssertEqual(key, InboxCache.key(messageID: "slack:C0LEAD/1", attachmentID: "F1"), "the same every time")
        XCTAssertNotEqual(key, InboxCache.key(messageID: "slack:C0LEAD/1", attachmentID: "F2"))
        XCTAssertNotEqual(key, InboxCache.key(messageID: "slack:C0LEAD/2", attachmentID: "F1"))
        XCTAssertNotEqual(InboxCache.key(messageID: "ab", attachmentID: "c"), InboxCache.key(messageID: "a", attachmentID: "bc"))

        func name(_ raw: String, _ type: String = "application/pdf") -> String {
            InboxCache.fileName(for: MessageAttachment(id: "x", name: raw, mimeType: type, remote: .gmail(messageID: "m", attachmentID: "a")))
        }
        XCTAssertEqual(name("Q3 deck.pdf"), "Q3 deck.pdf")
        XCTAssertEqual(name("report"), "report.pdf", "an extension from the type")
        XCTAssertEqual(name("", "image/png"), "Image.png")
        XCTAssertEqual(name(".hidden", "text/plain"), "hidden.txt")
        XCTAssertEqual(name("Q3 plan.final draft"), "Q3 plan.final draft.pdf")
        let long = name(String(repeating: "a", count: 300) + ".pdf")
        XCTAssertLessThanOrEqual(long.utf8.count, 200)
        XCTAssertTrue(long.hasSuffix("a.pdf"))
        for raw in ["../../etc/passwd", "a/b:c\\d.txt", "..", "\u{0}\u{7}", "   ", ".", "/"] {
            let safe = name(raw)
            XCTAssertFalse(safe.isEmpty, raw)
            XCTAssertFalse(safe.contains("/") || safe.contains(":") || safe.contains("\\"), safe)
            XCTAssertFalse(safe.hasPrefix("."), safe)
            XCTAssertTrue(safe.unicodeScalars.allSatisfy { !CharacterSet.controlCharacters.contains($0) }, safe)
        }

        func slackFile(_ address: String) throws -> Bool { InboxCache.isSlackFile(try XCTUnwrap(URL(string: address))) }
        XCTAssertTrue(InboxCache.isSlackFile(Sample.deckURL))
        XCTAssertTrue(try slackFile("https://files.slack-gov.com/files-pri/T1-F1/x.pdf"))
        XCTAssertFalse(try slackFile("http://files.slack.com/files-pri/T1-F1/x.pdf"), "HTTPS only")
        XCTAssertFalse(try slackFile("https://slack.com.evil.example/x.pdf"))
        XCTAssertFalse(try slackFile("https://notslack.com/x.pdf"))
        XCTAssertFalse(try slackFile("https://files.slack.com:8443/files-pri/T1-F1/x.pdf"))
        XCTAssertFalse(try slackFile("https://someone@files.slack.com/files-pri/T1-F1/x.pdf"))
    }

    func testCleanUpDropsFilesOfGoneMessagesAfterAWeekThenTheLeastUsedOverTheCap() async throws {
        let root = dir.appendingPathComponent("IntegrationCache")
        let now = Date()
        func entry(_ key: String, daysAgo: Double, bytes: Int) throws {
            let folder = root.appendingPathComponent(key)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let file = folder.appendingPathComponent("file.pdf")
            try Data(count: bytes).write(to: file)
            try FileManager.default.setAttributes([.modificationDate: now.addingTimeInterval(-daysAgo * 86_400)], ofItemAtPath: file.path)
        }
        try entry("live-old", daysAgo: 30, bytes: 10)
        try entry("in-use", daysAgo: 29, bytes: 10)
        try entry("gone-old", daysAgo: 8, bytes: 10)
        try entry("gone-recent", daysAgo: 2.5, bytes: 10)
        let removed = InboxCache.prune(root, live: ["live-old"], keep: ["in-use"], now: now)
        XCTAssertEqual(removed, ["gone-old"])
        XCTAssertEqual(Set(InboxCache.entries(in: root).map(\.key)), ["live-old", "in-use", "gone-recent"])

        // Over the cap: the least recently used go first, whatever their message, until it fits.
        try entry("a", daysAgo: 3, bytes: 400)
        try entry("b", daysAgo: 2, bytes: 400)
        try entry("c", daysAgo: 1, bytes: 400)
        let trimmed = InboxCache.prune(root, live: ["live-old", "a", "b", "c"], keep: ["in-use"], now: now, maxBytes: 1000)
        XCTAssertEqual(trimmed, ["live-old", "a"])
        XCTAssertEqual(Set(InboxCache.entries(in: root).map(\.key)), ["in-use", "gone-recent", "b", "c"])

        // Through Integrations: what's live is what the inbox's messages still attach. Using a file keeps it fresh.
        var item = Sample.slack(Sample.topID)
        item.content = MessageContent(text: "Deck attached", attachments: [Sample.deck], fetchedAt: now)
        let (integrations, _) = try make(slackFile([item]))
        let deckKey = InboxCache.key(messageID: item.id, attachmentID: Sample.deck.id)
        try entry(deckKey, daysAgo: 20, bytes: 10)
        let location = InboxCache.location(for: Sample.deck, key: deckKey, in: root)
        try Data("deck".utf8).write(to: location)
        try FileManager.default.setAttributes([.modificationDate: now.addingTimeInterval(-20 * 86_400)], ofItemAtPath: location.path)
        let cleaned = await integrations.pruneInboxCache(now: now.addingTimeInterval(86_400))?.value ?? []
        XCTAssertFalse(cleaned.contains(deckKey), "its message is still in the inbox")
        XCTAssertFalse(cleaned.contains("gone-recent"), "gone, but used less than a week ago")
        let reused = try await integrations.file(for: Sample.deck, messageID: item.id)
        XCTAssertEqual(reused.resolvingSymlinksInPath(), location.resolvingSymlinksInPath())
        let used = try XCTUnwrap(InboxCache.entries(in: root).first { $0.key == deckKey }?.used)
        XCTAssertLessThan(abs(used.timeIntervalSinceNow), 60, "opening it counts as using it")
    }

    // MARK: Permissions

    func testMissingSlackPermissionsComeFromWhatSlackGranted() async throws {
        let server = FakeIntegrationServer()
        let everything = Sample.olderScopes + SlackManifest.contentScopes.sorted()
        server.on({ $0.url?.host == "slack.com" && $0.url?.path == "/api/auth.test" }, [
            .init(body: Sample.authTest, headers: ["x-oauth-scopes": Sample.olderScopes.joined(separator: ",")]),
            .init(body: Sample.authTest, headers: ["x-oauth-scopes": everything.joined(separator: ",")]),
            .init(body: Sample.authTest),
        ])
        server.slack("reactions.list", #"{"ok":true,"items":[],"response_metadata":{"next_cursor":""}}"#)
        server.slack("search.messages", #"{"ok":true,"messages":{"matches":[]}}"#)
        let (integrations, store) = try make(transport: server.transport)
        XCTAssertTrue(integrations.missingSlackScopes.isEmpty, "not connected")

        // An app made before Docket showed whole messages.
        try await integrations.connectSlack(token: Sample.token)
        await integrations.waitForRefresh()
        XCTAssertEqual(integrations.missingSlackScopes, SlackManifest.contentScopes)
        XCTAssertNil(integrations.slackAccount?.missingScopes, "everything else is there")
        XCTAssertNil(integrations.slackScopeWarning, "the inbox has its own banner for these")
        integrations.flushSaves()
        XCTAssertEqual(relaunch(store).missingSlackScopes, SlackManifest.contentScopes, "remembered across launches")

        // The app was updated in Slack: asking again clears it.
        await integrations.checkSlackPermissions()
        XCTAssertTrue(integrations.missingSlackScopes.isEmpty)

        // Slack didn't list them: unknown means no banner, unless Slack turns something down.
        await integrations.checkSlackPermissions()
        XCTAssertNil(integrations.grantedSlackScopes)
        XCTAssertTrue(integrations.missingSlackScopes.isEmpty)
        integrations.noteRefusedSlackScopes("files:read")
        XCTAssertEqual(integrations.missingSlackScopes, ["files:read"])
        integrations.noteRefusedSlackScopes("chat:write")
        XCTAssertEqual(integrations.missingSlackScopes, ["files:read"], "only the ones the inbox needs")

        integrations.disconnectSlack()
        XCTAssertTrue(integrations.missingSlackScopes.isEmpty)
        XCTAssertNil(integrations.grantedSlackScopes)
    }

    // MARK: AI

    func testAIWritesTheReplyFromTheWholeMessageItsThreadAndYourNotes() async throws {
        let slack = FakeSlackInbox()
        slack.with {
            $0.threadAnswer = [ThreadMessage(id: Sample.parentTS, from: "Sam Lee", date: Date(timeIntervalSince1970: 1_791_199_000),
                                             text: "Board call is Thursday.", isMine: false)]
        }
        var item = Sample.slack(Sample.threadReplyID, threadTS: Sample.parentTS)
        item.content = MessageContent(text: "Can you send the Q3 numbers before Thursday?", markup: "Can you send the *Q3 numbers* before Thursday?",
                                      fetchedAt: Date(timeIntervalSince1970: 1_791_200_000))
        let (integrations, _) = try make(slackFile([item]), slack: slack)
        let log = ReplyLog()
        integrations.replyWriter = ReplyWriter { request in
            log.requests.append(request)
            return "  Sure, I'll send them Wednesday.\n"
        }
        integrations.setNote("  Numbers are final; send Wednesday ", for: item.id)

        let reply = try await integrations.draftReply(for: item.id, tone: .friendly, instruction: "  mention the churn dip ")
        XCTAssertEqual(reply, "Sure, I'll send them Wednesday.")
        XCTAssertEqual(integrations.suggestion(item.id)?.replyDraft, reply, "it becomes the reply draft")
        let request = try XCTUnwrap(log.requests.first)
        XCTAssertEqual(request.message.text, "Can you send the Q3 numbers before Thursday?")
        XCTAssertEqual(request.message.source, item.source)
        XCTAssertEqual(request.message.from, "Priya Shah")
        XCTAssertEqual(request.content, item.content)
        XCTAssertEqual(request.thread.map(\.text), ["Board call is Thursday."])
        XCTAssertEqual(request.notes, "Numbers are final; send Wednesday")
        XCTAssertEqual(request.tone, .friendly)
        XCTAssertEqual(request.instruction, "mention the churn dip")
        XCTAssertEqual(request.myName, "Maya Chen")

        // A blank instruction is none; an empty answer is an error, and the draft stays as it was.
        integrations.replyWriter = ReplyWriter { request in
            log.requests.append(request)
            return " \n"
        }
        do {
            _ = try await integrations.draftReply(for: item.id, tone: .brief, instruction: "   ")
            XCTFail("an empty reply is no reply")
        } catch {
            guard case AIError.badResponse = error else { return XCTFail("expected badResponse, got \(error)") }
        }
        XCTAssertEqual(log.requests.count, 2)
        XCTAssertNil(log.requests.last?.instruction)
        XCTAssertEqual(log.requests.last?.tone, .brief)
        XCTAssertEqual(integrations.suggestion(item.id)?.replyDraft, reply)

        // Stopped just as the answer came in: what the user had stays their reply.
        integrations.setReplyDraft("My own words", for: item.id)
        integrations.replyWriter = ReplyWriter { _ in
            withUnsafeCurrentTask { $0?.cancel() } // the user clicks Stop
            return "Sure, I'll send them Wednesday."
        }
        let stopped = Task { @MainActor in try await integrations.draftReply(for: item.id, tone: .brief, instruction: nil) }
        do {
            _ = try await stopped.value
            XCTFail("stopped")
        } catch {
            XCTAssertTrue(error is CancellationError, "\(error)")
        }
        XCTAssertEqual(integrations.suggestion(item.id)?.replyDraft, "My own words")
    }

    func testAIRepliesToAnEmailReadTheWholeEmailFirst() async throws {
        let gmail = FakeMailInbox(full: Sample.fullEmail)
        let (integrations, _) = try make(gmailFile([Sample.email(), Sample.email("gmail:t2/m2")]), gmail: gmail)
        let log = ReplyLog()
        integrations.replyWriter = ReplyWriter { request in
            log.requests.append(request)
            return "Hi Sam,\n\nI'll review sections 4 and 7 by Friday.\n\nBest,\nMaya"
        }
        let reply = try await integrations.draftReply(for: Sample.emailID, tone: .formal, instruction: nil)
        XCTAssertTrue(reply.hasPrefix("Hi Sam,"))
        XCTAssertEqual(gmail.fetched, ["m1"])
        let request = try XCTUnwrap(log.requests.first)
        XCTAssertEqual(request.message.text, Sample.fullEmail.content.text)
        XCTAssertEqual(request.message.from, "Sam Lee <sam@northwind.example>", "with the address, from the headers")
        XCTAssertEqual(request.message.subject, "Contract redlines")
        XCTAssertEqual(request.content, Sample.fullEmail.content)
        XCTAssertEqual(request.myName, "Maya Chen")
        XCTAssertNil(request.instruction)

        // Gmail out of reach and nothing kept: it still writes, from the snippet.
        integrations.inboxClients = InboxClients()
        Keychain.set(nil, for: Keychain.Account.googleRefreshToken)
        _ = try await integrations.draftReply(for: "gmail:t2/m2", tone: .brief, instruction: nil)
        XCTAssertEqual(log.requests.last?.message.text, "Attached are the redlines.")
        XCTAssertNil(log.requests.last?.content)
        XCTAssertEqual(gmail.fetched, ["m1"])

        // A starred email the user sent: marked as theirs, so the reply follows it up instead of greeting them.
        var sent = Sample.headers
        sent.from = "Maya Chen <Maya@Acme.example>"
        sent.to = ["Sam Lee <sam@northwind.example>"]
        let own = try XCTUnwrap(integrations.suggestions.firstIndex { $0.id == "gmail:t2/m2" })
        integrations.suggestions[own].replyHeaders = sent
        _ = try await integrations.draftReply(for: "gmail:t2/m2", tone: .brief, instruction: nil)
        XCTAssertEqual(log.requests.last?.message.from, "Maya Chen <Maya@Acme.example> (you)")
    }

    func testTheUsersOwnSlackMessageIsMarkedSoTheReplyFollowsItUp() async throws {
        let mine = Sample.slack(Sample.topID, label: "#leadership · Maya Chen", text: "Board deck is due Wednesday.")
        let theirs = Sample.slack("slack:C0LEAD/1791203700.000300")
        let (integrations, _) = try make(slackFile([mine, theirs]), slack: FakeSlackInbox())
        let log = ReplyLog()
        integrations.replyWriter = ReplyWriter { request in
            log.requests.append(request)
            return "Quick nudge on this."
        }
        // Who the user is in Slack isn't known yet: nothing is marked.
        _ = try await integrations.draftReply(for: mine.id, tone: .brief, instruction: nil)
        XCTAssertEqual(log.requests.last?.message.from, "Maya Chen")

        integrations.rememberSlackUsers([SlackUser(id: "U0MAYA", name: "Maya Chen", status: SlackStatus())])
        _ = try await integrations.draftReply(for: mine.id, tone: .brief, instruction: nil)
        XCTAssertEqual(log.requests.last?.message.from, "Maya Chen (you)")
        XCTAssertEqual(log.requests.last?.myName, "Maya Chen")
        _ = try await integrations.draftReply(for: theirs.id, tone: .brief, instruction: nil)
        XCTAssertEqual(log.requests.last?.message.from, "Priya Shah")
    }

    // MARK: Words and ids

    func testIDsNamesAndToasts() {
        XCTAssertEqual(InboxIDs.slack("slack:C0LEAD/1791200000.000100")?.channel, "C0LEAD")
        XCTAssertEqual(InboxIDs.slack("slack:C0LEAD/1791200000.000100")?.ts, "1791200000.000100")
        XCTAssertEqual(InboxIDs.gmail("gmail:t1/m1")?.thread, "t1")
        XCTAssertEqual(InboxIDs.gmail("gmail:t1/m1")?.message, "m1")
        XCTAssertNil(InboxIDs.gmail("gmail:demo-2"))
        XCTAssertNil(InboxIDs.slack("gmail:t1/m1"))
        XCTAssertNil(InboxIDs.slack("slack:/1"))
        XCTAssertNil(InboxIDs.slack("slack:C0/1/2"))

        XCTAssertEqual(InboxText.slackIDs(in: "Hi <@U0SAM>, see <#C0LEAD|leadership> and <https://x.example>"), ["U0SAM", "C0LEAD"])

        XCTAssertTrue(InboxText.isSlackUserID("U0SAM"))
        XCTAssertTrue(InboxText.isSlackUserID("W012ABCDEF"))
        XCTAssertFalse(InboxText.isSlackUserID("Sam Lee"))
        XCTAssertFalse(InboxText.isSlackUserID("UNITED"))
        XCTAssertFalse(InboxText.isSlackUserID("U1"))

        let channel = Sample.slack("slack:C0LEAD/1")
        XCTAssertEqual(InboxText.repliedToast(for: channel), "Replied in #leadership")
        XCTAssertEqual(InboxText.repliedToast(for: Sample.slack("slack:D0DM/1", label: "Direct message · Sam Lee")), "Replied to Sam Lee")
        XCTAssertEqual(InboxText.repliedToast(for: Sample.slack("slack:G0GRP/1", label: "Group message · Sam Lee")), "Reply sent")
    }

    // MARK: Screenshot mode

    func testScreenshotSamplesFillBothTabsWithoutTheNetwork() async throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let image = dir.appendingPathComponent("chart.png"), document = dir.appendingPathComponent("redlines.pdf")
        try Data("png".utf8).write(to: image)
        try Data("%PDF".utf8).write(to: document)
        let integrations = Integrations(transport: { request in
            XCTFail("no network in screenshot mode: \(request.url?.host ?? "")")
            throw URLError(.notConnectedToInternet)
        }, triage: .none, sleep: { _ in })
        let now = Date()
        integrations.debugSeed(imageFile: image, documentFile: document, now: now)

        XCTAssertTrue(integrations.isSlackConnected)
        XCTAssertTrue(integrations.isGmailConnected)
        XCTAssertTrue(integrations.missingSlackScopes.isEmpty)
        XCTAssertTrue(integrations.gmailCanCompose)
        XCTAssertNotNil(integrations.lastRefresh)
        let slack = integrations.items(.slack), email = integrations.items(.gmail)
        XCTAssertGreaterThanOrEqual(slack.count, 2)
        XCTAssertGreaterThanOrEqual(email.count, 2)
        let all = slack + email
        XCTAssertTrue(all.allSatisfy { $0.content != nil && $0.receivedAt <= now && $0.draft != nil })
        XCTAssertTrue(all.contains { !$0.note.isEmpty })
        XCTAssertTrue(all.contains { !$0.replyDraft.isEmpty })
        XCTAssertTrue(all.contains { $0.repliedAt != nil })
        XCTAssertTrue(email.allSatisfy { $0.replyHeaders != nil })
        XCTAssertTrue(email.contains { $0.content?.html != nil })
        XCTAssertTrue(slack.contains { $0.content?.markup?.contains("<@") == true })

        // Every item's whole message, thread and files come without the network.
        var files: [URL] = []
        for s in all {
            _ = try await integrations.content(for: s.id)
            _ = try await integrations.thread(for: s.id)
            for attachment in s.content?.attachments ?? [] {
                files.append(try await integrations.file(for: attachment, messageID: s.id))
            }
        }
        XCTAssertTrue(files.contains(image))
        XCTAssertTrue(files.contains(document))
        let threaded = try XCTUnwrap(slack.first { $0.threadTS != nil })
        let earlier = try await integrations.thread(for: threaded.id)
        XCTAssertFalse(earlier.isEmpty)
        XCTAssertTrue(earlier.contains { $0.isMine })
        XCTAssertEqual(integrations.slackNames["U0DEMOSAM"], "Sam Lee", "people in the markup have names")

        // Without sample files, there are no attachments to show.
        let bare = Integrations(transport: Sample.offline, triage: .none, sleep: { _ in })
        bare.debugSeed(imageFile: nil, documentFile: nil, now: now)
        XCTAssertEqual(bare.suggestions.count, all.count)
        XCTAssertTrue(bare.suggestions.allSatisfy { $0.content?.attachments.isEmpty == true })

        // Never over real data.
        let (real, _) = try make(slackFile([Sample.slack(Sample.topID)]))
        real.debugSeed(imageFile: image, documentFile: document, now: now)
        XCTAssertEqual(real.suggestions.map(\.id), [Sample.topID])
    }
}
