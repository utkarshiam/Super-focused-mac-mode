import XCTest
@testable import Docket

// The quick check every 2 minutes, notifications about new messages, and the menu bar panel's size. No network:
// `FakeIntegrationServer` answers for Slack and Google, the keychain is in memory, and notifications go to a
// recorder instead of macOS. Made-up workspace (Acme Test) and people (Maya Chen, Priya Shah, Sam Lee).

// MARK: - Fixtures

private enum Poll {
    static let token = "xoxp-1111-2222-3333-test"
    static let me = "U0MAYA"
    static let account = SlackAccount(userID: me, userName: "maya", teamID: "T0ACME", teamName: "Acme Test",
                                      teamURL: URL(string: "https://acme-test.slack.com/"))
    static let address = "maya@acme.example"
    static let accessToken = #"{"access_token":"ya29.test-access","expires_in":3599,"scope":"https://www.googleapis.com/auth/gmail.readonly","token_type":"Bearer"}"#
    static let noReactions = #"{"ok":true,"items":[],"response_metadata":{"next_cursor":""}}"#
    static let noConversations = #"{"ok":true,"channels":[],"response_metadata":{"next_cursor":""}}"#

    static func ts(_ date: Date) -> String { String(format: "%.6f", date.timeIntervalSince1970) }

    /// A message in #leadership that mentions Maya, from Priya.
    static func mention(_ text: String, at date: Date, user: String = "U0PRIYA") -> String {
        #"{"type":"message","channel":{"id":"C0LEAD","name":"leadership"},"user":"\#(user)","ts":"\#(ts(date))","text":"<@U0MAYA> \#(text)"}"#
    }

    static func search(_ matches: [String]) -> String {
        #"{"ok":true,"messages":{"total":\#(matches.count),"matches":[\#(matches.joined(separator: ","))]}}"#
    }

    /// A 📌 Maya put on a message in #leadership.
    static func reaction(by user: String, at date: Date) -> String {
        """
        {"ok":true,"items":[{"type":"message","channel":"C0LEAD","message":{"type":"message","ts":"\(ts(date))","user":"\(user)",
          "text":"Pinned for later","reactions":[{"name":"pushpin","users":["U0MAYA"],"count":1}]}}],"response_metadata":{"next_cursor":""}}
        """
    }

    static func user(_ id: String, _ handle: String, _ name: String) -> String {
        #"{"ok":true,"user":{"id":"\#(id)","name":"\#(handle)","real_name":"\#(name)","profile":{"real_name":"\#(name)","display_name":"\#(handle)"}}}"#
    }

    static func names(on server: FakeIntegrationServer) {
        server.slack("users.info", where: ("user", "U0PRIYA"), user("U0PRIYA", "priya", "Priya Shah"))
        server.slack("users.info", where: ("user", "U0SAM"), user("U0SAM", "sam", "Sam Lee"))
        server.slack("users.info", where: ("user", "U0MAYA"), user("U0MAYA", "maya", "Maya Chen"))
    }

    /// Maya's DMs: Sam (Slack says when his newest message was) and Priya (Slack doesn't say).
    static func conversations(samLatest: Date) -> String {
        """
        {"ok":true,"channels":[
          {"id":"D0SAM","is_im":true,"user":"U0SAM","created":1700000000,"latest":{"ts":"\(ts(samLatest))"}},
          {"id":"D0PRIYA","is_im":true,"user":"U0PRIYA","created":1700000100}
        ],"response_metadata":{"next_cursor":""}}
        """
    }

    static func history(_ user: String, _ text: String, at date: Date) -> String {
        #"{"ok":true,"messages":[{"type":"message","user":"\#(user)","text":"\#(text)","ts":"\#(ts(date))"}],"has_more":false}"#
    }

    static func list(_ refs: [(String, String)]) -> String {
        let items = refs.map { #"{"id":"\#($0.0)","threadId":"\#($0.1)"}"# }.joined(separator: ",")
        return #"{"messages":[\#(items)],"resultSizeEstimate":\#(refs.count)}"#
    }

    static func email(_ id: String, thread: String, from: String, subject: String, snippet: String, at date: Date) -> String {
        """
        {"id":"\(id)","threadId":"\(thread)","labelIds":["INBOX","IMPORTANT","UNREAD"],"snippet":"\(snippet)",
         "internalDate":"\(Int64(date.timeIntervalSince1970 * 1000))",
         "payload":{"headers":[{"name":"From","value":"\(from)"},{"name":"Subject","value":"\(subject)"}]}}
        """
    }

    static func suggestion(_ id: String, kind: TaskSource.Kind = .slack, from: String = "Priya Shah", label: String = "#leadership · Priya Shah",
                           subject: String? = nil, snippet: String = "Can you approve the Q4 budget?", at date: Date = Date()) -> Suggestion {
        Suggestion(source: TaskSource(kind: kind, externalID: id, url: nil, label: label), from: from, subject: subject,
                   snippet: snippet, receivedAt: date, draft: nil, trigger: .mention)
    }
}

/// What would have gone to Notification Center.
@MainActor
private final class AlertLog {
    var posted: [[MessageAlert]] = []
    var withdrawn: [String] = []
    var all: [MessageAlert] { posted.flatMap { $0 } }

    var sink: MessageAlertSink {
        MessageAlertSink(post: { [unowned self] in self.posted.append($0) }, withdraw: { [unowned self] in self.withdrawn += $0 })
    }
}

// MARK: - Pure rules

final class MessagePollRulesTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_791_000_000)

    private func skip(enabled: Bool = true, slack: Bool = true, gmail: Bool = false, refreshing: Bool = false, asleep: Bool = false,
                      slackPause: Date? = nil, gmailPause: Date? = nil) -> MessagePoll.Skip? {
        MessagePoll.skip(enabled: enabled, slackConnected: slack, gmailConnected: gmail, refreshing: refreshing, asleep: asleep,
                         slackPausedUntil: slackPause, gmailPausedUntil: gmailPause, now: now)
    }

    func testTheScheduleAndWhatSkipsACheck() {
        XCTAssertEqual(MessagePoll.interval, 120, "every 2 minutes")
        XCTAssertNil(skip())
        XCTAssertNil(skip(slack: false, gmail: true))
        XCTAssertEqual(skip(enabled: false), .turnedOff)
        XCTAssertEqual(skip(slack: false, gmail: false), .notConnected)
        XCTAssertEqual(skip(refreshing: true), .refreshing)
        XCTAssertEqual(skip(asleep: true), .asleep)
        // A rate-limit pause holds the check only while it lasts, and only when every connected service waits.
        XCTAssertEqual(skip(slackPause: now.addingTimeInterval(30)), .paused)
        XCTAssertNil(skip(slackPause: now.addingTimeInterval(-1)), "the pause is over")
        XCTAssertNil(skip(gmail: true, slackPause: now.addingTimeInterval(30)), "Gmail is still checked")
        XCTAssertEqual(skip(gmail: true, slackPause: now.addingTimeInterval(30), gmailPause: now.addingTimeInterval(90)), .paused)
    }

    func testOneNotificationPerMessageUpToThreeThenASummary() {
        let base = Date(timeIntervalSince1970: 1_791_000_000)
        let slack = (0..<4).map { i in
            Poll.suggestion("slack:C0LEAD/179100000\(i).000100", from: i == 3 ? "Sam Lee" : "Priya Shah",
                            snippet: "Message \(i)", at: base.addingTimeInterval(TimeInterval(i)))
        }
        let three = MessageAlerts.plan(Array(slack.prefix(3)))
        XCTAssertEqual(three.count, 3)
        XCTAssertEqual(three.map(\.itemID), slack.prefix(3).map(\.id), "oldest first, so the newest lands on top")
        XCTAssertEqual(three[0].title, "Priya Shah · #leadership")
        XCTAssertEqual(three[0].body, "Message 0")
        XCTAssertEqual(three[0].threadID, "slack:C0LEAD", "one thread per conversation")

        let four = MessageAlerts.plan(slack)
        XCTAssertEqual(four.count, 1)
        XCTAssertTrue(four[0].isSummary)
        XCTAssertEqual(four[0].title, "4 new Slack messages")
        XCTAssertEqual(four[0].body, "From Sam Lee, Priya Shah")

        let email = Poll.suggestion("gmail:t2/m2", kind: .gmail, from: "Priya Shah", label: "Priya Shah · Intro", subject: "Re: Intro: Contoso",
                                    snippet: "Are you free to meet the team next week?")
        XCTAssertEqual(MessageAlerts.title(for: email), "Priya Shah · Email")
        XCTAssertEqual(MessageAlerts.body(for: email), "Intro: Contoso\nAre you free to meet the team next week?")
        XCTAssertEqual(MessageAlerts.thread(for: email), "gmail:t2")
        XCTAssertEqual(MessageAlerts.plan(slack + [email]).first?.title, "5 new messages")
        XCTAssertEqual(MessageAlerts.plan(Array(repeating: email, count: 4)).first?.title, "4 new emails")

        let dm = Poll.suggestion("slack:D0SAM/1791000000.000100", from: "Sam Lee", label: "DM · Sam Lee")
        XCTAssertEqual(MessageAlerts.title(for: dm), "Sam Lee · DM")
        XCTAssertTrue(MessageAlerts.plan([]).isEmpty)
    }

    func testNotificationTextIsPlainAndAtMostTwoLines() {
        XCTAssertEqual(MessageAlerts.clipped("  one   two \n\n three \n four", lines: 2), "one two\nthree…")
        let long = String(repeating: "word ", count: 60)
        let clipped = MessageAlerts.clipped(long, lines: 2)
        XCTAssertLessThanOrEqual(clipped.count, MessageAlerts.bodyLimit)
        XCTAssertTrue(clipped.hasSuffix("…"))
    }

    func testThePanelIsAsTallAsTheScreenUnderTheIcon() {
        // A laptop screen: menu bar 25 pt, Dock 60 pt at the bottom.
        let visible = NSRect(x: 0, y: 60, width: 1440, height: 815)
        let frame = MenuBarPanelLayout.frame(visibleFrame: visible, anchorMidX: 1300)
        XCTAssertEqual(frame.width, MenuBarPanelLayout.width)
        XCTAssertEqual(frame.maxY, visible.maxY - MenuBarPanelLayout.gap, "just under the menu bar")
        XCTAssertEqual(frame.minY, visible.minY + MenuBarPanelLayout.gap, "down to the bottom of the visible frame")
        XCTAssertEqual(frame.height, 803)
        XCTAssertEqual(frame.maxX, visible.maxX - MenuBarPanelLayout.sideMargin, "kept on screen")

        // A second display to the right and lower, the icon in its middle.
        let second = NSRect(x: 1440, y: -200, width: 1920, height: 1055)
        let there = MenuBarPanelLayout.frame(visibleFrame: second, anchorMidX: 2400)
        XCTAssertEqual(there.midX, 2400)
        XCTAssertEqual(there.minY, -194)
        XCTAssertEqual(there.height, 1043)

        // A menu bar that hides itself: the visible frame reaches the top, the panel still starts under the icon.
        let full = NSRect(x: 0, y: 0, width: 1440, height: 900)
        XCTAssertEqual(MenuBarPanelLayout.frame(visibleFrame: full, anchorMidX: 200, anchorMinY: 876).maxY, 870)
        XCTAssertEqual(MenuBarPanelLayout.frame(visibleFrame: full, anchorMidX: 10).minX, 8)
    }

    func testTasksTakeWhatTheyNeedUpToNearlyHalf() {
        XCTAssertEqual(MenuBarPanelLayout.taskListHeight(available: 800, tasksNeed: 120, showsMessages: true), 120)
        XCTAssertEqual(MenuBarPanelLayout.taskListHeight(available: 800, tasksNeed: 700, showsMessages: true), 360)
        XCTAssertEqual(MenuBarPanelLayout.taskListHeight(available: 800, tasksNeed: 120, showsMessages: false), 800,
                       "no Slack or Gmail: the tasks get it all")
    }

    func testThePanelListsNewMessagesFirstThenTheNewest() {
        let base = Date(timeIntervalSince1970: 1_791_000_000)
        let old = Poll.suggestion("slack:C0LEAD/1.1", at: base)
        let newer = Poll.suggestion("slack:C0LEAD/2.1", at: base.addingTimeInterval(60))
        let newest = Poll.suggestion("gmail:t1/m1", kind: .gmail, subject: "Q3 numbers", snippet: "Final  numbers\nattached",
                                     at: base.addingTimeInterval(120))
        var ai = Poll.suggestion("ai:1", at: base.addingTimeInterval(500))
        ai.source.kind = .ai
        let listed = MenuBarMessageList.items([old, newer, newest, ai], new: [old.id])
        XCTAssertEqual(listed.map(\.id), [old.id, newest.id, newer.id])
        XCTAssertEqual(MenuBarMessageList.snippet(newest), "Q3 numbers — Final numbers attached")
    }

    func testBothSwitchesAreOnUnlessTurnedOff() {
        let settings = IntegrationSettings()
        XCTAssertTrue(settings.checksOften)
        XCTAssertTrue(settings.notifies)
        XCTAssertEqual(InboxReveal.tab(for: .slack, current: .gmail), .all)
        XCTAssertEqual(InboxReveal.tab(for: .slack, current: .slack), .slack)
        XCTAssertEqual(InboxReveal.tab(for: .gmail, current: .all), .all)
    }
}

// MARK: - Checking and notifying

@MainActor
final class MessagePollingFlowTests: XCTestCase {
    var dir: URL!
    var server: FakeIntegrationServer!
    private var stores: [Store] = []
    private var alerts: AlertLog!

    override func setUp() async throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("docket-polling-\(UUID().uuidString)")
        server = FakeIntegrationServer()
        alerts = AlertLog()
        Keychain.useInMemoryStore()
    }

    override func tearDown() async throws {
        stores = []
        Keychain.useInMemoryStore()
        try? FileManager.default.removeItem(at: dir)
    }

    private func make(slack: Bool = true, gmail: Bool = false, checkedBefore: Bool = false, triage: SuggestionTriage = .none,
                      settings: IntegrationSettings = IntegrationSettings()) throws -> (Integrations, Store) {
        var file = IntegrationsFile()
        if slack {
            Keychain.set(Poll.token, for: Keychain.Account.slackUserToken)
            file.slack = Poll.account
        }
        if gmail {
            Keychain.set("1234-test.apps.googleusercontent.com", for: Keychain.Account.googleClientID)
            Keychain.set("test-client-secret", for: Keychain.Account.googleClientSecret)
            Keychain.set("1//test-refresh", for: Keychain.Account.googleRefreshToken)
            file.gmailAddress = Poll.address
        }
        if checkedBefore { file.lastRefresh = Date().addingTimeInterval(-3600) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try file.encoded().write(to: dir.appendingPathComponent("integrations.json"))
        let store = Store(persistence: Persistence(directory: dir), seedIfEmpty: false)
        stores.append(store)
        let integrations = Integrations(transport: server.transport, triage: triage, sleep: { _ in })
        integrations.settings = { settings }
        integrations.openURL = { _ in XCTFail("tests never open a browser") }
        integrations.alertSink = alerts.sink
        integrations.attach(store: store, app: nil, directory: dir)
        return (integrations, store)
    }

    /// Slack with no reactions and no DMs; `mentions` are search.messages' answers in turn.
    private func slackAnswers(mentions: [String], reactions: [String] = [Poll.noReactions]) {
        server.slack("reactions.list", replies: reactions)
        server.slack("search.messages", replies: mentions)
        server.slack("users.conversations", where: ("types", "im,mpim"), Poll.noConversations)
        Poll.names(on: server)
    }

    func testAQuickCheckSkipsWhileARefreshRunsWhenTurnedOffAndWhilePaused() async throws {
        let now = Date()
        slackAnswers(mentions: [Poll.search([Poll.mention("budget?", at: now.addingTimeInterval(-60))])])
        let (integrations, _) = try make()

        integrations.refresh()
        XCTAssertEqual(integrations.poll(), .refreshing, "never two checks at once")
        await integrations.waitForRefresh()
        let requests = server.requests.count
        XCTAssertNil(integrations.poll(now: now))
        await integrations.waitForRefresh()
        XCTAssertGreaterThan(server.requests.count, requests, "the quick check ran")

        // Asleep or locked: nothing; awake and unlocked again: one check at once to catch up.
        integrations.notePause(.sleep, true)
        integrations.notePause(.locked, true)
        XCTAssertEqual(integrations.poll(now: now), .asleep)
        integrations.notePause(.sleep, false)
        XCTAssertEqual(integrations.poll(now: now), .asleep, "still locked")
        let beforeWake = server.calls("search.messages").count
        integrations.notePause(.locked, false)
        await integrations.waitForRefresh()
        XCTAssertEqual(server.calls("search.messages").count, beforeWake + 1, "caught up once on waking")

        var off = IntegrationSettings()
        off.checksOften = false
        integrations.settings = { off }
        let before = server.requests.count
        XCTAssertEqual(integrations.poll(now: now), .turnedOff)
        await integrations.waitForRefresh()
        XCTAssertEqual(server.requests.count, before, "turned off: Slack isn't asked")
    }

    func testARateLimitPausesQuickChecksUntilItsOver() async throws {
        let now = Date()
        slackAnswers(mentions: [#"{"ok":false,"error":"ratelimited"}"#])
        let (integrations, _) = try make()

        await integrations.refreshNow(now: now)
        XCTAssertNotNil(integrations.slackProblem)
        let before = server.requests.count
        XCTAssertEqual(integrations.poll(now: now.addingTimeInterval(30)), .paused)
        XCTAssertEqual(server.requests.count, before)
        XCTAssertNil(integrations.pollSkip(now: now.addingTimeInterval(61)), "Slack's pause is over")
    }

    func testTheFirstCheckIsABacklogThenNewMessagesAreNotified() async throws {
        let now = Date()
        let budget = Poll.mention("can you approve the Q4 budget?", at: now.addingTimeInterval(-600))
        let deck = Poll.mention("please send the deck\\nbefore the board meeting", at: now.addingTimeInterval(60))
        let mine = Poll.mention("note to self", at: now.addingTimeInterval(70), user: Poll.me)
        slackAnswers(mentions: [Poll.search([budget]), Poll.search([deck, mine, budget])],
                     reactions: [Poll.noReactions, Poll.reaction(by: "U0SAM", at: now.addingTimeInterval(65))])
        let (integrations, _) = try make()

        await integrations.refreshNow(now: now)
        XCTAssertEqual(integrations.suggestions.count, 1)
        XCTAssertTrue(alerts.posted.isEmpty, "a first check's backlog never floods")
        XCTAssertTrue(integrations.newMessageIDs.isEmpty)

        await integrations.refreshNow(now: now.addingTimeInterval(120), mode: .quick)
        XCTAssertEqual(integrations.suggestions.count, 3, "the new mention and the 📌")
        let deckID = "slack:C0LEAD/\(Poll.ts(now.addingTimeInterval(60)))"
        XCTAssertEqual(alerts.all, [MessageAlert(itemID: deckID, title: "Priya Shah · #leadership",
                                                 body: "@Maya Chen please send the deck\nbefore the board meeting", threadID: "slack:C0LEAD")],
                       "only what others sent: not the 📌 the user put there, not their own message")
        XCTAssertEqual(integrations.newMessageIDs, [deckID])
        XCTAssertEqual(integrations.newMessageCount, 1)

        // Opening the panel sees them; handling one takes its notification back.
        integrations.markMessagesSeen()
        XCTAssertEqual(integrations.newMessageCount, 0)
        let item = try XCTUnwrap(integrations.suggestion(deckID))
        integrations.dismiss(item)
        XCTAssertEqual(alerts.withdrawn, [deckID])
    }

    func testAfterAnEarlierLaunchMoreThanThreeNewOnesAreOneSummary() async throws {
        let now = Date()
        let four = (1...4).map { Poll.mention("item \($0)", at: now.addingTimeInterval(TimeInterval($0))) }
        slackAnswers(mentions: [Poll.search(four)])
        let (integrations, _) = try make(checkedBefore: true)

        await integrations.refreshNow(now: now.addingTimeInterval(10))
        XCTAssertEqual(alerts.posted.count, 1)
        XCTAssertEqual(alerts.all.map(\.title), ["4 new Slack messages"])
        XCTAssertEqual(alerts.all.first?.body, "From Priya Shah")
        XCTAssertEqual(integrations.newMessageCount, 4)
    }

    func testNotificationsWaitForAFocusSessionAndCanBeTurnedOff() async throws {
        let now = Date()
        let one = Poll.mention("first", at: now.addingTimeInterval(10))
        let two = Poll.mention("second", at: now.addingTimeInterval(20))
        let three = Poll.mention("third", at: now.addingTimeInterval(30))
        slackAnswers(mentions: [Poll.search([]), Poll.search([one, two]), Poll.search([three, two])])
        var focusing = false
        let (integrations, _) = try make()
        integrations.isFocusing = { focusing }

        await integrations.refreshNow(now: now)
        focusing = true
        await integrations.refreshNow(now: now.addingTimeInterval(120), mode: .quick)
        XCTAssertEqual(integrations.suggestions.count, 2)
        XCTAssertTrue(alerts.posted.isEmpty, "nothing during a focus session")
        XCTAssertEqual(integrations.newMessageCount, 2, "the menu bar still shows them")

        // One handled meanwhile isn't announced afterwards.
        integrations.dismiss(try XCTUnwrap(integrations.suggestion("slack:C0LEAD/\(Poll.ts(now.addingTimeInterval(10)))")))
        focusing = false
        integrations.focusEnded()
        XCTAssertEqual(alerts.all.map(\.itemID), ["slack:C0LEAD/\(Poll.ts(now.addingTimeInterval(20)))"])
        await integrations.waitForFocusUpdates()

        // Notifications off: still new in the menu bar, no notification.
        var quiet = IntegrationSettings()
        quiet.notifies = false
        integrations.settings = { quiet }
        integrations.markMessagesSeen()
        let posted = alerts.posted.count
        await integrations.refreshNow(now: now.addingTimeInterval(240), mode: .quick)
        XCTAssertNotNil(integrations.suggestion("slack:C0LEAD/\(Poll.ts(now.addingTimeInterval(30)))"))
        XCTAssertEqual(alerts.posted.count, posted)
        XCTAssertEqual(integrations.newMessageCount, 1)
    }

    func testQuickChecksReadOnlyDirectMessagesWithSomethingNew() async throws {
        let now = Date()
        let samFirst = now.addingTimeInterval(-300)
        let samLater = now.addingTimeInterval(60)
        server.slack("reactions.list", Poll.noReactions)
        server.slack("search.messages", Poll.search([]))
        server.slack("users.conversations", where: ("types", "im,mpim"),
                     replies: [Poll.conversations(samLatest: samFirst), Poll.conversations(samLatest: samFirst), Poll.conversations(samLatest: samLater)])
        server.slack("conversations.history", where: ("channel", "D0SAM"),
                     replies: [Poll.history("U0SAM", "Can you send the offer letter?", at: samFirst),
                               Poll.history("U0SAM", "Also the hiring plan, please", at: samLater)])
        server.slack("conversations.history", where: ("channel", "D0PRIYA"), Poll.history("U0PRIYA", "Lunch on Friday?", at: now.addingTimeInterval(-900)))
        Poll.names(on: server)
        let (integrations, _) = try make()

        func reads(_ channel: String) -> [[String: String]] {
            server.calls("conversations.history").map(FakeIntegrationServer.form).filter { $0["channel"] == channel }
        }

        await integrations.refreshNow(now: now)
        XCTAssertEqual(reads("D0SAM").count, 1)
        XCTAssertEqual(reads("D0PRIYA").count, 1)
        XCTAssertEqual(integrations.directMessageMarks["D0SAM"]?.ts, Poll.ts(samFirst))
        XCTAssertEqual(integrations.suggestions.filter { $0.trigger == .directMessage }.count, 2)

        // Nothing new from Sam (Slack's `latest` hasn't moved): his DM isn't read. Priya's (Slack doesn't say)
        // is, but only after the message seen last.
        await integrations.refreshNow(now: now.addingTimeInterval(120), mode: .quick)
        XCTAssertEqual(reads("D0SAM").count, 1, "an unchanged DM isn't read again")
        XCTAssertEqual(reads("D0PRIYA").count, 2)
        XCTAssertEqual(reads("D0PRIYA").last?["oldest"], Poll.ts(now.addingTimeInterval(-900)))
        XCTAssertTrue(alerts.posted.isEmpty)

        // Sam writes again: his DM is read from the last message seen, and the new message is notified.
        await integrations.refreshNow(now: now.addingTimeInterval(240), mode: .quick)
        XCTAssertEqual(reads("D0SAM").count, 2)
        XCTAssertEqual(reads("D0SAM").last?["oldest"], Poll.ts(samFirst))
        let samID = "slack:D0SAM/\(Poll.ts(samLater))"
        XCTAssertEqual(alerts.all, [MessageAlert(itemID: samID, title: "Sam Lee · DM", body: "Also the hiring plan, please", threadID: "slack:D0SAM")])
        XCTAssertEqual(integrations.suggestions.filter { $0.id.hasPrefix("slack:D0SAM/") }.map(\.id), [samID], "one card per DM")

        // A full check reads every DM from the start of the window again.
        await integrations.refreshNow(now: now.addingTimeInterval(360))
        XCTAssertEqual(reads("D0SAM").count, 3)
        XCTAssertEqual(reads("D0SAM").last?["oldest"], Poll.ts(now.addingTimeInterval(360).addingTimeInterval(-Integrations.mentionsWindow)))
    }

    func testQuickChecksFetchOnlyEmailsNotSeenBeforeAndNotifyNewOnes() async throws {
        let now = Date()
        server.google("/token", .init(body: Poll.accessToken))
        server.gmail("messages", query: GmailClient.starredQuery, #"{"resultSizeEstimate":0}"#)
        server.gmail("messages", query: GmailClient.needsReplyQuery,
                     .init(body: Poll.list([("m1", "t1")])), .init(body: Poll.list([("m1", "t1")])), .init(body: Poll.list([("m1", "t1")])),
                     .init(body: Poll.list([("m2", "t2"), ("m3", "t3"), ("m1", "t1")])))
        server.gmail("messages/m1", Poll.email("m1", thread: "t1", from: "Sam Lee <sam.lee@northwind.example>", subject: "Q3 numbers",
                                               snippet: "Can you send the final numbers?", at: now.addingTimeInterval(-7200)))
        server.gmail("messages/m2", Poll.email("m2", thread: "t2", from: "Priya Shah <priya@contoso.example>", subject: "Intro: Contoso",
                                               snippet: "Are you free to meet the team next week?", at: now.addingTimeInterval(60)))
        server.gmail("messages/m3", Poll.email("m3", thread: "t3", from: "Maya Chen <Maya@acme.example>", subject: "Reminder",
                                               snippet: "Book the venue", at: now.addingTimeInterval(70)))
        var aiFails = true
        let triage = SuggestionTriage(isAvailable: { true }, run: { messages, _, _ in
            if aiFails { throw URLError(.timedOut) }
            return Dictionary(uniqueKeysWithValues: messages.map { ($0.source.externalID, TaskDraft(title: "Reply")) })
        })
        let (integrations, _) = try make(slack: false, gmail: true, triage: triage)
        func fetches(_ id: String) -> Int { server.requests(toPath: "/gmail/v1/users/me/messages/\(id)").count }

        // AI couldn't sort it: a full check fetches it again, a quick one doesn't.
        await integrations.refreshNow(now: now)
        XCTAssertTrue(integrations.suggestions.isEmpty)
        XCTAssertEqual(fetches("m1"), 1)
        await integrations.refreshNow(now: now.addingTimeInterval(120), mode: .quick)
        XCTAssertEqual(fetches("m1"), 1, "fetched before: a quick check leaves it")
        await integrations.refreshNow(now: now.addingTimeInterval(240))
        XCTAssertEqual(fetches("m1"), 2, "a full check retries it")
        XCTAssertTrue(alerts.posted.isEmpty)

        // New mail: only the new ones are fetched, and the one from someone else is notified.
        aiFails = false
        await integrations.refreshNow(now: now.addingTimeInterval(360), mode: .quick)
        XCTAssertEqual(fetches("m1"), 2)
        XCTAssertEqual(fetches("m2"), 1)
        XCTAssertEqual(fetches("m3"), 1)
        XCTAssertEqual(Set(integrations.suggestions.map(\.id)), ["gmail:t2/m2", "gmail:t3/m3"])
        XCTAssertEqual(alerts.all, [MessageAlert(itemID: "gmail:t2/m2", title: "Priya Shah · Email",
                                                 body: "Intro: Contoso\nAre you free to meet the team next week?", threadID: "gmail:t2")],
                       "not the email Maya sent herself")

        // Quick checks go on with Gmail alone.
        XCTAssertNil(integrations.pollSkip(now: now.addingTimeInterval(400)))
    }

    func testANewConnectionsFirstCheckIsABacklogToo() async throws {
        let now = Date()
        slackAnswers(mentions: [Poll.search([Poll.mention("hello", at: now.addingTimeInterval(-60))])])
        server.slack("auth.test", #"{"ok":true,"url":"https://acme-test.slack.com/","team":"Acme Test","user":"maya","team_id":"T0ACME","user_id":"U0MAYA"}"#)
        let (integrations, _) = try make(slack: false, gmail: false, checkedBefore: true)

        try await integrations.connectSlack(token: Poll.token)
        await integrations.waitForRefresh()
        XCTAssertEqual(integrations.suggestions.count, 1)
        XCTAssertTrue(alerts.posted.isEmpty, "Slack was just connected: what's there is the backlog")
    }
}
