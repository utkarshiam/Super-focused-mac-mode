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

    struct FullThreadCall: Equatable {
        var channel: String
        var threadTS: String
        var myUserID: String
    }

    struct StarCall: Equatable {
        var starred: Bool
        var channel: String
        var ts: String
    }

    struct State {
        var replies: [Reply] = []
        var threadCalls: [ThreadCall] = []
        /// The names each thread call was handed as already known.
        var threadNames: [[String: String]] = []
        var fullThreadCalls: [FullThreadCall] = []
        /// The inbox message and the names each whole-thread call was handed.
        var fullThreadAround: [String?] = []
        var fullThreadNames: [[String: String]] = []
        var starCalls: [StarCall] = []
        var downloads: [URL] = []
        var lookups: [String] = []
        var replyError: Error?
        var threadAnswer: [ThreadMessage] = []
        var threadError: Error?
        /// The whole thread, in turn for each call (the last one repeats).
        var fullThreadAnswers: [[ThreadSlackMessage]] = []
        var fullThreadError: Error?
        var starError: Error?
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
    var fullThreadCalls: [FullThreadCall] { with { $0.fullThreadCalls } }
    var fullThreadAround: [String?] { with { $0.fullThreadAround } }
    var fullThreadNames: [[String: String]] { with { $0.fullThreadNames } }
    var starCalls: [StarCall] { with { $0.starCalls } }
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

    func fullThread(channel: String, threadTS: String, myUserID: String) async throws -> [ThreadSlackMessage] {
        try await fullThread(channel: channel, threadTS: threadTS, myUserID: myUserID, names: [:], around: nil)
    }

    func fullThread(channel: String, threadTS: String, myUserID: String, names: [String: String],
                    around: String?) async throws -> [ThreadSlackMessage] {
        try await pause()
        return try with { s in
            s.fullThreadCalls.append(FullThreadCall(channel: channel, threadTS: threadTS, myUserID: myUserID))
            s.fullThreadAround.append(around)
            s.fullThreadNames.append(names)
            if let error = s.fullThreadError { throw error }
            guard !s.fullThreadAnswers.isEmpty else { return [] }
            return s.fullThreadAnswers.count > 1 ? s.fullThreadAnswers.removeFirst() : s.fullThreadAnswers[0]
        }
    }

    func setStarred(_ starred: Bool, channel: String, ts: String) async throws {
        try await pause()
        try with { s in
            s.starCalls.append(StarCall(starred: starred, channel: channel, ts: ts))
            if let error = s.starError { throw error }
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

    struct StarCall: Equatable {
        var starred: Bool
        var messageID: String
    }

    struct State {
        var full: GmailFullMessage
        var fetched: [String] = []
        var conversation: [ThreadMessage] = []
        var conversationCalls: [ConversationCall] = []
        /// The whole conversation, in turn for each call (the last one repeats).
        var emails: [[ThreadEmail]] = []
        /// The conversations asked for in whole (thread ids).
        var wholeCalls: [String] = []
        var wholeError: Error?
        var starCalls: [StarCall] = []
        var starError: Error?
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
    var wholeCalls: [String] { with { $0.wholeCalls } }
    var starCalls: [StarCall] { with { $0.starCalls } }
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

    func conversationMessages(threadID: String, myAddress: String) async throws -> [ThreadEmail] {
        try await pause()
        return try with { s in
            s.wholeCalls.append(threadID)
            if let error = s.wholeError { throw error }
            guard !s.emails.isEmpty else { return [] }
            return s.emails.count > 1 ? s.emails.removeFirst() : s.emails[0]
        }
    }

    func setStarred(_ starred: Bool, messageID: String) async throws {
        try await pause()
        try with { s in
            s.starCalls.append(StarCall(starred: starred, messageID: messageID))
            if let error = s.starError { throw error }
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

    // The whole thread and conversation around the samples above.

    static let jordanTS = "1791200600.000300"

    static func post(_ ts: String, _ user: String?, _ from: String, _ text: String, mine: Bool = false,
                     files: [MessageAttachment] = []) -> ThreadSlackMessage {
        ThreadSlackMessage(id: ts, from: from, userID: user, date: Date(timeIntervalSince1970: TimeInterval(ts) ?? 0),
                           markup: text, text: text, files: files, isMine: mine)
    }

    /// The #leadership thread `threadReplyID` is in, as Slack sends it: Sam's parent, Maya's answer, Priya's
    /// ask (the item, with the deck) and Jordan's reply after it, whose name Slack didn't send.
    static let leadership = [
        post(parentTS, "U0SAM", "Sam Lee", "Board call is Thursday."),
        post("1791199500.000070", "U0MAYA", "Maya Chen", "Thanks!", mine: true),
        post(replyTS, "U0PRIYA", "Priya Shah", "Can you send the Q3 numbers?", files: [deck]),
        post(jordanTS, "U0JORDAN", "Someone", "I can help with the appendix."),
    ]

    static func mail(_ id: String, from name: String, _ address: String, at seconds: TimeInterval, text: String, mine: Bool = false,
                     to: [String] = ["Maya Chen <maya@acme.example>"], cc: [String] = []) -> ThreadEmail {
        ThreadEmail(id: id, from: name, date: Date(timeIntervalSince1970: seconds),
                    content: MessageContent(text: text, to: to, cc: cc, fetchedAt: Date(timeIntervalSince1970: seconds)),
                    replyHeaders: MailReplyHeaders(messageID: "<\(id)@mail.example>", references: nil, subject: "Contract redlines",
                                                   from: "\(name) <\(address)>", to: to, cc: cc),
                    isMine: mine, isStarred: false, snippet: text)
    }

    /// The conversation `emailID` (m1) is in, as Gmail sends it: Maya's draft, Sam's redlines (the item) and
    /// Lena's answer to all, quoting Sam.
    static let redlines = [
        mail("m0", from: "Maya Chen", "maya@acme.example", at: 1_791_000_000, text: "Here's our MSA draft.", mine: true,
             to: ["Sam Lee <sam@northwind.example>"]),
        ThreadEmail(id: "m1", from: "Sam Lee", date: Date(timeIntervalSince1970: 1_791_100_000), content: fullEmail.content,
                    replyHeaders: headers, isMine: false, isStarred: false, snippet: "Attached are the redlines."),
        mail("m2", from: "Lena Park", "lena@acme.example", at: 1_791_150_000,
             text: "I can join a call Friday.\n\nOn Sat, Sam Lee wrote:\n> Attached are the redlines.",
             to: ["Sam Lee <sam@northwind.example>", "Maya Chen <maya@acme.example>"]),
    ]
}

// MARK: - Tests

@MainActor
final class InboxTests: XCTestCase {
    var dir: URL!
    /// Integrations holds the store weakly (the app delegate owns it); the test owns it here.
    private var stores: [Store] = []
    /// The Integrations `make` made, which share the test folder.
    private var made: [Integrations] = []

    override func setUp() async throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("docket-inbox-\(UUID().uuidString)")
        Keychain.useInMemoryStore()
    }

    override func tearDown() async throws {
        for integrations in made { integrations.flushSaves() }
        made = []
        stores = []
        Keychain.useInMemoryStore()
        try? FileManager.default.removeItem(at: dir)
    }

    /// Integrations reading `file` from the test folder, with stand-in clients and no AI unless a test sets one.
    private func make(_ file: IntegrationsFile = IntegrationsFile(), slack: FakeSlackInbox? = nil, gmail: FakeMailInbox? = nil,
                      app: AppState? = nil, transport: @escaping IntegrationHTTP.Transport = Sample.offline) throws -> (Integrations, Store) {
        // What an earlier one saves in the background never lands over this one's file.
        for earlier in made { earlier.flushSaves() }
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
        made.append(integrations)
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

    /// Gmail connected as Maya, signed in with (or without) the permission to send, or with gmail.modify (what
    /// Docket asks for now: reading, starring, drafts and sending).
    private func gmailFile(_ items: [Suggestion] = [], canCompose: Bool = true, canModify: Bool = false) -> IntegrationsFile {
        Keychain.set("1234-test.apps.googleusercontent.com", for: Keychain.Account.googleClientID)
        Keychain.set("test-client-secret", for: Keychain.Account.googleClientSecret)
        Keychain.set("1//test-refresh", for: Keychain.Account.googleRefreshToken)
        var file = IntegrationsFile()
        file.gmailAddress = Sample.address
        file.gmailScopes = canModify ? ["openid", "email", GoogleOAuth.modifyScope]
            : [GoogleOAuth.gmailScope] + (canCompose ? [GoogleOAuth.composeScope] : [])
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
        XCTAssertEqual(json["version"] as? Int, 4)
        XCTAssertEqual(IntegrationsFile.currentVersion, 4)

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

    func testAVersion1FileLoadsAndIsWrittenBackAsTheCurrentVersion() async throws {
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
        XCTAssertEqual(saved.version, IntegrationsFile.currentVersion)
        XCTAssertEqual(saved.suggestions.first?.note, "Approve if it's under budget")
        XCTAssertEqual(saved.suggestions.first?.isStarred, false, "a Slack message saved with a reaction isn't starred")
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

    func testFilesOfAWholeThreadAreKeptAndForgottenWithItsItem() async throws {
        // A file on another message of the thread: kept under the item's id, like the item's own.
        let chart = MessageAttachment(id: "F0CHART", name: "Churn chart.png", mimeType: "image/png", size: 3,
                                      remote: .slack(url: URL(string: "https://files.slack.com/files-pri/T0ACME-F0CHART/download/chart.png")!,
                                                     thumbnail: nil))
        var leadership = Sample.leadership
        leadership[0].files = [chart]
        let slack = FakeSlackInbox()
        slack.with {
            $0.fullThreadAnswers = [leadership]
            $0.file = Data("png".utf8)
        }
        let id = Sample.threadReplyID
        let (integrations, _) = try make(slackFile([Sample.slack(id, threadTS: Sample.parentTS)], scopes: SlackManifest.userScopes), slack: slack)
        _ = try await integrations.fullThread(for: id, reload: false)
        let url = try await integrations.file(for: chart, messageID: id)
        XCTAssertTrue(integrations.inboxCacheKeys(integrations.suggestions).contains(InboxCache.key(messageID: id, attachmentID: "F0CHART")),
                      "in use while its thread is open, so tidying up leaves it")

        // Disconnecting forgets them with the message.
        integrations.disconnectSlack()
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
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
        // The whole thread: the parent and the message itself (AI gets that one whole, apart).
        slack.with {
            $0.fullThreadAnswers = [[Sample.post(Sample.parentTS, "U0SAM", "Sam Lee", "Board call is Thursday."),
                                     Sample.post(Sample.replyTS, "U0PRIYA", "Priya Shah", "Can you send the Q3 numbers before Thursday?")]]
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
        XCTAssertNil(request.replyingTo, "a Slack reply answers the message itself, in its thread")
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

    func testAIReadsTheWholeConversationAndKnowsWhichEmailItAnswers() async throws {
        let gmail = FakeMailInbox(full: Sample.fullEmail)
        gmail.with { $0.emails = [Sample.redlines] }
        let (integrations, _) = try make(gmailFile([Sample.email()]), gmail: gmail)
        let log = ReplyLog()
        integrations.replyWriter = ReplyWriter { request in
            log.requests.append(request)
            return "Hi Lena,\n\nFriday works.\n\nBest,\nMaya"
        }

        // By default a reply answers the newest email that isn't yours: Lena's, after the one in the inbox.
        _ = try await integrations.draftReply(for: Sample.emailID, tone: .brief, instruction: nil)
        let request = try XCTUnwrap(log.requests.last)
        XCTAssertEqual(request.thread.map(\.id), ["m0", "m2"], "the rest of the conversation, oldest first")
        XCTAssertEqual(request.thread.last?.text, "I can join a call Friday.", "without the history it quotes")
        XCTAssertEqual(request.thread.first?.isMine, true)
        XCTAssertEqual(request.replyingTo?.id, "m2")
        XCTAssertEqual(request.content, Sample.fullEmail.content, "the email itself came with its conversation")
        XCTAssertTrue(gmail.fetched.isEmpty, "so it wasn't fetched again")
        XCTAssertEqual(gmail.wholeCalls, ["t1"])

        // Picked in the conversation: that one; the inbox's own email is no other message to point at.
        _ = try await integrations.draftReply(for: Sample.emailID, tone: .brief, instruction: nil, replyingTo: "m0")
        XCTAssertEqual(log.requests.last?.replyingTo?.id, "m0")
        XCTAssertEqual(log.requests.last?.replyingTo?.isMine, true, "a follow-up to the user's own email")
        _ = try await integrations.draftReply(for: Sample.emailID, tone: .brief, instruction: nil, replyingTo: "gmail:t1/m1")
        XCTAssertNil(log.requests.last?.replyingTo)
        XCTAssertEqual(gmail.wholeCalls, ["t1"], "the conversation is kept for the session")

        // The conversation can't be loaded: the earlier messages still can.
        let offline = FakeMailInbox(full: Sample.fullEmail)
        offline.with {
            $0.wholeError = IntegrationError.offline(.gmail, "You seem to be offline.")
            $0.conversation = [ThreadMessage(id: "m0", from: "Maya Chen", date: Date(timeIntervalSince1970: 1_791_000_000),
                                             text: "Here's our MSA draft.", isMine: true)]
        }
        let (other, _) = try make(gmailFile([Sample.email("gmail:t2/m2")]), gmail: offline)
        other.replyWriter = integrations.replyWriter
        _ = try await other.draftReply(for: "gmail:t2/m2", tone: .brief, instruction: nil)
        XCTAssertEqual(log.requests.last?.thread.map(\.text), ["Here's our MSA draft."])
        XCTAssertNil(log.requests.last?.replyingTo)
    }

    // MARK: Whole threads

    func testAWholeSlackThreadLoadsOnceWithItsMessageHighlightedAndNamed() async throws {
        let slack = FakeSlackInbox()
        slack.with {
            $0.fullThreadAnswers = [Sample.leadership]
            $0.people = ["U0JORDAN": "Jordan Rivera"]
            $0.delay = 0.05
        }
        let id = Sample.threadReplyID
        let (integrations, _) = try make(slackFile([Sample.slack(id, threadTS: Sample.parentTS)]), slack: slack)

        async let a = integrations.fullThread(for: id, reload: false)
        async let b = integrations.fullThread(for: id, reload: false)
        let (first, second) = try await (a, b)
        XCTAssertEqual(first, second)
        guard case .slack(let messages, let highlighted) = first else { return XCTFail("a Slack thread") }
        XCTAssertEqual(messages.map(\.id), [Sample.parentTS, "1791199500.000070", Sample.replyTS, Sample.jordanTS], "oldest first")
        XCTAssertEqual(highlighted, 2, "the message in the inbox")
        XCTAssertEqual(messages[highlighted].files, [Sample.deck], "each message with its own files")
        XCTAssertEqual(messages.map(\.from), ["Sam Lee", "Maya Chen", "Priya Shah", "Jordan Rivera"], "a writer Slack didn't name is looked up")
        XCTAssertEqual(slack.fullThreadCalls, [.init(channel: "C0LEAD", threadTS: Sample.parentTS, myUserID: "U0MAYA")], "by its parent")
        XCTAssertEqual(slack.fullThreadAround, [Sample.replyTS], "around the inbox message, which a very long thread keeps")
        XCTAssertEqual(slack.lookups, ["U0JORDAN"])
        XCTAssertEqual(integrations.slackNames["U0SAM"], "Sam Lee", "names the thread came with are remembered")
        XCTAssertEqual(integrations.slackNames["U0JORDAN"], "Jordan Rivera")

        // Kept for the session, as the views see it; reload asks again.
        XCTAssertEqual(integrations.wholeThreads[id], first)
        _ = try await integrations.fullThread(for: id, reload: false)
        XCTAssertEqual(slack.fullThreadCalls.count, 1)
        _ = try await integrations.fullThread(for: id, reload: true)
        XCTAssertEqual(slack.fullThreadCalls.count, 2)
        XCTAssertEqual(slack.lookups, ["U0JORDAN"], "people are looked up once")
        XCTAssertEqual(slack.fullThreadNames.last?["U0JORDAN"], "Jordan Rivera", "Slack is handed the names known by then")

        // A message that's gone says so.
        do {
            _ = try await integrations.fullThread(for: "slack:C0LEAD/1791209999.000100", reload: false)
            XCTFail("not in the inbox")
        } catch {
            XCTAssertNotNil(error as? IntegrationError)
        }
    }

    func testAnOlderSlackItemLearnsItsThreadAndAMessageOnItsOwnIsAConversationOfOne() async throws {
        let slack = FakeSlackInbox()
        slack.with { $0.fullThreadAnswers = [Sample.leadership] }
        // Saved before Docket kept whole messages: not known to be in a thread.
        let (integrations, _) = try make(slackFile([Sample.slack(Sample.threadReplyID), Sample.slack(Sample.topID)]), slack: slack)

        let thread = try await integrations.fullThread(for: Sample.threadReplyID, reload: false)
        XCTAssertEqual(slack.fullThreadCalls.first?.threadTS, Sample.replyTS, "asked by its own ts, which Slack answers with its thread")
        XCTAssertEqual(thread.highlightedIndex, 2)
        let item = try XCTUnwrap(integrations.suggestion(Sample.threadReplyID))
        XCTAssertEqual(item.threadTS, Sample.parentTS, "now it's known to be a reply in that thread")
        XCTAssertEqual(item.content?.text, "Can you send the Q3 numbers?")
        XCTAssertEqual(item.content?.attachments, [Sample.deck])

        // A message nobody answered: Slack sends it alone.
        slack.with { $0.fullThreadAnswers = [[Sample.post(Sample.topTS, "U0PRIYA", "Priya Shah", "Can you send the Q3 numbers?")]] }
        let alone = try await integrations.fullThread(for: Sample.topID, reload: false)
        guard case .slack(let messages, let highlighted) = alone else { return XCTFail("a Slack thread") }
        XCTAssertEqual(messages.map(\.id), [Sample.topTS])
        XCTAssertEqual(highlighted, 0)
        XCTAssertNil(integrations.suggestion(Sample.topID)?.threadTS, "not a reply")
    }

    func testWithoutTheHistoryPermissionASlackMessageShowsAloneAndIsAskedAgainLater() async throws {
        let slack = FakeSlackInbox()
        slack.with { $0.fullThreadError = IntegrationError.missingPermission(.slack, "channels:history") }
        var item = Sample.slack(Sample.threadReplyID, threadTS: Sample.parentTS)
        item.content = MessageContent(text: "Can you send the Q3 numbers?", markup: "Can you send the *Q3 numbers*?", attachments: [Sample.deck],
                                      fetchedAt: Date())
        let (integrations, _) = try make(slackFile([item, Sample.slack(Sample.topID)]), slack: slack)

        let alone = try await integrations.fullThread(for: item.id, reload: false)
        guard case .slack(let messages, let highlighted) = alone else { return XCTFail("a Slack thread") }
        XCTAssertEqual(messages.map(\.id), [Sample.replyTS], "the message itself, as Docket kept it")
        XCTAssertEqual(messages.first?.markup, "Can you send the *Q3 numbers*?")
        XCTAssertEqual(messages.first?.files, [Sample.deck])
        XCTAssertEqual(highlighted, 0)
        XCTAssertEqual(integrations.missingSlackScopes, ["channels:history"], "the views offer to update the app")
        XCTAssertNil(integrations.wholeThreads[item.id], "not kept: once the app is updated, it's asked again")

        // Updated: the thread comes.
        slack.with {
            $0.fullThreadError = nil
            $0.fullThreadAnswers = [Sample.leadership]
        }
        let whole = try await integrations.fullThread(for: item.id, reload: false)
        XCTAssertEqual(whole.allMessageIDs.count, 4)
        XCTAssertEqual(slack.fullThreadCalls.count, 2)

        // When Slack listed the token's permissions and there's no history among them, it isn't asked at all.
        integrations.grantedSlackScopes = Set(Sample.olderScopes)
        let other = try await integrations.fullThread(for: Sample.topID, reload: false)
        XCTAssertEqual(other.allMessageIDs, [Sample.topTS])
        XCTAssertEqual(slack.fullThreadCalls.count, 2)

        // Anything else is an error, in plain words.
        integrations.grantedSlackScopes = nil
        slack.with { $0.fullThreadError = IntegrationError.api(.slack, "That message isn't in Slack any more.") }
        do {
            _ = try await integrations.fullThread(for: Sample.topID, reload: true)
            XCTFail("gone")
        } catch {
            XCTAssertEqual(error as? IntegrationError, .api(.slack, "That message isn't in Slack any more."))
        }
    }

    func testAWholeEmailConversationBringsTheEmailWithIt() async throws {
        let gmail = FakeMailInbox(full: Sample.fullEmail)
        gmail.with { $0.emails = [Sample.redlines] }
        var item = Sample.email()
        item.receivedAt = Sample.redlines[1].date
        let (integrations, store) = try make(gmailFile([item]), gmail: gmail)

        let thread = try await integrations.fullThread(for: Sample.emailID, reload: false)
        guard case .email(let emails, let highlighted) = thread else { return XCTFail("an email conversation") }
        XCTAssertEqual(emails.map(\.id), ["m0", "m1", "m2"])
        XCTAssertEqual(highlighted, 1)
        XCTAssertEqual(gmail.wholeCalls, ["t1"])

        // What opening the email and replying to it need came along: nothing more is fetched, now or next launch.
        XCTAssertEqual(integrations.suggestion(Sample.emailID)?.replyHeaders, Sample.headers)
        let content = try await integrations.content(for: Sample.emailID)
        XCTAssertEqual(content, Sample.fullEmail.content)
        XCTAssertTrue(gmail.fetched.isEmpty)
        integrations.flushSaves()
        XCTAssertEqual(relaunch(store).suggestion(Sample.emailID)?.replyHeaders, Sample.headers)
        XCTAssertNil(relaunch(store).wholeThreads[Sample.emailID], "threads aren't saved")

        // An email no longer in its conversation (deleted since) still shows, in its place.
        gmail.with { $0.emails = [[Sample.redlines[0], Sample.redlines[2]]] }
        let without = try await integrations.fullThread(for: Sample.emailID, reload: true)
        XCTAssertEqual(without.allMessageIDs, ["m0", "m1", "m2"])
        XCTAssertEqual(without.highlightedIndex, 1)

        // Offline: an error in plain words, and what was loaded stays.
        gmail.with { $0.wholeError = IntegrationError.offline(.gmail, "You seem to be offline.") }
        do {
            _ = try await integrations.fullThread(for: Sample.emailID, reload: true)
            XCTFail("offline")
        } catch {
            XCTAssertEqual(error as? IntegrationError, .offline(.gmail, "You seem to be offline."))
        }
        XCTAssertEqual(integrations.wholeThreads[Sample.emailID]?.allMessageIDs, ["m0", "m1", "m2"])
    }

    func testTheItemsOwnMessageIsPlacedByTimeWhenTheThreadLeavesItOut() {
        let own = Sample.post(Sample.replyTS, nil, "Priya Shah", "Can you send the Q3 numbers?")
        let others = Sample.leadership.filter { $0.id != Sample.replyTS }
        let (slack, slackHasOwn) = Integrations.slackThread(others, own: own)
        XCTAssertFalse(slackHasOwn)
        XCTAssertEqual(slack.allMessageIDs, [Sample.parentTS, "1791199500.000070", Sample.replyTS, Sample.jordanTS])
        XCTAssertEqual(slack.highlightedIndex, 2)
        // The same ts written another way is the same message.
        let (same, sameHasOwn) = Integrations.slackThread([Sample.post("1791200000.0001", "U0PRIYA", "Priya Shah", "Can you…")], own: own)
        XCTAssertTrue(sameHasOwn)
        XCTAssertEqual(same.highlightedIndex, 0)
        XCTAssertTrue(InboxThread.sameSlackMessage("slack:C0LEAD/\(Sample.replyTS)", "1791200000.0001"))
        XCTAssertFalse(InboxThread.sameSlackMessage(Sample.replyTS, Sample.parentTS))

        let (email, emailHasOwn) = Integrations.emailThread([Sample.redlines[2]], own: Sample.redlines[1])
        XCTAssertFalse(emailHasOwn)
        XCTAssertEqual(email.allMessageIDs, ["m1", "m2"])
        XCTAssertEqual(email.highlightedIndex, 0)
    }

    // MARK: Replying to one message

    func testAnEmailReplyAnswersThePickedEmailOrTheNewestNotFromYou() async throws {
        let gmail = FakeMailInbox(full: Sample.fullEmail)
        gmail.with { $0.emails = [Sample.redlines] }
        let app = AppState()
        let (integrations, _) = try make(gmailFile([Sample.email()], canModify: true), gmail: gmail, app: app)
        let id = Sample.emailID
        XCTAssertNil(integrations.defaultReplyTarget(for: id), "not before the conversation is in")
        XCTAssertEqual(integrations.replyHeaders(for: id, replyingTo: nil), nil, "nor the item's own headers, until it's opened")

        _ = try await integrations.fullThread(for: id, reload: false)
        let lena = Sample.redlines[2].replyHeaders
        XCTAssertEqual(integrations.defaultReplyTarget(for: id), "m2", "the newest that isn't yours")
        XCTAssertEqual(integrations.replyHeaders(for: id, replyingTo: nil), lena, "what the confirmation shows")
        XCTAssertEqual(integrations.replyHeaders(for: id, replyingTo: "m0")?.messageID, "<m0@mail.example>")

        // The default one: Lena's email, its Message-ID and its people.
        try await integrations.sendReply("Friday works for both of us.", for: id, replyingTo: nil, replyAll: true)
        XCTAssertEqual(gmail.sent.last, MailReply(threadID: "t1", headers: lena, fromAddress: Sample.address,
                                                  body: "Friday works for both of us.", replyAll: true))
        XCTAssertEqual(app.toast, "Reply sent")

        // One picked in the conversation (by its id, or as the views name it).
        try await integrations.sendReply("Thanks, Sam.", for: id, replyingTo: "m1", replyAll: false)
        XCTAssertEqual(gmail.sent.last?.headers, Sample.headers)
        try await integrations.saveReplyAsDraft("Following up on the draft.", for: id, replyingTo: "gmail:t1/m0", replyAll: false)
        XCTAssertEqual(gmail.drafts.last?.headers.messageID, "<m0@mail.example>")
        XCTAssertEqual(gmail.drafts.last?.threadID, "t1")

        // One that isn't in the conversation never goes anywhere.
        do {
            try await integrations.sendReply("Hello?", for: id, replyingTo: "m9", replyAll: false)
            XCTFail("no such email")
        } catch {
            XCTAssertEqual(error as? IntegrationError, .api(.gmail, "That email isn't in the conversation any more. Reply to another one."))
        }
        XCTAssertEqual(gmail.sent.count, 2)
        await integrations.waitForThreadRechecks()
    }

    func testASlackReplyToAnyMessageGoesInTheThreadAndShowsThereAtOnce() async throws {
        let slack = FakeSlackInbox()
        let app = AppState()
        let sentTS = String(format: "%.6f", Date().timeIntervalSince1970)
        // Before the reply, then the same thread with the reply as Slack has it.
        slack.with {
            $0.fullThreadAnswers = [Sample.leadership, Sample.leadership + [Sample.post(sentTS, "U0MAYA", "Maya Chen", "On it", mine: true)]]
        }
        // Saved before Docket knew it's a reply in a thread: the thread says which.
        let (integrations, _) = try make(slackFile([Sample.slack(Sample.threadReplyID)]), slack: slack, app: app)
        let id = Sample.threadReplyID
        _ = try await integrations.fullThread(for: id, reload: false)

        try await integrations.sendReply("On it", for: id, replyingTo: Sample.jordanTS, replyAll: false)
        XCTAssertEqual(slack.replies, [.init(channel: "C0LEAD", threadTS: Sample.parentTS, text: "On it")],
                       "in the thread, whichever of its messages it answers")
        XCTAssertEqual(app.toast, "Replied in #leadership")

        // In the thread at once, as yours.
        guard case .slack(let shown, _)? = integrations.wholeThreads[id] else { return XCTFail("a Slack thread") }
        let mine = try XCTUnwrap(shown.last)
        XCTAssertEqual(mine.text, "On it")
        XCTAssertTrue(mine.isMine)
        XCTAssertTrue(InboxThread.isSentFromDocket(mine.id))
        XCTAssertEqual(shown.count, 5)

        // Then as Slack has it, once it's fetched again.
        await integrations.waitForThreadRechecks()
        guard case .slack(let confirmed, _)? = integrations.wholeThreads[id] else { return XCTFail("a Slack thread") }
        XCTAssertEqual(confirmed.map(\.id), Sample.leadership.map(\.id) + [sentTS])
        XCTAssertEqual(slack.fullThreadCalls.count, 2)

        // A sent reply Slack doesn't list yet stays at the end until it does.
        try await integrations.sendReply("Also, the deck is attached above.", for: id, replyingTo: nil, replyAll: false)
        await integrations.waitForThreadRechecks()
        guard case .slack(let waiting, _)? = integrations.wholeThreads[id] else { return XCTFail("a Slack thread") }
        XCTAssertEqual(waiting.count, 6)
        XCTAssertEqual(waiting.last?.text, "Also, the deck is attached above.")
        XCTAssertEqual(slack.replies.last?.threadTS, Sample.parentTS)
    }

    func testASentReplyWaitsInTheThreadUntilSlackOrGmailListsIt() {
        func mine(_ ts: String, _ text: String) -> ThreadSlackMessage { Sample.post(ts, "U0MAYA", "Maya Chen", text, mine: true) }
        let shown = Set(Sample.leadership.map(\.id))
        let first = SentFromDocket(message: .slack(mine(InboxThread.newSentFromDocketID(), "On it")), before: shown)
        let second = SentFromDocket(message: .slack(mine(InboxThread.newSentFromDocketID(), "Also, the *deck* is attached.")), before: shown)
        let onIt = mine("1791201000.000100", "On it")

        // Not listed yet: both wait.
        XCTAssertEqual(SentFromDocket.unlisted([first, second], in: .slack(Sample.leadership, highlighted: 2)).count, 2)
        // The first is listed: only the second waits, however soon after it went.
        XCTAssertEqual(SentFromDocket.unlisted([first, second], in: .slack(Sample.leadership + [onIt], highlighted: 2)).map(\.words),
                       [second.words])
        // Listed the way Slack keeps it (formatting gone): the same words. Out of order too.
        let deck = mine("1791201100.000100", "Also, the deck is attached.")
        XCTAssertTrue(SentFromDocket.unlisted([first, second], in: .slack(Sample.leadership + [deck, onIt], highlighted: 2)).isEmpty)

        // A message that was already there when a reply went is never that reply.
        let later = SentFromDocket(message: .slack(mine(InboxThread.newSentFromDocketID(), "Thanks")), before: shown.union([onIt.id]))
        XCTAssertEqual(SentFromDocket.unlisted([later], in: .slack(Sample.leadership + [onIt], highlighted: 2)).count, 1)
        // Listed in other words (an email with its quoted history, say): a new message of yours is still that reply.
        let quoted = mine("1791201200.000100", "Thanks!\n> On it")
        XCTAssertTrue(SentFromDocket.unlisted([later], in: .slack(Sample.leadership + [onIt, quoted], highlighted: 2)).isEmpty)
        XCTAssertEqual(SentFromDocket.words("Re: *Q3* numbers — 10:42!"), "req3numbers1042")
    }

    func testAnEmailReplyShowsInItsConversationAtOnceUntilGmailListsIt() async throws {
        let gmail = FakeMailInbox(full: Sample.fullEmail)
        let sent = Sample.mail("m3", from: "Maya Chen", "maya@acme.example", at: Date().timeIntervalSince1970, text: "Friday works.", mine: true,
                               to: ["Lena Park <lena@acme.example>"])
        gmail.with { $0.emails = [Sample.redlines, Sample.redlines + [sent]] }
        let (integrations, _) = try make(gmailFile([Sample.email()], canModify: true), gmail: gmail)
        _ = try await integrations.fullThread(for: Sample.emailID, reload: false)

        try await integrations.sendReply("Friday works.", for: Sample.emailID, replyingTo: "m2", replyAll: false)
        guard case .email(let shown, let highlighted)? = integrations.wholeThreads[Sample.emailID] else { return XCTFail("an email conversation") }
        XCTAssertEqual(highlighted, 1)
        let reply = try XCTUnwrap(shown.last)
        XCTAssertTrue(reply.isMine)
        XCTAssertEqual(reply.content.text, "Friday works.")
        XCTAssertEqual(reply.content.to, ["Lena Park <lena@acme.example>"], "to whom it went")
        XCTAssertEqual(reply.replyHeaders.subject, "Re: Contract redlines")
        XCTAssertEqual(integrations.defaultReplyTarget(for: Sample.emailID), "m2", "a reply of yours is never the one to answer")

        await integrations.waitForThreadRechecks()
        XCTAssertEqual(integrations.wholeThreads[Sample.emailID]?.allMessageIDs, ["m0", "m1", "m2", "m3"])
    }

    // MARK: Stars

    func testStarredItemsComeFirstAndTheStarredFilterShowsOnlyThem() throws {
        let (integrations, _) = try make()
        var pinned = Sample.slack("slack:C0LEAD/2", minutesAgo: 50)
        pinned.isStarred = true
        var older = Sample.slack("slack:C0LEAD/3", minutesAgo: 90)
        older.isStarred = true
        var mail = Sample.email("gmail:t1/m1", minutesAgo: 30)
        mail.isStarred = true
        integrations.suggestions = [Sample.slack("slack:C0LEAD/1", minutesAgo: 5), pinned, mail, older, Sample.slack("slack:D0DM/4", minutesAgo: 1),
                                    Sample.email("gmail:t2/m2", minutesAgo: 2)]
        XCTAssertEqual(integrations.items(.slack).map(\.id), ["slack:C0LEAD/2", "slack:C0LEAD/3", "slack:D0DM/4", "slack:C0LEAD/1"],
                       "starred first, each part newest first")
        XCTAssertEqual(integrations.items(.slack, starredOnly: true).map(\.id), ["slack:C0LEAD/2", "slack:C0LEAD/3"])
        XCTAssertEqual(integrations.items(.gmail).map(\.id), ["gmail:t1/m1", "gmail:t2/m2"])
        XCTAssertEqual(integrations.items(.gmail, starredOnly: true).map(\.id), ["gmail:t1/m1"])
        XCTAssertTrue(integrations.items(.ai, starredOnly: true).isEmpty)
        // All: both together, by the same rule.
        XCTAssertEqual(integrations.allItems().map(\.id),
                       ["gmail:t1/m1", "slack:C0LEAD/2", "slack:C0LEAD/3", "slack:D0DM/4", "gmail:t2/m2", "slack:C0LEAD/1"])
        XCTAssertEqual(integrations.allItems(starredOnly: true).map(\.id), ["gmail:t1/m1", "slack:C0LEAD/2", "slack:C0LEAD/3"])
    }

    func testAStarShowsAtOnceReachesGmailAndIsSaved() async throws {
        let gmail = FakeMailInbox(full: Sample.fullEmail)
        gmail.with {
            $0.emails = [Sample.redlines]
            $0.delay = 0.2
        }
        let (integrations, store) = try make(gmailFile([Sample.email(), Sample.email("gmail:t2/m2", minutesAgo: 5)], canModify: true), gmail: gmail)
        _ = try await integrations.fullThread(for: Sample.emailID, reload: false)
        XCTAssertEqual(integrations.items(.gmail).map(\.id), ["gmail:t2/m2", Sample.emailID])

        let starring = Task { await integrations.setStarred(true, for: Sample.emailID) }
        try await Task.sleep(nanoseconds: 60_000_000)
        XCTAssertEqual(integrations.suggestion(Sample.emailID)?.isStarred, true, "at once, before Gmail answers")
        XCTAssertEqual(integrations.items(.gmail).first?.id, Sample.emailID, "and first in its tab")
        guard case .email(let shown, _)? = integrations.wholeThreads[Sample.emailID] else { return XCTFail("an email conversation") }
        XCTAssertEqual(shown[1].isStarred, true, "the conversation shows it too")
        XCTAssertTrue(gmail.starCalls.isEmpty, "Gmail hasn't answered yet")
        await starring.value
        XCTAssertEqual(gmail.starCalls, [.init(starred: true, messageID: "m1")], "the STARRED label on its own message")
        XCTAssertNil(integrations.starProblem(for: Sample.emailID))
        XCTAssertTrue(integrations.isStarred(message: nil, in: Sample.emailID))

        // Saved: still starred next launch.
        integrations.flushSaves()
        XCTAssertEqual(relaunch(store).suggestion(Sample.emailID)?.isStarred, true)

        // Unstarred: Gmail too, and it stays in the inbox.
        gmail.with { $0.delay = 0 }
        await integrations.setStarred(false, for: Sample.emailID)
        XCTAssertEqual(gmail.starCalls.last, .init(starred: false, messageID: "m1"))
        XCTAssertEqual(integrations.suggestion(Sample.emailID)?.isStarred, false)

        // Asking for what it is already does nothing.
        await integrations.setStarred(false, for: Sample.emailID)
        XCTAssertEqual(gmail.starCalls.count, 2)
    }

    func testAStarThatDoesntTakeGoesBackAndSaysWhy() async throws {
        let gmail = FakeMailInbox(full: Sample.fullEmail)
        gmail.with { $0.starError = IntegrationError.offline(.gmail, "You seem to be offline.") }
        let (integrations, store) = try make(gmailFile([Sample.email()], canModify: true), gmail: gmail)

        await integrations.setStarred(true, for: Sample.emailID)
        XCTAssertEqual(integrations.suggestion(Sample.emailID)?.isStarred, false, "put back")
        XCTAssertEqual(integrations.starProblem(for: Sample.emailID), "Couldn't reach Gmail. You seem to be offline.")
        integrations.flushSaves()
        XCTAssertEqual(relaunch(store).suggestion(Sample.emailID)?.isStarred, false)

        // The next try clears it.
        gmail.with { $0.starError = nil }
        await integrations.setStarred(true, for: Sample.emailID)
        XCTAssertNil(integrations.starProblem(for: Sample.emailID))
        XCTAssertEqual(integrations.suggestion(Sample.emailID)?.isStarred, true)

        // Slack too: a message deleted there can't be saved for later.
        let slack = FakeSlackInbox()
        slack.with { $0.starError = IntegrationError.api(.slack, "That message isn't in Slack any more.") }
        let (other, _) = try make(slackFile([Sample.slack(Sample.topID)], scopes: SlackManifest.userScopes), slack: slack)
        await other.setStarred(true, for: Sample.topID)
        XCTAssertEqual(slack.starCalls, [.init(starred: true, channel: "C0LEAD", ts: Sample.topTS)])
        XCTAssertEqual(other.suggestion(Sample.topID)?.isStarred, false)
        XCTAssertEqual(other.starProblem(for: Sample.topID), "Couldn't star it in Slack. That message isn't in Slack any more.")
        XCTAssertFalse(other.slackStarsStayInDocket)
    }

    func testQuickChangesReachGmailInOrderAndEndAsTheUserLeftThem() async throws {
        let gmail = FakeMailInbox(full: Sample.fullEmail)
        gmail.with { $0.delay = 0.1 }
        let (integrations, _) = try make(gmailFile([Sample.email()], canModify: true), gmail: gmail)

        let first = Task { await integrations.setStarred(true, for: Sample.emailID) }
        try await Task.sleep(nanoseconds: 30_000_000)
        // Unstarred while the star is on its way, then starred and unstarred again: Gmail ends unstarred too.
        await integrations.setStarred(false, for: Sample.emailID)
        await first.value
        XCTAssertEqual(gmail.starCalls, [.init(starred: true, messageID: "m1"), .init(starred: false, messageID: "m1")])
        XCTAssertEqual(integrations.suggestion(Sample.emailID)?.isStarred, false)

        let again = Task { await integrations.setStarred(true, for: Sample.emailID) }
        try await Task.sleep(nanoseconds: 30_000_000)
        let off = Task { await integrations.setStarred(false, for: Sample.emailID) }
        try await Task.sleep(nanoseconds: 10_000_000)
        let on = Task { await integrations.setStarred(true, for: Sample.emailID) }
        _ = await (again.value, off.value, on.value)
        XCTAssertEqual(integrations.suggestion(Sample.emailID)?.isStarred, true)
        XCTAssertEqual(gmail.starCalls.last, .init(starred: true, messageID: "m1"), "what Gmail heard last is what Docket shows")
    }

    func testSlackThatWontSaveForLaterKeepsTheStarInDocketAndSaysSoOnce() async throws {
        let slack = FakeSlackInbox()
        // What SlackClient throws when Slack retired stars for the app (method_deprecated) or doesn't allow them.
        slack.with { $0.starError = IntegrationError.api(.slack, "Saved in Docket only (Slack didn't allow saving it there)") }
        let app = AppState()
        let other = "slack:C0LEAD/1791203700.000300"
        let (integrations, store) = try make(slackFile([Sample.slack(Sample.topID), Sample.slack(other)], scopes: SlackManifest.userScopes),
                                             slack: slack, app: app)

        await integrations.setStarred(true, for: Sample.topID)
        XCTAssertEqual(integrations.suggestion(Sample.topID)?.isStarred, true, "kept in Docket")
        XCTAssertNil(integrations.starProblem(for: Sample.topID))
        XCTAssertEqual(app.toast, "Saved in Docket only (Slack didn't allow saving it there)")
        XCTAssertTrue(integrations.slackStarsStayInDocket)

        // From then on Slack isn't asked, and it isn't said again, also after a relaunch.
        app.toast = nil
        await integrations.setStarred(true, for: other)
        XCTAssertEqual(integrations.suggestion(other)?.isStarred, true)
        XCTAssertEqual(slack.starCalls.count, 1)
        XCTAssertNil(app.toast)
        integrations.flushSaves()
        XCTAssertTrue(relaunch(store).slackStarsStayInDocket)

        // Slack's own words for it count the same way; connecting Slack again asks again.
        XCTAssertTrue(InboxStarRules.slackDeclined(.api(.slack, "Slack said “method_deprecated”.")))
        XCTAssertTrue(InboxStarRules.slackDeclined(.api(.slack, "Slack said “not_allowed”.")))
        XCTAssertTrue(InboxStarRules.slackDeclined(.missingPermission(.slack, "stars:write")))
        XCTAssertFalse(InboxStarRules.slackDeclined(.api(.slack, "That message isn't in Slack any more.")))
        XCTAssertFalse(InboxStarRules.slackDeclined(.offline(.slack, "You seem to be offline.")))
        integrations.disconnectSlack(problem: "Slack no longer accepts Docket's token.")
        XCTAssertFalse(integrations.slackStarsStayInDocket)

        // An app made before stars (no stars:write): Slack isn't asked, and Docket says so once.
        let older = FakeSlackInbox()
        let olderApp = AppState()
        let (before, _) = try make(slackFile([Sample.slack(Sample.topID)], scopes: Sample.olderScopes), slack: older, app: olderApp)
        await before.setStarred(true, for: Sample.topID)
        XCTAssertEqual(before.suggestion(Sample.topID)?.isStarred, true)
        XCTAssertTrue(older.starCalls.isEmpty)
        XCTAssertEqual(olderApp.toast, InboxStarRules.slackNote)
        XCTAssertEqual(IntegrationError.missingPermission(.slack, "stars:write").errorDescription,
                       "Docket needs one more Slack permission to save messages for later in Slack. Update the Docket app in Settings → Connections.")
    }

    func testASlackAppGivenThePermissionToSaveForLaterIsAskedAgain() async throws {
        let server = FakeIntegrationServer()
        server.on({ $0.url?.host == "slack.com" && $0.url?.path == "/api/auth.test" },
                  [.init(body: Sample.authTest, headers: ["x-oauth-scopes": SlackManifest.userScopes.joined(separator: ",")])])
        let slack = FakeSlackInbox()
        let (integrations, _) = try make(slackFile([Sample.slack(Sample.topID)], scopes: Sample.olderScopes), slack: slack,
                                         transport: server.transport)
        await integrations.setStarred(true, for: Sample.topID)
        XCTAssertTrue(integrations.slackStarsStayInDocket, "an app made before stars")
        XCTAssertTrue(slack.starCalls.isEmpty)

        // The app in Slack was given stars:write: the next star goes to Slack.
        await integrations.checkSlackPermissions()
        XCTAssertFalse(integrations.slackStarsStayInDocket)
        await integrations.setStarred(false, for: Sample.topID)
        XCTAssertEqual(slack.starCalls, [.init(starred: false, channel: "C0LEAD", ts: Sample.topTS)])
    }

    func testWithoutTheGmailStarPermissionAStarStaysInDocket() async throws {
        let gmail = FakeMailInbox(full: Sample.fullEmail)
        let app = AppState()
        // Signed in before Docket asked for gmail.modify.
        let (integrations, _) = try make(gmailFile([Sample.email(), Sample.email("gmail:t2/m2")]), gmail: gmail, app: app)
        XCTAssertFalse(integrations.gmailCanModify)

        await integrations.setStarred(true, for: Sample.emailID)
        XCTAssertEqual(integrations.suggestion(Sample.emailID)?.isStarred, true)
        XCTAssertTrue(gmail.starCalls.isEmpty)
        XCTAssertEqual(app.toast, "Starred in Docket only (reconnect Gmail to star it there too)")
        app.toast = nil
        await integrations.setStarred(true, for: "gmail:t2/m2")
        XCTAssertNil(app.toast, "said once")
        // Taken off in Docket only: said in those words (once too).
        await integrations.setStarred(false, for: "gmail:t2/m2")
        XCTAssertEqual(integrations.suggestion("gmail:t2/m2")?.isStarred, false)
        XCTAssertEqual(app.toast, "Unstarred in Docket only (reconnect Gmail to change it there too)")

        // Signed in with it, but Google turns it down after all: kept here, and Docket stops asking.
        integrations.grantedGmailScopes = ["openid", "email", GoogleOAuth.modifyScope]
        gmail.with { $0.starError = IntegrationError.missingPermission(.gmail, "star emails") }
        await integrations.setStarred(false, for: Sample.emailID)
        XCTAssertEqual(integrations.suggestion(Sample.emailID)?.isStarred, false)
        XCTAssertEqual(gmail.starCalls, [.init(starred: false, messageID: "m1")])
        XCTAssertFalse(integrations.gmailCanModify)
        XCTAssertNil(integrations.starProblem(for: Sample.emailID))
    }

    func testMessagesOfAThreadHaveTheirOwnStars() async throws {
        let slack = FakeSlackInbox()
        slack.with { $0.fullThreadAnswers = [Sample.leadership] }
        let jordan = "slack:C0LEAD/\(Sample.jordanTS)"
        let id = Sample.threadReplyID
        let (integrations, store) = try make(slackFile([Sample.slack(id, threadTS: Sample.parentTS), Sample.slack(jordan, threadTS: Sample.parentTS)],
                                                       scopes: SlackManifest.userScopes), slack: slack)
        _ = try await integrations.fullThread(for: id, reload: false)

        // Slack: saved for later there, and kept in Docket (Slack doesn't say which messages are saved).
        await integrations.setStarred(true, message: Sample.parentTS, in: id)
        XCTAssertTrue(integrations.isStarred(message: Sample.parentTS, in: id))
        XCTAssertEqual(slack.starCalls, [.init(starred: true, channel: "C0LEAD", ts: Sample.parentTS)])
        XCTAssertEqual(integrations.suggestion(id)?.starredInThread, [Sample.parentTS])
        XCTAssertFalse(integrations.suggestion(id)?.isStarred ?? true, "the item's own star is its own")
        XCTAssertTrue(integrations.isStarred(message: Sample.parentTS, in: jordan), "the same message seen from another item of the thread")
        integrations.flushSaves()
        XCTAssertTrue(relaunch(store).isStarred(message: Sample.parentTS, in: id), "kept across launches")

        // As the views name it ("slack:<channel>/<ts>"): the same star.
        await integrations.setStarred(false, for: "slack:C0LEAD/\(Sample.parentTS)")
        XCTAssertFalse(integrations.isStarred(message: Sample.parentTS, in: id))
        XCTAssertEqual(slack.starCalls.last, .init(starred: false, channel: "C0LEAD", ts: Sample.parentTS))

        // A message that's an inbox item itself is that item's star; the item's own message is the item's.
        await integrations.setStarred(true, message: Sample.jordanTS, in: id)
        XCTAssertEqual(integrations.suggestion(jordan)?.isStarred, true)
        XCTAssertTrue(integrations.isStarred(message: "slack:C0LEAD/\(Sample.jordanTS)", in: id))
        await integrations.setStarred(true, message: Sample.replyTS, in: id)
        XCTAssertEqual(integrations.suggestion(id)?.isStarred, true)

        // Email: Gmail's label on that email, shown in the conversation at once; put back when it doesn't take.
        let gmail = FakeMailInbox(full: Sample.fullEmail)
        gmail.with { $0.emails = [Sample.redlines] }
        let (mail, _) = try make(gmailFile([Sample.email()], canModify: true), gmail: gmail)
        _ = try await mail.fullThread(for: Sample.emailID, reload: false)
        await mail.setStarred(true, message: "m2", in: Sample.emailID)
        XCTAssertEqual(gmail.starCalls, [.init(starred: true, messageID: "m2")])
        XCTAssertTrue(mail.isStarred(message: "m2", in: Sample.emailID))
        guard case .email(let emails, _)? = mail.wholeThreads[Sample.emailID] else { return XCTFail("an email conversation") }
        XCTAssertEqual(emails.map(\.isStarred), [false, false, true])
        XCTAssertFalse(mail.suggestion(Sample.emailID)?.isStarred ?? true)

        gmail.with { $0.starError = IntegrationError.offline(.gmail, "You seem to be offline.") }
        await mail.setStarred(false, message: "gmail:t1/m2", in: Sample.emailID)
        XCTAssertTrue(mail.isStarred(message: "m2", in: Sample.emailID), "put back")
        XCTAssertEqual(mail.starProblem(for: Sample.emailID, message: "m2"), "Couldn't reach Gmail. You seem to be offline.")
        XCTAssertNil(mail.starProblem(for: Sample.emailID))

        // A star on its way survives the conversation being fetched again meanwhile.
        gmail.with {
            $0.starError = nil
            $0.delay = 0.1
        }
        let unstarring = Task { await mail.setStarred(false, message: "m2", in: Sample.emailID) }
        try await Task.sleep(nanoseconds: 20_000_000)
        gmail.with { $0.delay = 0 }
        _ = try await mail.fullThread(for: Sample.emailID, reload: true)
        XCTAssertFalse(mail.isStarred(message: "m2", in: Sample.emailID))
        await unstarring.value
        guard case .email(let after, _)? = mail.wholeThreads[Sample.emailID] else { return XCTFail("an email conversation") }
        XCTAssertEqual(after.map(\.isStarred), [false, false, false])
    }

    func testGmailMessagesArriveStarredWhenGmailHasThemStarred() async throws {
        let server = FakeIntegrationServer()
        let now = Date()
        func list(_ refs: [(String, String)]) -> String {
            #"{"messages":["# + refs.map { #"{"id":"\#($0.0)","threadId":"\#($0.1)"}"# }.joined(separator: ",") + "]}"
        }
        func email(_ id: String, thread: String, labels: [String], minutesAgo: Double) -> String {
            let labels = labels.map { "\"\($0)\"" }.joined(separator: ",")
            return """
            {"id":"\(id)","threadId":"\(thread)","labelIds":[\(labels)],"snippet":"Can you review this?",
             "internalDate":"\(Int64(now.addingTimeInterval(-minutesAgo * 60).timeIntervalSince1970 * 1000))",
             "payload":{"headers":[{"name":"From","value":"Sam Lee <sam@northwind.example>"},{"name":"Subject","value":"Q3 numbers \(id)"}]}}
            """
        }
        server.google("/token", .init(body: #"{"access_token":"ya29.test-access","expires_in":3599,"scope":"openid email https://www.googleapis.com/auth/gmail.modify","token_type":"Bearer"}"#))
        server.gmail("messages", query: GmailClient.starredQuery, list([("m1", "t1")]))
        server.gmail("messages", query: GmailClient.needsReplyQuery, list([("m2", "t2"), ("m3", "t3")]))
        server.gmail("messages/m1", email("m1", thread: "t1", labels: ["INBOX", "STARRED"], minutesAgo: 30))
        server.gmail("messages/m2", email("m2", thread: "t2", labels: ["INBOX", "UNREAD", "IMPORTANT", "STARRED"], minutesAgo: 20))
        server.gmail("messages/m3", email("m3", thread: "t3", labels: ["INBOX", "UNREAD", "IMPORTANT"], minutesAgo: 10))
        let (integrations, _) = try make(gmailFile(), transport: server.transport)

        await integrations.refreshNow(now: now)
        XCTAssertNil(integrations.gmailProblem)
        XCTAssertEqual(integrations.items(.gmail).map(\.id), ["gmail:t2/m2", "gmail:t1/m1", "gmail:t3/m3"])
        XCTAssertEqual(integrations.items(.gmail, starredOnly: true).map(\.id), ["gmail:t2/m2", "gmail:t1/m1"])
        XCTAssertEqual(integrations.suggestion("gmail:t2/m2")?.trigger, .needsReply, "waiting for a reply, and starred in Gmail")
        XCTAssertTrue(integrations.gmailCanModify, "Google said the sign-in allows starring")
    }

    func testSavedFilesKeepStarsAndOlderOnesLoadStarredEmailsAsStarred() throws {
        // Saved before stars: an email that came in because it was starred in Gmail is starred.
        let before = #"""
        {"version": 2, "suggestions": [
          {"source": {"kind": "gmail", "externalID": "gmail:t1/m1", "label": "Sam Lee · Contract redlines"},
           "from": "Sam Lee", "snippet": "Attached are the redlines.", "receivedAt": "2026-10-05T09:12:00Z", "trigger": "starred"},
          {"source": {"kind": "gmail", "externalID": "gmail:t2/m2", "label": "Dana Whitfield · Intro"},
           "from": "Dana Whitfield", "snippet": "Are you free?", "receivedAt": "2026-10-05T08:00:00Z", "trigger": "needsReply"},
          {"source": {"kind": "slack", "externalID": "slack:C0LEAD/1791200000.000100", "label": "#leadership · Priya Shah"},
           "from": "Priya Shah", "snippet": "Can you approve the Q4 budget?", "receivedAt": "2026-10-05T09:12:00Z", "trigger": "reaction"}]}
        """#
        let file = try Persistence.decoder.decode(IntegrationsFile.self, from: Data(before.utf8))
        XCTAssertEqual(file.suggestions.map(\.isStarred), [true, false, false])
        XCTAssertTrue(file.suggestions.allSatisfy { $0.starredInThread.isEmpty })
        XCTAssertFalse(file.slackStarsStayInDocket)

        // Stars come back as they were saved, unstarred ones too.
        var saved = file
        saved.suggestions[0].isStarred = false
        saved.suggestions[2].isStarred = true
        saved.suggestions[2].starredInThread = ["1791199000.000050"]
        saved.slackStarsStayInDocket = true
        let again = try Persistence.decoder.decode(IntegrationsFile.self, from: saved.encoded())
        XCTAssertEqual(again.suggestions, saved.suggestions)
        XCTAssertEqual(again.suggestions.map(\.isStarred), [false, false, true])
        XCTAssertTrue(again.slackStarsStayInDocket)
    }

    // MARK: Gmail permissions

    func testReplyingAndStarringFollowTheGmailPermissions() async throws {
        let (integrations, _) = try make(gmailFile(canModify: true))
        XCTAssertTrue(integrations.gmailCanCompose, "gmail.modify covers sending and drafts")
        XCTAssertTrue(integrations.gmailCanModify)
        integrations.grantedGmailScopes = [GoogleOAuth.gmailScope, GoogleOAuth.composeScope]
        XCTAssertTrue(integrations.gmailCanCompose)
        XCTAssertFalse(integrations.gmailCanModify, "a sign-in from before stars")
        integrations.grantedGmailScopes = [GoogleOAuth.gmailScope]
        XCTAssertFalse(integrations.gmailCanCompose)

        XCTAssertTrue(Integrations.canReadMail(granted: ["openid", "email", GoogleOAuth.modifyScope]), "what Docket asks for now")
        XCTAssertTrue(Integrations.canReadMail(granted: [GoogleOAuth.gmailScope]))
        XCTAssertTrue(Integrations.canReadMail(granted: []), "Google didn't list them: what Docket asked for")
        XCTAssertFalse(Integrations.canReadMail(granted: ["openid", "email", GoogleOAuth.composeScope]))

        // A sign-in that turns out to allow more: Docket notes it.
        let session = GoogleSession(client: GoogleOAuth.Client(id: "1234-test.apps.googleusercontent.com", secret: "test-client-secret"),
                                    refreshToken: "1//test-refresh", transport: Sample.offline,
                                    tokens: GoogleOAuth.Tokens(accessToken: "ya29.test", expiresAt: Date().addingTimeInterval(3600),
                                                               refreshToken: nil, scopes: ["openid", GoogleOAuth.modifyScope]))
        await integrations.noteGmailGrants(session)
        XCTAssertTrue(integrations.gmailCanModify)
        XCTAssertEqual(integrations.grantedGmailScopes, [GoogleOAuth.gmailScope, GoogleOAuth.modifyScope])

        // Google turning a send down takes both away, so the views ask to reconnect.
        let gmail = FakeMailInbox(full: Sample.fullEmail)
        gmail.with { $0.sendError = IntegrationError.missingPermission(.gmail, "send replies and save drafts") }
        let (other, _) = try make(gmailFile([Sample.email()], canModify: true), gmail: gmail)
        do {
            try await other.sendReply("Thanks", for: Sample.emailID, replyAll: false)
            XCTFail("Google said no")
        } catch {
            XCTAssertEqual(error as? IntegrationError, Integrations.cantCompose)
        }
        XCTAssertFalse(other.gmailCanCompose)
        XCTAssertFalse(other.gmailCanModify)
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

        // Whole threads: a 6-message Slack thread with files in 2 messages, its item highlighted.
        guard case .slack(let posts, let highlighted) = try await integrations.fullThread(for: threaded.id, reload: false) else {
            return XCTFail("a Slack thread")
        }
        XCTAssertEqual(posts.count, 6)
        XCTAssertEqual(posts.filter { !$0.files.isEmpty }.count, 2)
        XCTAssertEqual(posts[highlighted].id, InboxIDs.slack(threaded.id)?.ts)
        XCTAssertEqual(posts.first?.id, threaded.threadTS, "the thread's parent first")
        XCTAssertTrue(posts.contains { $0.isMine })
        XCTAssertTrue(integrations.isStarred(message: posts[0].id, in: threaded.id), "a message of the thread starred in Docket")
        let deck = try XCTUnwrap(posts[0].files.first)
        let deckFile = try await integrations.file(for: deck, messageID: threaded.id)
        XCTAssertEqual(deckFile, document)

        // A 4-message email conversation: one email from you, one with attachments, one starred.
        var conversations: [InboxThread] = []
        for s in email { conversations.append(try await integrations.fullThread(for: s.id, reload: false)) }
        let emails = try XCTUnwrap(conversations.compactMap { thread -> [ThreadEmail]? in
            guard case .email(let emails, _) = thread, emails.count == 4 else { return nil }
            return emails
        }.first)
        XCTAssertTrue(emails.contains { $0.isMine })
        XCTAssertTrue(emails.contains { !$0.content.attachments.isEmpty })
        XCTAssertTrue(emails.contains { $0.isStarred })
        XCTAssertTrue(slack.contains { $0.isStarred }, "a starred Slack item")
        XCTAssertFalse(integrations.items(.gmail, starredOnly: true).isEmpty)
        for s in all {
            let thread = try await integrations.fullThread(for: s.id, reload: false)
            XCTAssertEqual(thread.ownMessageID, InboxThread.bareMessageID(s.id), "every item's thread, its own message highlighted")
        }

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
