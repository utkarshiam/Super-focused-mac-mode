import XCTest
@testable import Docket

// The inbox views' rules, without a window: how a thread or conversation is laid out, what its messages say,
// which message a reply answers (and so who it goes to), stars, the Starred filter, the permission banners,
// the Gmail sign-in hint, and email quote trimming. No network: Integrations answers from what the test puts
// in it. Made-up people (Maya Chen, Priya Shah, Sam Lee, Lena Park, Alex Kim) and companies (acme.example,
// northwind.example).

/// The connected Gmail address, and a #leadership thread: Sam's parent and Priya's reply (the inbox item).
private enum Fixture {
    static let me = "maya@acme.example"
    static let parentTS = "1791199000.000050"
    static let replyTS = "1791200000.000100"
}

@MainActor
final class InboxViewsTests: XCTestCase {
    private var suites: [String] = []

    override func setUp() async throws {
        Keychain.useInMemoryStore()
    }

    override func tearDown() async throws {
        for name in suites { UserDefaults().removePersistentDomain(forName: name) }
        suites = []
        Keychain.useInMemoryStore()
    }

    // MARK: Fixtures

    private static let me = Fixture.me
    private static let parentTS = Fixture.parentTS
    private static let replyTS = Fixture.replyTS

    /// Integrations with these items and nothing connected: nothing it does reaches the network.
    private func integrations(_ items: [Suggestion] = []) -> Integrations {
        let integrations = Integrations(transport: { _ in throw URLError(.notConnectedToInternet) }, triage: .none, sleep: { _ in })
        integrations.openURL = { _ in XCTFail("tests never open a browser") }
        integrations.suggestions = items
        return integrations
    }

    private func defaults() -> UserDefaults {
        let name = "docket-inbox-views-\(UUID().uuidString)"
        suites.append(name)
        return UserDefaults(suiteName: name)!
    }

    private func slackItem(_ ts: String = Fixture.replyTS, label: String = "#leadership · Priya Shah", minutesAgo: Double = 10,
                           starred: Bool = false) -> Suggestion {
        var s = Suggestion(source: TaskSource(kind: .slack, externalID: "slack:C0LEAD/\(ts)", url: nil, label: label),
                           from: label.components(separatedBy: " · ").last ?? "Priya Shah", subject: nil,
                           snippet: "Can you send the Q3 numbers?", receivedAt: Date().addingTimeInterval(-minutesAgo * 60),
                           draft: nil, trigger: .reaction)
        s.isStarred = starred
        return s
    }

    private func emailItem(_ id: String = "gmail:t1/m1", minutesAgo: Double = 20, starred: Bool = false) -> Suggestion {
        var s = Suggestion(source: TaskSource(kind: .gmail, externalID: id, url: nil, label: "Sam Lee · Contract redlines"),
                           from: "Sam Lee", subject: "Contract redlines", snippet: "Attached are the redlines.",
                           receivedAt: Date().addingTimeInterval(-minutesAgo * 60), draft: nil, trigger: .starred)
        s.isStarred = starred
        return s
    }

    private func post(_ ts: String, _ from: String, user: String? = nil, mine: Bool = false) -> ThreadSlackMessage {
        ThreadSlackMessage(id: ts, from: from, userID: user, date: Date(timeIntervalSince1970: TimeInterval(ts) ?? 0),
                           markup: "Hello", text: "Hello", files: [], isMine: mine)
    }

    private func mail(_ id: String, from: String, at seconds: TimeInterval = 1_791_000_000, text: String = "Hi", mine: Bool = false,
                      to: [String] = ["Maya Chen <maya@acme.example>"], cc: [String] = []) -> ThreadEmail {
        ThreadEmail(id: id, from: from, date: Date(timeIntervalSince1970: seconds),
                    content: MessageContent(text: text, to: to, cc: cc, fetchedAt: Date(timeIntervalSince1970: seconds)),
                    replyHeaders: MailReplyHeaders(messageID: "<\(id)@mail.example>", subject: "Contract redlines", from: from, to: to, cc: cc),
                    isMine: mine, isStarred: false, snippet: text)
    }

    private func day(_ day: Int, _ hour: Int, _ minute: Int = 0) -> Date {
        Calendar.current.date(from: DateComponents(year: 2026, month: 10, day: day, hour: hour, minute: minute))!
    }

    /// Waits for work Docket started in a task of its own (a star on its way).
    private func waitUntil(_ condition: () -> Bool, file: StaticString = #filePath, line: UInt = #line) async {
        for _ in 0..<200 {
            if condition() { return }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTFail("timed out", file: file, line: line)
    }

    // MARK: Laying out a thread

    func testShowEarlierHidesAllButTwentyMessagesAboveTheInboxOne() {
        XCTAssertEqual(ThreadLayout.hiddenEarlier(highlighted: nil, showAll: false), 0)
        XCTAssertEqual(ThreadLayout.hiddenEarlier(highlighted: 20, showAll: false), 0)
        XCTAssertEqual(ThreadLayout.hiddenEarlier(highlighted: 21, showAll: false), 1)
        XCTAssertEqual(ThreadLayout.hiddenEarlier(highlighted: 120, showAll: false), 100)
        XCTAssertEqual(ThreadLayout.hiddenEarlier(highlighted: 120, showAll: true), 0)
        XCTAssertEqual(ThreadLayout.hiddenEarlier(highlighted: 5, showAll: false, limit: 2), 3)
        XCTAssertEqual(ThreadText.showEarlier(1), "Show 1 earlier message")
        XCTAssertEqual(ThreadText.showEarlier(100), "Show 100 earlier messages")
    }

    func testOnlyAConversationOfMoreThanOneHighlightsTheInboxMessage() {
        XCTAssertNil(ThreadLayout.highlight(0, count: 1))
        XCTAssertEqual(ThreadLayout.highlight(2, count: 6), 2)
        XCTAssertNil(ThreadLayout.highlight(6, count: 6))
        XCTAssertNil(ThreadLayout.highlight(-1, count: 6))
    }

    func testTheNewestAndTheInboxEmailOpenTheOthersShowAsLines() {
        let ids = ["m0", "m1", "m2", "m3"]
        let newest = ThreadLayout.newest(ids)
        XCTAssertEqual(newest, 3)
        func open(_ toggled: [String: Bool]) -> [Int] {
            ids.indices.filter { ThreadLayout.isOpen(ids[$0], at: $0, newest: newest, highlighted: 1, toggled: toggled) }
        }
        XCTAssertEqual(open([:]), [1, 3])
        // A click opens one, or closes one.
        XCTAssertEqual(open(["m0": true, "m3": false]), [0, 1])
    }

    func testARepliesJustSentStayOpenWithoutTakingTheNewestsPlace() {
        let sent = InboxThread.newSentFromDocketID()
        XCTAssertEqual(ThreadLayout.newest(["m0", "m1", sent]), 1)
        XCTAssertTrue(ThreadLayout.isOpen(sent, at: 2, newest: 1, highlighted: nil, toggled: [:]))
        XCTAssertEqual(ThreadLayout.newest([sent]), 0)
        XCTAssertNil(ThreadLayout.newest([]))
    }

    func testAMessageShowsItsDayOnlyWhenTheDayChanges() {
        XCTAssertTrue(ThreadLayout.showsDay(day(5, 9), after: nil))
        XCTAssertFalse(ThreadLayout.showsDay(day(5, 17), after: day(5, 9)))
        XCTAssertTrue(ThreadLayout.showsDay(day(6, 8), after: day(5, 17)))
    }

    func testTheEyebrowCountsTheMessages() {
        XCTAssertEqual(ThreadText.title(.slack, count: 6), "Thread · 6 messages")
        XCTAssertEqual(ThreadText.title(.gmail, count: 4), "Conversation · 4 messages")
        XCTAssertEqual(ThreadText.title(.gmail, count: 1), "Message")
        XCTAssertEqual(ThreadText.title(.slack, count: 0), "Message")
    }

    // MARK: Who wrote what

    func testInitialsAndFirstNames() {
        XCTAssertEqual(ThreadText.initial(of: "Priya Shah"), "P")
        XCTAssertEqual(ThreadText.initial(of: "sam@northwind.example"), "S")
        XCTAssertEqual(ThreadText.initial(of: "  (ops) desk"), "O")
        XCTAssertEqual(ThreadText.initial(of: ""), "?")
        XCTAssertEqual(ThreadText.firstName("Priya Shah"), "Priya")
        XCTAssertEqual(ThreadText.firstName("sam@northwind.example"), "sam@northwind.example")
        XCTAssertEqual(ThreadText.firstName("—"), "—")
    }

    func testSlackSendersByNameAndYourOwnAsYou() {
        let names = ["U0PRIYA": "Priya Shah"]
        XCTAssertEqual(ThreadText.sender(of: post("1.0", "Maya Chen", mine: true), names: names), "You")
        XCTAssertEqual(ThreadText.sender(of: post("1.0", "Someone", user: "U0PRIYA"), names: names), "Priya Shah")
        XCTAssertEqual(ThreadText.sender(of: post("1.0", "U0PRIYA"), names: names), "Priya Shah")
        XCTAssertEqual(ThreadText.sender(of: post("1.0", "Sam Lee", user: "U0SAM"), names: names), "Sam Lee")
        XCTAssertEqual(ThreadText.sender(of: post("1.0", "  "), names: [:]), "Someone")
    }

    func testEmailSendersAddressesAndRecipients() {
        let sam = mail("m1", from: "Sam Lee <sam@northwind.example>",
                       to: ["Maya Chen <maya@acme.example>", "Lena Park <lena@acme.example>"],
                       cc: ["lena@acme.example", "Ops <ops@northwind.example>"])
        XCTAssertEqual(ThreadText.sender(of: sam), "Sam Lee")
        XCTAssertEqual(ThreadText.address(of: sam), "sam@northwind.example")
        XCTAssertNil(ThreadText.address(of: mail("m2", from: "lena@acme.example")), "no name: the address is the name")
        let mine = mail("m3", from: "Maya Chen <maya@acme.example>", mine: true)
        XCTAssertEqual(ThreadText.sender(of: mine), "You")
        XCTAssertNil(ThreadText.address(of: mine))

        // To then Cc, each once, the user as "you" however their address is written.
        XCTAssertEqual(ThreadText.recipients(of: sam, myAddress: "Maya@Acme.example"), "to you, Lena Park, Ops")
        XCTAssertEqual(ThreadText.recipients(of: sam, myAddress: nil), "to Maya Chen, Lena Park, Ops")
        // From the reply headers when the content doesn't say.
        var bare = mail("m4", from: "Sam Lee <sam@northwind.example>", to: [], cc: [])
        bare.replyHeaders.to = ["Lena Park <lena@acme.example>"]
        XCTAssertEqual(ThreadText.recipients(of: bare, myAddress: Self.me), "to Lena Park")
        bare.replyHeaders.to = []
        XCTAssertNil(ThreadText.recipients(of: bare, myAddress: Self.me))
    }

    func testACollapsedEmailReadsAsItsFirstWords() {
        var lena = mail("m2", from: "Lena Park <lena@acme.example>", text: "I can join a call Friday.\n\nOn Sat, Sam Lee wrote:\n> Attached are the redlines.")
        lena.snippet = ""
        XCTAssertEqual(ThreadText.snippet(of: lena), "I can join a call Friday.")
        lena.snippet = "  Gmail's own\n snippet "
        XCTAssertEqual(ThreadText.snippet(of: lena), "Gmail's own snippet")
    }

    // MARK: Replying to one message

    func testReplyingToNamesThePersonAndARealTime() {
        let now = day(5, 15)
        let earlier = day(5, 10, 42)
        let friday = day(2, 9, 15)
        XCTAssertEqual(ThreadText.replyingTo("Priya Shah", isMine: false, at: earlier, now: now), "Replying to Priya · \(Fmt.time(earlier))")
        XCTAssertEqual(ThreadText.replyingTo("Maya Chen", isMine: true, at: friday, now: now),
                       "Replying to your message · \(Fmt.due(friday, hasTime: true, now: now))")
        // A real date for another day, never "Yesterday".
        let yesterday = ThreadText.when(day(4, 9), now: now)
        XCTAssertEqual(yesterday, Fmt.due(day(4, 9), hasTime: true, now: now))
        XCTAssertFalse(yesterday.contains("Yesterday"))
    }

    func testTheQuoteLineGoesOnTopAndComesOffAgain() throws {
        let quote = try XCTUnwrap(ThreadText.quoteLine("Can you send me the\n  Q3 numbers   before Thursday?"))
        XCTAssertEqual(quote, "> Can you send me the Q3 numbers before Thursday?")
        XCTAssertNil(ThreadText.quoteLine(" \n "))
        let long = try XCTUnwrap(ThreadText.quoteLine(String(repeating: "words ", count: 60)))
        XCTAssertTrue(long.hasPrefix("> words"))
        XCTAssertTrue(long.hasSuffix("…"))
        XCTAssertLessThanOrEqual(long.count, 2 + 140 + 1)
        XCTAssertFalse(long.contains("\n"), "one line")

        XCTAssertEqual(ThreadText.adding(quote: quote, to: " "), quote + "\n")
        let reply = ThreadText.adding(quote: quote, to: "Sending them tonight.")
        XCTAssertEqual(reply, quote + "\nSending them tonight.")
        XCTAssertEqual(ThreadText.removing(quote: quote, from: reply), "Sending them tonight.")
        // Changed by hand: left as it is.
        let edited = reply.replacingOccurrences(of: "Thursday", with: "Friday")
        XCTAssertEqual(ThreadText.removing(quote: quote, from: edited), edited)
    }

    func testAnEmailReplyAnswersTheNewestEmailThatIsntYoursUntilOneIsPicked() async {
        let item = emailItem()
        let integrations = integrations([item])
        integrations.wholeThreads[item.id] = .email([
            mail("m0", from: "Maya Chen <maya@acme.example>", at: 1, mine: true),
            mail("m1", from: "Sam Lee <sam@northwind.example>", at: 2),
            mail("m2", from: "Lena Park <lena@acme.example>", at: 3),
            mail("m3", from: "Maya Chen <maya@acme.example>", at: 4, mine: true),
        ], highlighted: 1)
        let conversation = ConversationModel(itemID: item.id, integrations: integrations)
        await conversation.start()
        XCTAssertEqual(conversation.phase, .loaded)

        // Nothing picked: Lena's (the newest that isn't yours), named to sendReply so it goes where the composer said.
        XCTAssertNil(conversation.target)
        XCTAssertEqual(conversation.replyEmail?.id, "m2")
        XCTAssertEqual(conversation.replyingTo, "m2")

        // Sam's Reply: the composer answers Sam's email, and comes up.
        conversation.reply(to: "m1")
        XCTAssertEqual(conversation.pickedEmail?.id, "m1")
        XCTAssertEqual(conversation.replyEmail?.id, "m1")
        XCTAssertEqual(conversation.replyingTo, "m1")
        XCTAssertEqual(conversation.composerRequests, 1)
        XCTAssertNil(conversation.pickedSlack)

        // Sent: back to the default, and the emails open now stay open once the reply comes in as the newest.
        conversation.didSend()
        XCTAssertNil(conversation.target)
        XCTAssertEqual(conversation.toggled, ["m1": true, "m3": true])
    }

    func testASlackReplyGoesInTheThreadWhicheverMessageItAnswers() async {
        let item = slackItem()
        let integrations = integrations([item])
        integrations.wholeThreads[item.id] = .slack([post(Self.parentTS, "Sam Lee"), post(Self.replyTS, "Priya Shah")], highlighted: 1)
        let conversation = ConversationModel(itemID: item.id, integrations: integrations)
        await conversation.start()
        // The thread: nothing to name.
        XCTAssertNil(conversation.replyingTo)
        XCTAssertNil(conversation.replyEmail)
        conversation.reply(to: Self.parentTS)
        XCTAssertEqual(conversation.pickedSlack?.from, "Sam Lee")
        XCTAssertEqual(conversation.replyingTo, Self.parentTS)
        conversation.target = nil
        XCTAssertNil(conversation.replyingTo)
    }

    func testAPickedMessageThatLeftTheThreadFallsBackToTheDefault() async {
        let item = emailItem()
        let integrations = integrations([item])
        integrations.wholeThreads[item.id] = .email([mail("m1", from: "Sam Lee <sam@northwind.example>")], highlighted: 0)
        let conversation = ConversationModel(itemID: item.id, integrations: integrations)
        conversation.reply(to: "m9")
        await conversation.load(reload: false)
        XCTAssertNil(conversation.target)
        XCTAssertEqual(conversation.replyingTo, "m1")
    }

    func testAThreadThatCantLoadSaysWhyAndARefreshThatFailsKeepsWhatsThere() async {
        let integrations = integrations()
        let gone = ConversationModel(itemID: "gmail:t9/m9", integrations: integrations)
        await gone.load(reload: false)
        guard case .failed(let message) = gone.phase else { return XCTFail("\(gone.phase)") }
        XCTAssertFalse(message.isEmpty)
        XCTAssertNil(gone.thread)
        XCTAssertNil(gone.replyingTo, "without the conversation, Integrations picks the email to answer")

        let item = slackItem()
        integrations.suggestions = [item]
        integrations.wholeThreads[item.id] = .slack([post(Self.replyTS, "Priya Shah")], highlighted: 0)
        let shown = ConversationModel(itemID: item.id, integrations: integrations)
        await shown.load(reload: false)
        XCTAssertEqual(shown.phase, .loaded)
        // Asking Slack again doesn't work (not connected): the thread stays, with a note.
        await shown.load(reload: true)
        XCTAssertEqual(shown.phase, .loaded)
        XCTAssertNotNil(shown.reloadProblem)
        XCTAssertNotNil(shown.thread)
        XCTAssertFalse(shown.reloading)
    }

    func testASendGoesWhereTheConfirmationSaidEvenIfTheConversationArrivesMeanwhile() async {
        let item = emailItem()
        let integrations = integrations([item])
        let conversation = ConversationModel(itemID: item.id, integrations: integrations)
        // Before the conversation is in, the composer and the confirmation name the email itself, and a send
        // takes that down: the conversation's newer default can't take its place while the confirmation is up.
        XCTAssertNil(conversation.replyingTo, "AI answers the default once the conversation is in")
        XCTAssertEqual(conversation.sendTarget, "m1")
        integrations.wholeThreads[item.id] = .email([mail("m1", from: "Sam Lee <sam@northwind.example>", at: 1),
                                                     mail("m2", from: "Lena Park <lena@acme.example>", at: 2)], highlighted: 0)
        XCTAssertEqual(conversation.sendTarget, "m2", "once it's in: its default, as the composer then shows")
        conversation.reply(to: "m1")
        XCTAssertEqual(conversation.sendTarget, "m1")

        // Slack replies go in the thread whichever message they answer: nothing to take down.
        let slack = slackItem()
        integrations.suggestions.append(slack)
        XCTAssertNil(ConversationModel(itemID: slack.id, integrations: integrations).sendTarget)
    }

    func testTheConfirmationNamesWhoseSlackMessageIsAnswered() {
        let item = slackItem()
        XCTAssertEqual(ReplyText.confirmation(for: item, others: 0), "Send this reply to Priya Shah in #leadership?")
        XCTAssertEqual(ReplyText.confirmation(for: item, others: 0, person: "Sam Lee"), "Send this reply to Sam Lee in #leadership?")
        XCTAssertEqual(ReplyText.confirmation(for: item, others: 0, person: "the thread"), "Send this reply to the thread in #leadership?")
        // A direct message has one other person.
        let dm = slackItem(label: "Direct message · Alex Kim")
        XCTAssertEqual(ReplyText.confirmation(for: dm, others: 0, person: "the thread"), "Send this reply to Alex Kim?")
    }

    func testAnEmailReplyGoesToThePeopleOfTheEmailItAnswers() {
        let lena = MailReplyHeaders(messageID: "<m2@mail.example>", subject: "Contract redlines", from: "Lena Park <lena@acme.example>",
                                    to: ["Sam Lee <sam@northwind.example>", "Maya Chen <maya@acme.example>"],
                                    cc: ["Ops <ops@northwind.example>"])
        XCTAssertEqual(ReplyText.mailRecipients(headers: lena, myAddress: Self.me, replyAll: false).compactMap(\.address),
                       ["lena@acme.example"])
        XCTAssertEqual(ReplyText.mailRecipients(headers: lena, myAddress: Self.me, replyAll: true).compactMap(\.address),
                       ["lena@acme.example", "sam@northwind.example", "ops@northwind.example"])
        // The item's own headers, the same way.
        var item = emailItem()
        item.replyHeaders = lena
        XCTAssertEqual(ReplyText.mailRecipients(for: item, myAddress: Self.me, replyAll: false)?.compactMap(\.address), ["lena@acme.example"])
        XCTAssertNil(ReplyText.mailRecipients(for: slackItem(), myAddress: Self.me, replyAll: false))
    }

    // MARK: Stars and the Starred filter

    func testStarringFromTheListHeaderOrSChangesItAtOnce() async {
        let item = slackItem()
        let integrations = integrations([item])
        InboxStarring.toggle(item: item.id, integrations: integrations)
        await waitUntil { integrations.suggestion(item.id)?.isStarred == true }
        InboxStarring.toggle(item: item.id, integrations: integrations)
        await waitUntil { integrations.suggestion(item.id)?.isStarred == false }
        // Gone from the inbox: nothing to star.
        InboxStarring.toggle(item: "slack:C0LEAD/1.000000", integrations: integrations)
    }

    func testStarringAMessageOfTheThread() async {
        let item = slackItem()
        let integrations = integrations([item])
        integrations.wholeThreads[item.id] = .slack([post(Self.parentTS, "Sam Lee"), post(Self.replyTS, "Priya Shah")], highlighted: 1)
        XCTAssertFalse(integrations.isStarred(message: Self.parentTS, in: item.id))
        InboxStarring.toggle(message: Self.parentTS, in: item.id, integrations: integrations)
        await waitUntil { integrations.isStarred(message: Self.parentTS, in: item.id) }
        XCTAssertFalse(integrations.suggestion(item.id)?.isStarred ?? true, "Sam's message, not the item")
        // The item's own message is the item.
        InboxStarring.toggle(message: Self.replyTS, in: item.id, integrations: integrations)
        await waitUntil { integrations.suggestion(item.id)?.isStarred == true }
    }

    func testTheStarredFilterIsPerTabAndRemembered() {
        let defaults = defaults()
        let model = InboxModel(defaults: defaults)
        XCTAssertFalse(model.isStarredOnly(.slack))
        XCTAssertFalse(model.isStarredOnly(.gmail))
        model.setStarredOnly(true, for: .gmail)
        XCTAssertTrue(model.isStarredOnly(.gmail))
        XCTAssertFalse(model.isStarredOnly(.slack))
        // The next launch.
        let again = InboxModel(defaults: defaults)
        XCTAssertTrue(again.isStarredOnly(.gmail))
        XCTAssertFalse(again.isStarredOnly(.slack))
        again.setStarredOnly(false, for: .gmail)
        XCTAssertFalse(InboxModel(defaults: defaults).isStarredOnly(.gmail))
    }

    func testTheListShowsStarredFirstAndOnlyThemWhenFiltered() {
        let older = slackItem("1791100000.000100", minutesAgo: 60, starred: true)
        let newer = slackItem("1791300000.000100", minutesAgo: 5)
        let newest = slackItem("1791400000.000100", minutesAgo: 1)
        let email = emailItem(starred: false)
        let integrations = integrations([newer, email, older, newest])
        let model = InboxModel(defaults: defaults())
        XCTAssertEqual(model.items(.slack, in: integrations).map(\.id), [older.id, newest.id, newer.id])
        model.setStarredOnly(true, for: .slack)
        XCTAssertEqual(model.items(.slack, in: integrations).map(\.id), [older.id])
        // The other tab keeps its own filter.
        XCTAssertEqual(model.items(.gmail, in: integrations).map(\.id), [email.id])
    }

    // MARK: Permissions and signing in

    func testTheSlackBannerNamesWhatsMissing() {
        XCTAssertNil(InboxItemText.slackPermissionBanner(missing: []))
        XCTAssertEqual(InboxItemText.slackPermissionBanner(missing: ["files:read", "channels:history"]),
                       "Docket needs two more Slack permissions to show files and threads.")
        XCTAssertEqual(InboxItemText.slackPermissionBanner(missing: ["files:read"]), "Docket needs one more Slack permission to show files.")
        XCTAssertEqual(InboxItemText.slackPermissionBanner(missing: ["stars:read", "stars:write"]),
                       "Docket needs one more Slack permission to star messages in Slack.")
        XCTAssertEqual(InboxItemText.slackPermissionBanner(missing: ["groups:history", "stars:read"]),
                       "Docket needs two more Slack permissions to show threads and to star messages in Slack.")
        XCTAssertEqual(InboxItemText.slackPermissionBanner(missing: ["files:read", "im:history", "stars:write"]),
                       "Docket needs three more Slack permissions to show files and threads, and to star messages in Slack.")

        XCTAssertEqual(InboxItemText.slackPermissionEffect(missing: ["stars:write"]), "Until then, stars stay in Docket. Everything else works.")
        XCTAssertEqual(InboxItemText.slackPermissionEffect(missing: ["files:read", "channels:history"]),
                       "Until then, files open in Slack and threads stay hidden. Everything else works.")
        XCTAssertEqual(InboxItemText.slackPermissionEffect(missing: ["files:read", "mpim:history", "stars:read"]),
                       "Until then, files open in Slack, threads stay hidden, and stars stay in Docket. Everything else works.")

        // Every permission the manifest adds for the complete message (files, threads, stars) gets the banner.
        for scope in SlackManifest.contentScopes {
            XCTAssertNotNil(InboxItemText.slackPermissionBanner(missing: [scope]), scope)
        }
    }

    func testTheGmailSignInHintSaysWhatToDoAboutAccessBlocked() {
        XCTAssertEqual(GmailSignInHint.text,
                       "Seeing “Access blocked”? Add your Google address under Test users in Google Cloud (Google Auth Platform → Audience), then try again.")
        XCTAssertEqual(GmailSignInHint.audienceURL.absoluteString, "https://console.cloud.google.com/auth/audience")
        XCTAssertEqual(GmailSignInHint.audienceURL.scheme, "https")
    }

    // MARK: Quoted history in emails

    func testAnHTMLEmailsQuotedHistoryHidesBehindTheToggle() throws {
        let reply = #"<div>Friday works.</div><div class="gmail_quote"><div>On Thu, Sam wrote:</div><blockquote class="gmail_quote">Can we meet?</blockquote></div>"#
        XCTAssertTrue(MailHTML.hasQuotedHistory(reply))
        let page = MailHTML.document(reply, hidingQuotes: true)
        XCTAssertTrue(page.contains(MailHTML.quoteHidingStyle))
        XCTAssertFalse(MailHTML.document(reply).contains(MailHTML.quoteHidingStyle))
        // The security policy still comes before anything from the email.
        let policy = try XCTUnwrap(page.range(of: "Content-Security-Policy"))
        let email = try XCTUnwrap(page.range(of: "<div>Friday works."))
        XCTAssertLessThan(policy.lowerBound, email.lowerBound)

        XCTAssertTrue(MailHTML.hasQuotedHistory(#"<p>Sounds good.</p><blockquote type="cite">Earlier</blockquote>"#))
        XCTAssertTrue(MailHTML.hasQuotedHistory(#"<p>Yes.</p><div id="divRplyFwdMsg">From: Sam</div><div>Earlier</div>"#))
        XCTAssertTrue(MailHTML.hasQuotedHistory(#"<div dir="ltr">Yes.</div><div><div dir="ltr" class="x_gmail_quote">Earlier</div></div>"#))
        // Nothing of its own before the quote, a forward, or no quote at all: nothing to hide.
        XCTAssertFalse(MailHTML.hasQuotedHistory(#"<div class="gmail_quote">On Thu, Sam wrote: Can we meet?</div>"#))
        XCTAssertFalse(MailHTML.hasQuotedHistory(#"<html><head><style>p { margin: 0 }</style></head><body><div id="divRplyFwdMsg">From: Sam</div><div>Body</div></body></html>"#))
        XCTAssertFalse(MailHTML.hasQuotedHistory(#"<p>FYI</p><div class="gmail_quote">---------- Forwarded message ---------<br>From: Sam</div>"#))
        XCTAssertFalse(MailHTML.hasQuotedHistory("<p>Just a note, quoting nobody.</p>"))
    }

    func testAPlainTextEmailTrimsToWhatItAdds() {
        XCTAssertEqual(MailHTML.trimmedText("I can join Friday.\n\nOn Sat, Sam Lee wrote:\n> Attached are the redlines."), "I can join Friday.")
        XCTAssertNil(MailHTML.trimmedText("Just a note.\n\nThanks,\nLena"))
        XCTAssertNil(MailHTML.trimmedText("> all of it quoted"))
    }

    // MARK: The header's status line

    func testTheStatusLineShowsATickOrTheProblemAndItsFix() {
        var facts = InboxStatus.Facts(slackConnected: true, gmailConnected: true)
        XCTAssertEqual(InboxStatus.parts(facts).map(\.text), ["Slack ✓", "Gmail ✓", "AI ✓"])
        XCTAssertTrue(InboxStatus.parts(facts).allSatisfy { $0.fix == nil })

        facts.slackPermissions = InboxItemText.slackPermissionBanner(missing: ["files:read"])
        facts.gmailNeedsReconnect = true
        facts.aiHasKey = false
        var parts = InboxStatus.parts(facts)
        XCTAssertEqual(parts.map(\.text), ["Slack needs permissions", "Reconnect Gmail", "AI needs a key"])
        XCTAssertEqual(parts.map(\.fix), [.updateSlack, .reconnectGmail, .aiSettings])

        // A refresh error wins over a missing permission; not connected wins over everything.
        facts.slackProblem = "Slack said the token was revoked."
        facts.gmailConnected = false
        facts.aiOn = false
        parts = InboxStatus.parts(facts)
        XCTAssertEqual(parts.map(\.text), ["Slack error", "Gmail not connected", "AI off"])
        XCTAssertEqual(parts.map(\.fix), [.connections, .connections, .aiSettings])
        XCTAssertTrue(parts[0].help.hasPrefix("Slack said the token was revoked."))

        let now = Date(timeIntervalSince1970: 1_791_200_000)
        XCTAssertEqual(InboxStatus.updated(now, refreshing: true, now: now), "Checking…")
        XCTAssertEqual(InboxStatus.updated(now.addingTimeInterval(-60), refreshing: false, now: now), "Updated \(Fmt.time(now.addingTimeInterval(-60)))")
        XCTAssertEqual(InboxStatus.updated(now.addingTimeInterval(-3 * 86_400), refreshing: false, now: now),
                       "Updated \(Fmt.dateTime(now.addingTimeInterval(-3 * 86_400)))")
        XCTAssertNil(InboxStatus.updated(nil, refreshing: false, now: now))
    }

    // MARK: The list

    func testTheOpenMessageFollowsTheListAndTheArrows() {
        XCTAssertEqual(InboxLayout.successor(of: "b", before: ["a", "b", "c"], after: ["a", "c"]), "c")
        XCTAssertEqual(InboxLayout.successor(of: "c", before: ["a", "b", "c"], after: ["a", "b"]), "b")
        XCTAssertEqual(InboxLayout.successor(of: "x", before: ["a"], after: ["a"]), "a")
        XCTAssertNil(InboxLayout.successor(of: "a", before: ["a"], after: []))
        XCTAssertEqual(InboxLayout.step(from: nil, by: 1, in: ["a", "b"]), "a")
        XCTAssertEqual(InboxLayout.step(from: nil, by: -1, in: ["a", "b"]), "b")
        XCTAssertEqual(InboxLayout.step(from: "b", by: 1, in: ["a", "b"]), "b")
        XCTAssertNil(InboxLayout.step(from: "a", by: 1, in: []))
    }
}
