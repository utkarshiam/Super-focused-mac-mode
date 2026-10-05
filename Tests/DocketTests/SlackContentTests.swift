import SwiftUI
import XCTest
@testable import Docket

// The complete Slack message without the network: files, the rest of a thread and the whole of it, replying
// in it, saving messages for later (stars), downloads, and Slack's mrkdwn as rich text. A fake server answers
// from canned JSON (made-up workspace Acme Test; people Maya Chen, Priya Shah, Sam Lee, Dana Whitfield).

private enum SlackFixture {
    static let token = "xoxp-1111-2222-3333-test"
    static let me = "U0MAYA"

    static func ts(_ date: Date) -> String { String(format: "%.6f", date.timeIntervalSince1970) }

    static func user(_ id: String, _ name: String) -> String {
        #"{"ok":true,"user":{"id":"\#(id)","name":"\#(name.lowercased())","real_name":"\#(name)","profile":{"real_name":"\#(name)"}}}"#
    }

    static func file(_ id: String, _ path: String) -> URL {
        URL(string: "https://files.slack.com/files-pri/T0ACME-\(id)/\(path)")!
    }

    /// What Maya saved with 📌: a reply in a thread with files (an image, a PDF, a snippet, and ones Docket
    /// can't show), the thread's parent, and a message that's only two files.
    static func savedWithFiles(now: Date, parent: String) -> String {
        """
        {"ok":true,"items":[
          {"type":"message","channel":"C0LEAD","message":{"type":"message","ts":"\(ts(now.addingTimeInterval(-3600)))","user":"U0PRIYA",
            "text":"Board pack for Thursday, see the chart","thread_ts":"\(parent)",
            "permalink":"https://acme-test.slack.com/archives/C0LEAD/p1000?thread_ts=\(parent)&cid=C0LEAD",
            "reactions":[{"name":"pushpin","users":["U0MAYA"],"count":1}],
            "files":[
              {"id":"F0CHART","name":"q3-chart.png","title":"Q3 chart","mimetype":"image/png","filetype":"png","size":48213,"mode":"hosted",
               "url_private":"https://files.slack.com/files-pri/T0ACME-F0CHART/q3-chart.png",
               "url_private_download":"https://files.slack.com/files-pri/T0ACME-F0CHART/download/q3-chart.png",
               "thumb_64":"https://files.slack.com/files-tmb/T0ACME-F0CHART-1a2b/q3-chart_64.png",
               "thumb_360":"https://files.slack.com/files-tmb/T0ACME-F0CHART-1a2b/q3-chart_360.png",
               "thumb_480":"https://files.slack.com/files-tmb/T0ACME-F0CHART-1a2b/q3-chart_480.png"},
              {"id":"F0BUDGET","name":"budget.pdf","title":"Q4 budget","mimetype":"application/pdf","size":52000,"mode":"hosted",
               "url_private":"https://files.slack.com/files-pri/T0ACME-F0BUDGET/budget.pdf",
               "url_private_download":"https://files.slack.com/files-pri/T0ACME-F0BUDGET/download/budget.pdf"},
              {"id":"F0MINUTES","name":"minutes.txt","mimetype":"","size":812,"mode":"snippet",
               "url_private":"https://files.slack.com/files-pri/T0ACME-F0MINUTES/minutes.txt"},
              {"id":"F0GONE","mode":"tombstone"},
              {"id":"F0OLD","mode":"hidden_by_limit"},
              {"id":"F0DRIVE","name":"Hiring plan","mimetype":"application/vnd.google-apps.document","mode":"external","is_external":true,
               "url_private":"https://docs.example.com/document/d/hiring"},
              {"id":"F0ODD","name":"odd.png","mimetype":"image/png","mode":"hosted","url_private":"https://cdn.example.net/odd.png"},
              {"id":"F0CANVAS","name":"Offsite agenda","mimetype":"application/vnd.slack-docs","mode":"quip",
               "url_private":"https://files.slack.com/files-pri/T0ACME-F0CANVAS/canvas"},
              {"id":"F0CHART","name":"q3-chart.png","mimetype":"image/png","mode":"hosted",
               "url_private":"https://files.slack.com/files-pri/T0ACME-F0CHART/q3-chart.png"},
              {"id":"F0WEIRD","name":"weird.bin","size":"big","url_private":"https://files.slack.com/files-pri/T0ACME-F0WEIRD/weird.bin"}
            ]}},
          {"type":"message","channel":"C0LEAD","message":{"ts":"\(parent)","user":"U0PRIYA","text":"The board pack thread",
            "thread_ts":"\(parent)","reply_count":4,"reactions":[{"name":"pushpin","users":["U0MAYA"],"count":1}]}},
          {"type":"message","channel":"C0GEN","message":{"ts":"\(ts(now.addingTimeInterval(-5400)))","user":"U0SAM","text":"",
            "files":[
              {"id":"F0DECK","name":"deck.key","title":"Offsite deck","mimetype":"application/x-iwork-keynote-sffkey","size":1048576,
               "url_private_download":"https://files.slack.com/files-pri/T0ACME-F0DECK/download/deck.key"},
              {"id":"F0PHOTO","name":"IMG_0042.HEIC","mimetype":"image/heic","size":2097152,
               "url_private_download":"https://files.slack.com/files-pri/T0ACME-F0PHOTO/download/img_0042.heic",
               "thumb_360":"https://files.slack.com/files-tmb/T0ACME-F0PHOTO-9z/img_0042_360.jpg",
               "thumb_480":"https://cdn.example.net/img_0042_480.jpg"}
            ],
            "reactions":[{"name":"pushpin","users":["U0MAYA"],"count":1}]}}
        ],"response_metadata":{"next_cursor":""}}
        """
    }

    /// Saved messages that share something: a forwarded message, an app's card and a link preview under
    /// a question; a share on its own; a card on its own; a link preview on its own.
    static func savedShares(now: Date) -> String {
        func message(_ minutesAgo: Double, _ body: String) -> String {
            #"{"type":"message","channel":"C0LEAD","message":{"ts":"\#(ts(now.addingTimeInterval(-minutesAgo * 60)))","user":"U0PRIYA",\#(body),"reactions":[{"name":"pushpin","users":["U0MAYA"],"count":1}]}}"#
        }
        let items = [
            message(10, #""text":"Can you take this one?","attachments":[{"is_msg_unfurl":true,"author_name":"Sam Lee","text":"The customer wants a refund by Friday\nOrder 1042","fallback":"[Sam Lee] The customer wants a refund"},{"from_url":"https://reports.example/q3","original_url":"https://reports.example/q3","title":"Q3 report","text":"Revenue up 12%"},{"pretext":"New pull request","title":"Fix the totals","title_link":"https://git.example/acme/pull/12","text":"Totals were off by one","fields":[{"title":"Status","value":"Open"},{"title":"","value":"2 files changed"},{"title":"Reviewers","value":""}]}]"#),
            message(20, #""text":"","attachments":[{"is_share":true,"author_name":"Priya Shah","text":"Board moved to Thursday"}]"#),
            message(30, #""text":"","attachments":[{"title":"Deploy finished","text":"v2.3 is live","fields":[{"title":"Env","value":"production"}]}]"#),
            message(40, #""text":"","attachments":[{"from_url":"https://reports.example/q3","title":"Q3 report","text":"Revenue up 12%"}]"#),
        ]
        return #"{"ok":true,"items":[\#(items.joined(separator: ","))],"response_metadata":{"next_cursor":""}}"#
    }

    // A thread in #leadership, at fixed times. Maya has Priya's question open; Sam answered it since.
    static let parentTS = "1791200000.000100"
    static let openTS = "1791200500.000600"
    static let dueDate = Date(timeIntervalSince1970: 1_791_547_200)

    static let replies = #"""
    {"ok":true,"messages":[
      {"type":"message","ts":"1791200000.000100","user":"U0PRIYA","text":"Can everyone send their *Q4 numbers* by Friday?","thread_ts":"1791200000.000100","reply_count":7},
      {"type":"message","ts":"1791200100.000200","user":"U0SAM","text":"Mine are in the <https://docs.example.com/q4|sheet> :+1:","thread_ts":"1791200000.000100","user_profile":{"real_name":"Sam Lee","display_name":"sam"}},
      {"type":"message","subtype":"channel_join","ts":"1791200150.000000","user":"U0NEW","text":"<@U0NEW> has joined the channel"},
      {"type":"message","ts":"1791200200.000300","user":"U0MAYA","text":"Sending mine tonight","thread_ts":"1791200000.000100"},
      {"type":"message","subtype":"tombstone","ts":"1791200250.000000","text":"This message was deleted.","hidden":true,"thread_ts":"1791200000.000100"},
      {"type":"message","subtype":"bot_message","ts":"1791200300.000400","bot_id":"B0CAL","username":"reminders","bot_profile":{"name":"Calendar"},"text":"Numbers are due <!date^1791547200^{date_short} at {time}|Fri 9 Oct>","thread_ts":"1791200000.000100"},
      {"type":"message","ts":"1791200400.000500","user":"U0PRIYA","text":"Thanks all &amp; :tada:","thread_ts":"1791200000.000100"},
      {"type":"message","ts":"1791200450.000550","user":"U0SAM","text":"","thread_ts":"1791200000.000100"},
      {"type":"message","ts":"1791200500.000600","user":"U0PRIYA","text":"<@U0MAYA> can you check Sam's numbers?","thread_ts":"1791200000.000100"},
      {"type":"message","ts":"1791200600.000700","user":"U0SAM","text":"Checked them, all good <@U0DANA>","thread_ts":"1791200000.000100"},
      {"bogus":1}
    ],"has_more":false,"response_metadata":{"next_cursor":""}}
    """#

    /// A message in a thread, as conversations.replies sends it.
    static func reply(_ ts: String, _ name: String, _ text: String) -> String {
        #"{"ts":"\#(ts)","user":"U0\#(name.uppercased())","text":"\#(text)","user_profile":{"real_name":"\#(name)"}}"#
    }
}

/// How long a client was told to wait.
private actor Waits {
    var seconds: [TimeInterval] = []
    func add(_ s: TimeInterval) { seconds.append(s) }
}

// MARK: - Files and threads in the messages Docket finds

final class SlackMessageContentTests: XCTestCase {
    func testSavedMessagesCarryTheirFilesWithoutDeletedHiddenOrOutsideOnes() async throws {
        let now = Date()
        let parent = SlackFixture.ts(now.addingTimeInterval(-7200))
        let server = FakeIntegrationServer()
        server.slack("reactions.list", SlackFixture.savedWithFiles(now: now, parent: parent))
        let saved = try await SlackClient(token: SlackFixture.token, transport: server.transport)
            .savedMessages(by: SlackFixture.me, emoji: "pushpin", since: now.addingTimeInterval(-30 * 86_400))
        XCTAssertEqual(saved.count, 3)

        // Deleted, hidden, Google Drive, canvas, non-Slack and unreadable files are left out; a repeat counts once.
        let files = saved[0].files
        XCTAssertEqual(files.map(\.id), ["F0CHART", "F0BUDGET", "F0MINUTES"])
        XCTAssertEqual(files[0], MessageAttachment(
            id: "F0CHART", name: "q3-chart.png", mimeType: "image/png", size: 48_213,
            remote: .slack(url: SlackFixture.file("F0CHART", "download/q3-chart.png"),
                           thumbnail: URL(string: "https://files.slack.com/files-tmb/T0ACME-F0CHART-1a2b/q3-chart_480.png"))))
        XCTAssertTrue(files[0].isImage)
        XCTAssertEqual(files[1].remote, .slack(url: SlackFixture.file("F0BUDGET", "download/budget.pdf"), thumbnail: nil))
        XCTAssertEqual(files[1].size, 52_000)
        XCTAssertFalse(files[1].isImage)
        // No download link: the private one. No type from Slack: one from the name.
        XCTAssertEqual(files[2].remote, .slack(url: SlackFixture.file("F0MINUTES", "minutes.txt"), thumbnail: nil))
        XCTAssertEqual(files[2].mimeType, "text/plain")
        XCTAssertTrue(files.allSatisfy { $0.contentID == nil })

        // A reply knows its thread; the parent of a thread is not a reply.
        XCTAssertEqual(saved[0].threadTS, parent)
        XCTAssertEqual(saved[1].ts, parent)
        XCTAssertNil(saved[1].threadTS)
        XCTAssertTrue(saved[1].files.isEmpty)

        // Files only: their names stand in for the text. A thumbnail away from Slack is dropped.
        XCTAssertEqual(saved[2].text, "Shared 2 files: Offsite deck, IMG_0042.HEIC")
        XCTAssertEqual(saved[2].files.map(\.name), ["deck.key", "IMG_0042.HEIC"])
        XCTAssertEqual(saved[2].files[1].remote, .slack(url: SlackFixture.file("F0PHOTO", "download/img_0042.heic"),
                                                       thumbnail: URL(string: "https://files.slack.com/files-tmb/T0ACME-F0PHOTO-9z/img_0042_360.jpg")))
        XCTAssertTrue(saved[2].files[1].isImage)
        XCTAssertNil(saved[2].threadTS)
    }

    func testMentionsCarryFilesAndTheirThreadFromThePermalink() async throws {
        let now = Date()
        let parent = SlackFixture.ts(now.addingTimeInterval(-4000))
        let server = FakeIntegrationServer()
        server.slack("search.messages", """
        {"ok":true,"messages":{"matches":[
          {"type":"message","channel":{"id":"C0LEAD","name":"leadership"},"user":"U0PRIYA","username":"priya",
           "ts":"\(SlackFixture.ts(now.addingTimeInterval(-600)))","text":"<@U0MAYA> numbers attached",
           "permalink":"https://acme-test.slack.com/archives/C0LEAD/p2000?thread_ts=\(parent)&cid=C0LEAD",
           "files":[{"id":"F0NUMS","name":"numbers.xlsx","title":"Q4 numbers","mimetype":"application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
                     "size":20480,"url_private_download":"https://files.slack.com/files-pri/T0ACME-F0NUMS/download/numbers.xlsx"}]},
          {"type":"message","channel":{"id":"C0GEN","name":"general"},"user":"U0SAM","ts":"\(SlackFixture.ts(now.addingTimeInterval(-900)))",
           "text":"<@U0MAYA> a message of its own","permalink":"https://acme-test.slack.com/archives/C0GEN/p3000"}
        ]}}
        """)
        let mentions = try await SlackClient(token: SlackFixture.token, transport: server.transport)
            .mentions(of: SlackFixture.me, since: now.addingTimeInterval(-3 * 86_400))
        XCTAssertEqual(mentions.count, 2)
        XCTAssertEqual(mentions[0].threadTS, parent, "search results say so only in the permalink")
        XCTAssertEqual(mentions[0].files.map(\.id), ["F0NUMS"])
        XCTAssertEqual(mentions[0].files.first?.mimeType, "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet")
        XCTAssertNil(mentions[1].threadTS)
        XCTAssertTrue(mentions[1].files.isEmpty)
    }

    func testSharedMessagesAndAppCardsAreTheCompleteMessage() async throws {
        let now = Date()
        let server = FakeIntegrationServer()
        server.slack("reactions.list", SlackFixture.savedShares(now: now))
        let saved = try await SlackClient(token: SlackFixture.token, transport: server.transport)
            .savedMessages(by: SlackFixture.me, emoji: "pushpin", since: now.addingTimeInterval(-86_400))
        XCTAssertEqual(saved.count, 4)

        // Under words of its own: the forwarded message and the app's card, quoted; the link preview left out.
        XCTAssertEqual(saved[0].text, """
        Can you take this one?
        &gt; Sam Lee: The customer wants a refund by Friday
        &gt; Order 1042
        &gt; New pull request
        &gt; <https://git.example/acme/pull/12|Fix the totals>
        &gt; Totals were off by one
        &gt; Status: Open
        &gt; 2 files changed
        """)
        XCTAssertEqual(SlackText.readable(saved[0].text), """
        Can you take this one?
        > Sam Lee: The customer wants a refund by Friday
        > Order 1042
        > New pull request
        > Fix the totals
        > Totals were off by one
        > Status: Open
        > 2 files changed
        """)
        // Someone else's words are quoted even alone; an app's card alone is the message.
        XCTAssertEqual(saved[1].text, "&gt; Priya Shah: Board moved to Thursday")
        XCTAssertEqual(saved[2].text, "Deploy finished\nv2.3 is live\nEnv: production")
        XCTAssertEqual(saved[3].text, "Revenue up 12%", "a link preview alone still gives words")
    }
}

// MARK: - The rest of the thread

final class SlackThreadTests: XCTestCase {
    func testTheThreadIsTheEarlierMessagesOldestFirstByName() async throws {
        let server = FakeIntegrationServer()
        server.slack("conversations.replies", SlackFixture.replies)
        server.slack("users.info", where: ("user", "U0PRIYA"), SlackFixture.user("U0PRIYA", "Priya Shah"))
        server.slack("users.info", where: ("user", "U0MAYA"), SlackFixture.user("U0MAYA", "Maya Chen"))
        let client = SlackClient(token: SlackFixture.token, transport: server.transport)

        let thread = try await client.thread(channel: "C0LEAD", threadTS: SlackFixture.parentTS, excluding: SlackFixture.openTS,
                                             limit: 20, myUserID: SlackFixture.me)
        // Before the open message, without joins, deleted, empty and unreadable ones.
        XCTAssertEqual(thread.map(\.id), ["slack:C0LEAD/1791200000.000100", "slack:C0LEAD/1791200100.000200",
                                          "slack:C0LEAD/1791200200.000300", "slack:C0LEAD/1791200300.000400",
                                          "slack:C0LEAD/1791200400.000500"])
        XCTAssertEqual(thread.map(\.from), ["Priya Shah", "Sam Lee", "Maya Chen", "Calendar", "Priya Shah"])
        XCTAssertEqual(thread.map(\.isMine), [false, false, true, false, false])
        XCTAssertEqual(thread.map(\.text), [
            "Can everyone send their Q4 numbers by Friday?",
            "Mine are in the sheet 👍",
            "Sending mine tonight",
            "Numbers are due \(Fmt.absoluteDay(SlackFixture.dueDate)) at \(Fmt.time(SlackFixture.dueDate))",
            "Thanks all & 🎉",
        ])
        XCTAssertEqual(thread[0].date.timeIntervalSince1970, 1_791_200_000.0001, accuracy: 0.000_01)

        let request = try XCTUnwrap(server.calls("conversations.replies").first)
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer \(SlackFixture.token)")
        let form = FakeIntegrationServer.form(request)
        XCTAssertEqual(form["channel"], "C0LEAD")
        XCTAssertEqual(form["ts"], SlackFixture.parentTS)
        XCTAssertEqual(form["limit"], "200")
        XCTAssertNil(form["cursor"])
        // Sam came with his name; the others were looked up once each.
        XCTAssertEqual(Set(server.calls("users.info").map { FakeIntegrationServer.form($0)["user"] }), ["U0PRIYA", "U0MAYA"])

        // Names already known aren't looked up again.
        let before = server.calls("users.info").count
        let again = try await client.thread(channel: "C0LEAD", threadTS: SlackFixture.parentTS, excluding: SlackFixture.openTS, limit: 20,
                                            myUserID: SlackFixture.me, names: ["U0PRIYA": "Priya Shah", "U0MAYA": "Maya Chen"])
        XCTAssertEqual(again, thread)
        XCTAssertEqual(server.calls("users.info").count, before)
    }

    func testALongThreadKeepsItsStartAndTheRepliesClosestToTheMessage() {
        let thread = (1...10).map { "17912000\(String(format: "%02d", $0)).000100" }
        func pick(around n: Int, limit: Int) -> [Int] {
            SlackClient.threadWindow(thread.shuffled(), around: "17912000\(String(format: "%02d", n)).000100", limit: limit)
                .map { Int($0.dropFirst(8).prefix(2))! }
        }
        XCTAssertEqual(pick(around: 7, limit: 20), [1, 2, 3, 4, 5, 6, 8, 9, 10], "short enough: every other message")
        XCTAssertEqual(pick(around: 7, limit: 4), [1, 5, 6, 8], "the start, then the closest, earlier first")
        XCTAssertEqual(pick(around: 10, limit: 3), [1, 8, 9], "the newest message: the start and what led up to it")
        XCTAssertEqual(pick(around: 1, limit: 3), [2, 3, 4], "the parent: its first replies")
        XCTAssertEqual(pick(around: 7, limit: 1), [1])
        XCTAssertEqual(pick(around: 7, limit: 0), [])
        XCTAssertEqual(SlackClient.threadWindow(["1.5", "1.5", "2.0"], around: "2.000000", limit: 5), ["1.5"], "each once, never the message")
    }

    func testTimestampsCompareExactly() {
        XCTAssertTrue(SlackClient.isTimestamp("1791200000.000100"))
        for bad in ["", "1791200000", "1791200000.", ".000100", "1791200000.0001x", "p1791200000000100", "-1.5", "1.2.3"] {
            XCTAssertFalse(SlackClient.isTimestamp(bad), bad)
        }
        XCTAssertEqual(SlackClient.compare("1791200000.000099", "1791200000.000100"), -1)
        XCTAssertEqual(SlackClient.compare("1791200000.0001", "1791200000.000100"), 0)
        XCTAssertEqual(SlackClient.compare("999.900000", "1000.100000"), -1, "by time, not as text")
        XCTAssertEqual(SlackClient.compare("1791200000.000101", "1791200000.000100"), 1)
    }

    func testLongThreadsArePagedOnlyAsFarAsTheMessage() async throws {
        typealias F = SlackFixture
        let server = FakeIntegrationServer()
        server.slack("conversations.replies", """
        {"ok":true,"messages":[\(F.reply("1791200000.000100", "Priya", "Plan for the offsite?")),
          \(F.reply("1791200100.000200", "Sam", "Thursday works"))],"has_more":true,"response_metadata":{"next_cursor":"page2"}}
        """, """
        {"ok":true,"messages":[\(F.reply("1791200200.000300", "Priya", "Booked")),
          \(F.reply("1791200300.000400", "Sam", "Can someone order lunch?")),
          \(F.reply("1791200400.000500", "Priya", "Done"))],"has_more":true,"response_metadata":{"next_cursor":"page3"}}
        """)
        let client = SlackClient(token: SlackFixture.token, transport: server.transport)
        let thread = try await client.thread(channel: "C0LEAD", threadTS: F.parentTS, excluding: "1791200300.000400",
                                             limit: 5, myUserID: F.me)
        XCTAssertEqual(thread.map(\.text), ["Plan for the offsite?", "Thursday works", "Booked"])
        let pages = server.calls("conversations.replies")
        XCTAssertEqual(pages.count, 2, "the second page reaches the message: the rest are later")
        XCTAssertEqual(FakeIntegrationServer.form(pages[1])["cursor"], "page2")
        XCTAssertTrue(server.calls("users.info").isEmpty, "names came with the messages")

        // More than `limit`: the start, then the ones just before the message.
        let long = FakeIntegrationServer()
        long.slack("conversations.replies", """
        {"ok":true,"messages":[\(F.reply("1791200000.000100", "Priya", "Plan for the offsite?")),
          \(F.reply("1791200100.000200", "Sam", "Thursday works")), \(F.reply("1791200200.000300", "Priya", "Booked")),
          \(F.reply("1791200300.000400", "Sam", "Can someone order lunch?")), \(F.reply("1791200400.000500", "Priya", "Done"))],
         "has_more":false,"response_metadata":{"next_cursor":""}}
        """)
        let longClient = SlackClient(token: SlackFixture.token, transport: long.transport)
        let short = try await longClient.thread(channel: "C0LEAD", threadTS: F.parentTS, excluding: "1791200400.000500", limit: 2,
                                                myUserID: F.me)
        XCTAssertEqual(short.map(\.text), ["Plan for the offsite?", "Can someone order lunch?"])

        // The parent itself has nothing earlier.
        let parent = try await longClient.thread(channel: "C0LEAD", threadTS: F.parentTS, excluding: F.parentTS, limit: 5, myUserID: F.me)
        XCTAssertEqual(parent, [])
        XCTAssertEqual(long.calls("conversations.replies").count, 2)
    }

    func testThreadsNeedTheHistoryPermissionAndAGoneOneIsEmpty() async throws {
        let server = FakeIntegrationServer()
        server.slack("conversations.replies", replies: [
            #"{"ok":false,"error":"missing_scope","needed":"channels:history","provided":"reactions:read,search:read,users:read"}"#,
            #"{"ok":false,"error":"thread_not_found"}"#,
        ])
        let client = SlackClient(token: SlackFixture.token, transport: server.transport)
        do {
            _ = try await client.thread(channel: "C0LEAD", threadTS: SlackFixture.parentTS, excluding: SlackFixture.openTS, limit: 10,
                                        myUserID: SlackFixture.me)
            XCTFail("an app without channels:history can't read threads")
        } catch {
            XCTAssertEqual(error as? IntegrationError, .missingPermission(.slack, "channels:history"))
        }
        let gone = try await client.thread(channel: "C0LEAD", threadTS: SlackFixture.parentTS, excluding: SlackFixture.openTS, limit: 10,
                                           myUserID: SlackFixture.me)
        XCTAssertEqual(gone, [])

        // Nothing to ask for: no call at all.
        let calls = server.requests.count
        let none = try await client.thread(channel: "C0LEAD", threadTS: SlackFixture.parentTS, excluding: SlackFixture.openTS, limit: 0,
                                           myUserID: SlackFixture.me)
        let notATimestamp = try await client.thread(channel: "C0LEAD", threadTS: "p1791200000000100", excluding: SlackFixture.openTS,
                                                    limit: 10, myUserID: SlackFixture.me)
        XCTAssertEqual(none + notATimestamp, [])
        XCTAssertEqual(server.requests.count, calls)
    }
}

// MARK: - Replying and downloading

final class SlackReplyAndDownloadTests: XCTestCase {
    func testAReplyGoesInTheThreadAsYouEscapedForSlack() async throws {
        let server = FakeIntegrationServer()
        server.slack("chat.postMessage", #"{"ok":true,"channel":"C0LEAD","ts":"1791200700.000800"}"#)
        let client = SlackClient(token: SlackFixture.token, transport: server.transport)
        try await client.reply(channel: "C0LEAD", threadTS: SlackFixture.parentTS, text: """
          Got it, *sending tonight*.
        > can you check Sam's numbers?
        Looks right & <the sheet> is <https://docs.example.com/q4?tab=2&view=all|here>. <!channel> <@U0SAM>

        """)

        let request = try XCTUnwrap(server.calls("chat.postMessage").first)
        XCTAssertEqual(request.url?.absoluteString, "https://slack.com/api/chat.postMessage")
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer \(SlackFixture.token)")
        let form = FakeIntegrationServer.form(request)
        XCTAssertEqual(Set(form.keys), ["channel", "thread_ts", "text"], "in the thread only: no broadcast to the channel")
        XCTAssertEqual(form["channel"], "C0LEAD")
        XCTAssertEqual(form["thread_ts"], SlackFixture.parentTS)
        XCTAssertEqual(form["text"], """
        Got it, *sending tonight*.
        &gt; can you check Sam's numbers?
        Looks right &amp; &lt;the sheet&gt; is <https://docs.example.com/q4?tab=2&amp;view=all|here>. &lt;!channel&gt; <@U0SAM>
        """, "trimmed; links and mentions kept, everything else escaped, never an @channel")

        // Text a caller already escaped for Slack goes out the same, not escaped twice.
        try await client.reply(channel: "C0LEAD", threadTS: SlackFixture.parentTS, text: "Q&amp;A at 3 &lt;3 <https://docs.example.com/q4?a=1&amp;b=2|notes>")
        XCTAssertEqual(FakeIntegrationServer.form(try XCTUnwrap(server.calls("chat.postMessage").last))["text"],
                       "Q&amp;A at 3 &lt;3 <https://docs.example.com/q4?a=1&amp;b=2|notes>")
    }

    func testRepliesSayWhatWentWrongAndNeverSendNothing() async throws {
        let server = FakeIntegrationServer()
        server.slack("chat.postMessage", replies: [
            #"{"ok":false,"error":"msg_too_long"}"#,
            #"{"ok":false,"error":"not_in_channel"}"#,
            #"{"ok":false,"error":"missing_scope","needed":"chat:write"}"#,
            #"{"ok":false,"error":"cannot_reply_to_message"}"#,
            #"{"ok":false,"error":"invalid_auth"}"#,
        ])
        let client = SlackClient(token: SlackFixture.token, transport: server.transport)
        let expected: [IntegrationError] = [
            .api(.slack, "That reply is too long for one Slack message."),
            .api(.slack, "Join that channel in Slack first, then try again."),
            .missingPermission(.slack, "chat:write"),
            .api(.slack, "Slack doesn't take replies to that message. Reply in Slack instead."),
            .signedOut(.slack),
        ]
        for want in expected {
            do {
                try await client.reply(channel: "C0LEAD", threadTS: SlackFixture.parentTS, text: "On it")
                XCTFail("expected \(want)")
            } catch {
                XCTAssertEqual(error as? IntegrationError, want)
            }
        }

        let calls = server.requests.count
        for (thread, text) in [(SlackFixture.parentTS, " \n\t "), ("p1791200000000100", "On it"), ("", "On it")] {
            do {
                try await client.reply(channel: "C0LEAD", threadTS: thread, text: text)
                XCTFail("nothing to send, or nowhere to send it")
            } catch {
                XCTAssertNotNil(error as? IntegrationError)
            }
        }
        XCTAssertEqual(server.requests.count, calls, "no request without text and a thread")
    }

    func testAReplyThatTimesOutSaysItMayHaveBeenPosted() async throws {
        let flaky: IntegrationHTTP.Transport = { request in
            throw URLError(request.url?.path == "/api/chat.postMessage" ? .networkConnectionLost : .timedOut)
        }
        let client = SlackClient(token: SlackFixture.token, transport: flaky)
        do {
            try await client.reply(channel: "C0LEAD", threadTS: SlackFixture.parentTS, text: "On it")
            XCTFail("it may or may not have gone")
        } catch {
            XCTAssertEqual(error as? IntegrationError,
                           .api(.slack, "Slack didn't answer in time, so Docket can't tell if the reply was posted. Check the thread in Slack before trying again."))
        }
        // Reading that times out is just slow.
        do {
            _ = try await client.download(SlackFixture.file("F0BUDGET", "download/budget.pdf"))
            XCTFail("must fail")
        } catch {
            XCTAssertEqual(error as? IntegrationError, .offline(.slack, "It took too long to answer."))
        }
    }

    func testDownloadsCarryTheTokenToSlackOnly() async throws {
        let server = FakeIntegrationServer()
        let budget = SlackFixture.file("F0BUDGET", "download/budget.pdf")
        server.on({ $0.url == budget }, [.init(body: "%PDF-1.7 test budget", headers: ["Content-Type": "application/pdf"])])
        let client = SlackClient(token: SlackFixture.token, transport: server.transport)

        let data = try await client.download(budget)
        XCTAssertEqual(String(decoding: data, as: UTF8.self), "%PDF-1.7 test budget")
        let request = try XCTUnwrap(server.requests.first)
        XCTAssertEqual(request.httpMethod, "GET")
        XCTAssertEqual(request.url, budget)
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer \(SlackFixture.token)")
        XCTAssertNil(request.httpBody)
        XCTAssertFalse(budget.absoluteString.contains("xoxp"), "never in the address")

        // Anywhere but Slack's own servers over https: refused before any request.
        for elsewhere in ["https://cdn.example.net/budget.pdf", "http://files.slack.com/files-pri/T0ACME-F0BUDGET/budget.pdf",
                          "https://files.slack.com.example.net/budget.pdf", "https://user:secret@files.slack.com/files-pri/x.pdf",
                          "https://files.slack.com:8443/files-pri/x.pdf", "https://notslack.com/files-pri/x.pdf", "file:///etc/hosts"] {
            let url = try XCTUnwrap(URL(string: elsewhere))
            do {
                _ = try await client.download(url)
                XCTFail("\(elsewhere) isn't Slack")
            } catch {
                XCTAssertEqual(error as? IntegrationError, .api(.slack, "That file isn't stored in Slack, so Docket can't download it."))
            }
        }
        XCTAssertEqual(server.requests.count, 1)
        XCTAssertTrue(SlackClient.isSlackFileURL(try XCTUnwrap(URL(string: "https://files.slack-gov.com/files-pri/T0/x.pdf"))))
        XCTAssertTrue(SlackClient.isSlackFileURL(try XCTUnwrap(URL(string: "https://FILES.Slack.com:443/files-pri/T0/x.pdf"))))
    }

    func testADownloadWithoutFilesReadPermissionSaysSo() async throws {
        let server = FakeIntegrationServer()
        let waits = Waits()
        // Without files:read, Slack sends its sign-in page instead of the file.
        server.on({ $0.url?.lastPathComponent == "budget.pdf" },
                  [.init(body: "<!DOCTYPE html><html><title>Sign in | Acme Test</title></html>", headers: ["Content-Type": "text/html; charset=utf-8"])])
        // An uploaded web page is still a file.
        server.on({ $0.url?.lastPathComponent == "agenda.html" }, [.init(body: "<html>Agenda</html>", headers: ["Content-Type": "text/html"])])
        server.on({ $0.url?.lastPathComponent == "gone.png" }, [.init(status: 404, body: "")])
        server.on({ $0.url?.lastPathComponent == "busy.png" }, [
            .init(status: 429, body: "", headers: ["Retry-After": "1"]),
            .init(body: "PNG", headers: ["Content-Type": "image/png"]),
        ])
        let client = SlackClient(token: SlackFixture.token, transport: server.transport, sleep: { await waits.add($0) })

        do {
            _ = try await client.download(SlackFixture.file("F0BUDGET", "download/budget.pdf"))
            XCTFail("a sign-in page isn't the file")
        } catch {
            XCTAssertEqual(error as? IntegrationError, .missingPermission(.slack, "files:read"))
        }
        let page = try await client.download(SlackFixture.file("F0AGENDA", "download/agenda.html"))
        XCTAssertEqual(String(decoding: page, as: UTF8.self), "<html>Agenda</html>")
        do {
            _ = try await client.download(SlackFixture.file("F0GONE", "download/gone.png"))
            XCTFail("a deleted file can't be downloaded")
        } catch {
            XCTAssertEqual(error as? IntegrationError, .api(.slack, "That file isn't in Slack any more."))
        }
        let busy = try await client.download(SlackFixture.file("F0BUSY", "download/busy.png"))
        XCTAssertEqual(String(decoding: busy, as: UTF8.self), "PNG")
        let waited = await waits.seconds
        XCTAssertEqual(waited, [1], "a short rate limit is waited out")
    }

    func testTheManifestAsksForFilesThreadsAndStars() throws {
        XCTAssertTrue(SlackManifest.contentScopes.isSubset(of: Set(SlackManifest.userScopes)))
        XCTAssertEqual(SlackManifest.contentScopes, ["files:read", "channels:history", "groups:history", "im:history", "mpim:history",
                                                     "stars:read", "stars:write"])
        XCTAssertEqual(SlackManifest.userScopes.count, Set(SlackManifest.userScopes).count, "no permission twice")
        let manifest = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(SlackManifest.json.utf8)) as? [String: Any])
        let scopes = try XCTUnwrap((manifest["oauth_config"] as? [String: Any])?["scopes"] as? [String: Any])
        let user = Set(scopes["user"] as? [String] ?? [])
        XCTAssertTrue(user.isSuperset(of: SlackManifest.contentScopes))
        XCTAssertTrue(user.isSuperset(of: ["stars:read", "stars:write"]), "saving for later")
        XCTAssertNil(scopes["bot"], "user scopes only")
        XCTAssertLessThanOrEqual(SlackManifest.description.count, 140, "Slack's limit")
    }
}

// MARK: - The whole thread

/// A thread in #leadership at fixed times. Maya has Priya's question to her (`open`) in Docket's inbox.
private enum WholeThread {
    static let channel = "C0LEAD"
    static let parent = "1791200000.000100"
    static let open = "1791200500.000600"

    /// The parent and its replies, files and all, with what a thread never shows (a join, a deleted
    /// message, an empty one, an unreadable one) and a reply that came late in the list.
    static let replies = #"""
    {"ok":true,"messages":[
      {"type":"message","ts":"1791200000.000100","user":"U0PRIYA","text":"Can everyone send their *Q4 numbers* by Friday?","thread_ts":"1791200000.000100","reply_count":8,
       "files":[{"id":"F0CHART","name":"q3-chart.png","mimetype":"image/png","size":48213,"mode":"hosted",
                 "url_private_download":"https://files.slack.com/files-pri/T0ACME-F0CHART/download/q3-chart.png",
                 "thumb_480":"https://files.slack.com/files-tmb/T0ACME-F0CHART-1a2b/q3-chart_480.png"}]},
      {"type":"message","ts":"1791200100.000200","user":"U0SAM","text":"Mine are in the <https://docs.example.com/q4|sheet> :+1:","thread_ts":"1791200000.000100",
       "user_profile":{"real_name":"Sam Lee","display_name":"sam"},
       "files":[{"id":"F0BUDGET","name":"budget.pdf","title":"Q4 budget","mimetype":"application/pdf","size":52000,"mode":"hosted",
                 "url_private_download":"https://files.slack.com/files-pri/T0ACME-F0BUDGET/download/budget.pdf"},
                {"id":"F0GONE","mode":"tombstone"}]},
      {"type":"message","subtype":"channel_join","ts":"1791200150.000000","user":"U0NEW","text":"<@U0NEW> has joined the channel"},
      {"type":"message","ts":"1791200200.000300","user":"U0MAYA","text":"Sending mine tonight, <@U0DANA> too","thread_ts":"1791200000.000100"},
      {"type":"message","subtype":"tombstone","ts":"1791200250.000000","text":"This message was deleted.","hidden":true,"thread_ts":"1791200000.000100"},
      {"type":"message","subtype":"bot_message","ts":"1791200300.000400","bot_id":"B0CAL","username":"reminders","bot_profile":{"name":"Calendar"},
       "text":"Numbers are due Friday","thread_ts":"1791200000.000100"},
      {"type":"message","ts":"1791200450.000550","user":"U0SAM","text":"","thread_ts":"1791200000.000100"},
      {"type":"message","ts":"1791200460.000560","user":"U0PRIYA","text":"","thread_ts":"1791200000.000100",
       "files":[{"id":"F0DECK","name":"deck.key","title":"Offsite deck","mimetype":"application/x-iwork-keynote-sffkey","size":1048576,
                 "url_private_download":"https://files.slack.com/files-pri/T0ACME-F0DECK/download/deck.key"}]},
      {"type":"message","ts":"1791200500.000600","user":"U0PRIYA","text":"<@U0MAYA> can you check Sam's numbers in <#C0FIN>?","thread_ts":"1791200000.000100"},
      {"type":"message","ts":"1791200600.000700","user":"U0SAM","text":"Checked them, all good <@U0DANA|dana>","thread_ts":"1791200000.000100",
       "user_profile":{"real_name":"Sam Lee"}},
      {"type":"message","ts":"1791200050.000150","user":"U0SAM","text":"Will do","thread_ts":"1791200000.000100"},
      {"bogus":1}
    ],"has_more":false,"response_metadata":{"next_cursor":""}}
    """#

    /// Message `n` of a long thread (0 is the parent), ten seconds apart.
    static func ts(_ n: Int) -> String { "\(1_791_200_000 + n * 10).000100" }

    /// A page of numbered messages. After the first, a page starts with the parent again, as Slack's do.
    static func page(_ numbers: Range<Int>, next: String?) -> String {
        let messages = (numbers.lowerBound > 0 ? [0] : []) + Array(numbers)
        let body = messages.map { SlackFixture.reply(ts($0), "Priya", "Message \($0)") }.joined(separator: ",")
        return #"{"ok":true,"messages":[\#(body)],"has_more":\#(next != nil),"response_metadata":{"next_cursor":"\#(next ?? "")"}}"#
    }
}

final class SlackWholeThreadTests: XCTestCase {
    private typealias T = WholeThread

    private func slack(_ server: FakeIntegrationServer) -> SlackClient {
        SlackClient(token: SlackFixture.token, transport: server.transport)
    }

    func testTheWholeThreadIsEveryMessageOldestFirstByNameWithItsFiles() async throws {
        let server = FakeIntegrationServer()
        server.slack("conversations.replies", T.replies)
        server.slack("users.info", where: ("user", "U0PRIYA"), SlackFixture.user("U0PRIYA", "Priya Shah"))
        server.slack("users.info", where: ("user", "U0MAYA"), SlackFixture.user("U0MAYA", "Maya Chen"))
        server.slack("users.info", where: ("user", "U0DANA"), SlackFixture.user("U0DANA", "Dana Whitfield"))
        let thread = try await slack(server).fullThread(channel: T.channel, threadTS: T.parent, myUserID: SlackFixture.me)

        // The parent and every reply, oldest first; no joins, deleted, empty or unreadable messages.
        XCTAssertEqual(thread.map(\.id), ["1791200000.000100", "1791200050.000150", "1791200100.000200", "1791200200.000300",
                                          "1791200300.000400", "1791200460.000560", "1791200500.000600", "1791200600.000700"])
        XCTAssertEqual(thread.map(\.from), ["Priya Shah", "Sam Lee", "Sam Lee", "Maya Chen", "Calendar", "Priya Shah", "Priya Shah", "Sam Lee"])
        XCTAssertEqual(thread.map(\.userID), ["U0PRIYA", "U0SAM", "U0SAM", "U0MAYA", nil, "U0PRIYA", "U0PRIYA", "U0SAM"])
        XCTAssertEqual(thread.map(\.isMine), [false, false, false, true, false, false, false, false])
        XCTAssertEqual(thread[0].date.timeIntervalSince1970, 1_791_200_000.0001, accuracy: 0.000_01)
        XCTAssertEqual(thread[7].date.timeIntervalSince1970, 1_791_200_600.0007, accuracy: 0.000_01)
        XCTAssertEqual(thread.map(\.text), [
            "Can everyone send their Q4 numbers by Friday?", "Will do", "Mine are in the sheet 👍",
            "Sending mine tonight, @Dana Whitfield too", "Numbers are due Friday", "Shared a file: Offsite deck",
            "@Maya Chen can you check Sam's numbers in #channel?", "Checked them, all good @Dana Whitfield",
        ])
        // The markup as sent, its people by name; formatting, links and unknown channels as they were.
        XCTAssertEqual(thread[0].markup, "Can everyone send their *Q4 numbers* by Friday?")
        XCTAssertEqual(thread[2].markup, "Mine are in the <https://docs.example.com/q4|sheet> :+1:")
        XCTAssertEqual(thread[6].markup, "<@U0MAYA|Maya Chen> can you check Sam's numbers in <#C0FIN>?")
        XCTAssertEqual(thread[7].markup, "Checked them, all good <@U0DANA|Dana Whitfield>")
        XCTAssertEqual(String(SlackText.attributed(thread[6].markup, names: [:]).characters), thread[6].text,
                       "reads right without the names at hand")

        // Each message with its own files (a deleted one left out).
        XCTAssertEqual(thread.map { $0.files.map(\.id) }, [["F0CHART"], [], ["F0BUDGET"], [], [], ["F0DECK"], [], []])
        XCTAssertEqual(thread[0].files.first, MessageAttachment(
            id: "F0CHART", name: "q3-chart.png", mimeType: "image/png", size: 48_213,
            remote: .slack(url: SlackFixture.file("F0CHART", "download/q3-chart.png"),
                           thumbnail: URL(string: "https://files.slack.com/files-tmb/T0ACME-F0CHART-1a2b/q3-chart_480.png"))))
        XCTAssertEqual(thread[5].files.first?.name, "deck.key")

        let pages = server.calls("conversations.replies")
        XCTAssertEqual(pages.count, 1)
        let request = try XCTUnwrap(pages.first)
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer \(SlackFixture.token)")
        XCTAssertEqual(FakeIntegrationServer.form(request), ["channel": "C0LEAD", "ts": T.parent, "limit": "200"])
        // Sam came with his name; the other writers and the people mentioned were looked up once each.
        XCTAssertEqual(server.calls("users.info").map { FakeIntegrationServer.form($0)["user"] ?? "" }.sorted(), ["U0DANA", "U0MAYA", "U0PRIYA"])

        // Names already known aren't looked up again, and a channel without a name gains one.
        let lookups = server.calls("users.info").count
        let named = try await slack(server).fullThread(channel: T.channel, threadTS: T.parent, myUserID: SlackFixture.me,
                                                       names: ["U0PRIYA": "Priya Shah", "U0MAYA": "Maya Chen", "U0DANA": "Dana Whitfield",
                                                               "C0FIN": "finance"], around: T.open)
        XCTAssertEqual(server.calls("users.info").count, lookups)
        XCTAssertEqual(named.map(\.id), thread.map(\.id))
        XCTAssertEqual(named[6].markup, "<@U0MAYA|Maya Chen> can you check Sam's numbers in <#C0FIN|finance>?")
        XCTAssertEqual(named[6].text, "@Maya Chen can you check Sam's numbers in #finance?")
        XCTAssertEqual(SlackClient.index(of: T.open, in: named), 6, "the inbox message, to highlight")
    }

    func testTheInboxMessageIsKeptEvenWhenThereIsNothingToShowOfIt() async throws {
        let server = FakeIntegrationServer()
        server.slack("conversations.replies", T.replies)
        let empty = "1791200450.000550"
        let thread = try await slack(server).fullThread(channel: T.channel, threadTS: T.parent, myUserID: SlackFixture.me,
                                                        names: ["U0PRIYA": "Priya Shah", "U0MAYA": "Maya Chen", "U0SAM": "Sam Lee",
                                                                "U0DANA": "Dana Whitfield"], around: empty)
        XCTAssertEqual(thread.count, 9)
        let i = try XCTUnwrap(SlackClient.index(of: empty, in: thread))
        XCTAssertEqual(thread[i].from, "Sam Lee")
        XCTAssertEqual(thread[i].text, "")
        XCTAssertEqual(thread.map(\.id), thread.map(\.id).sorted { SlackClient.compare($0, $1) < 0 })
        XCTAssertTrue(server.calls("users.info").isEmpty)
    }

    func testReplyingToAnyMessageOfTheThreadStaysInTheThread() async throws {
        let server = FakeIntegrationServer()
        server.slack("conversations.replies", T.replies)
        server.slack("chat.postMessage", #"{"ok":true,"channel":"C0LEAD","ts":"1791200700.000800"}"#)
        let client = slack(server)
        let names = ["U0PRIYA": "Priya Shah", "U0MAYA": "Maya Chen", "U0SAM": "Sam Lee", "U0DANA": "Dana Whitfield"]
        let thread = try await client.fullThread(channel: T.channel, threadTS: T.parent, myUserID: SlackFixture.me, names: names, around: T.open)
        // Answering Sam's reply (not the parent): the reply goes under the thread's parent, never under a reply.
        let sams = try XCTUnwrap(thread.first { $0.id == "1791200600.000700" })
        XCTAssertEqual(sams.from, "Sam Lee")
        try await client.reply(channel: T.channel, threadTS: try XCTUnwrap(thread.first?.id), text: "Thanks, Sam")
        let form = FakeIntegrationServer.form(try XCTUnwrap(server.calls("chat.postMessage").first))
        XCTAssertEqual(form["thread_ts"], T.parent)
        XCTAssertEqual(form["channel"], T.channel)
        XCTAssertEqual(form["text"], "Thanks, Sam")
    }

    func testTheParentLeadsItsThreadEvenDeletedOrEmpty() async throws {
        let server = FakeIntegrationServer()
        server.slack("conversations.replies", #"""
        {"ok":true,"messages":[
          {"type":"message","subtype":"tombstone","ts":"1791200000.000100","user":"USLACKBOT","text":"This message was deleted.","hidden":true,
           "thread_ts":"1791200000.000100","reply_count":2},
          {"type":"message","ts":"1791200100.000200","user":"U0SAM","text":"Thursday works","thread_ts":"1791200000.000100","user_profile":{"real_name":"Sam Lee"}},
          {"type":"message","ts":"1791200200.000300","user":"U0PRIYA","text":"","thread_ts":"1791200000.000100","user_profile":{"real_name":"Priya Shah"}}
        ],"has_more":false}
        """#, #"""
        {"ok":true,"messages":[
          {"type":"message","subtype":"huddle_thread","ts":"1791200000.000100","user":"U0PRIYA","text":"","thread_ts":"1791200000.000100",
           "user_profile":{"real_name":"Priya Shah"}},
          {"type":"message","ts":"1791200100.000200","user":"U0SAM","text":"Notes from the call are in the doc","thread_ts":"1791200000.000100",
           "user_profile":{"real_name":"Sam Lee"}}
        ],"has_more":false}
        """#)
        server.slack("users.info", where: ("user", "USLACKBOT"), SlackFixture.user("USLACKBOT", "Slackbot"))
        let deleted = try await slack(server).fullThread(channel: T.channel, threadTS: T.parent, myUserID: SlackFixture.me)
        XCTAssertEqual(deleted.map(\.id), [T.parent, "1791200100.000200"], "the parent first, as in Slack; an empty reply left out")
        XCTAssertEqual(deleted.map(\.text), ["This message was deleted.", "Thursday works"])
        XCTAssertEqual(deleted.first?.from, "Slackbot")

        let empty = try await slack(server).fullThread(channel: T.channel, threadTS: T.parent, myUserID: SlackFixture.me)
        XCTAssertEqual(empty.map(\.id), [T.parent, "1791200100.000200"])
        XCTAssertEqual(empty.map(\.text), ["", "Notes from the call are in the doc"])
        XCTAssertEqual(empty.first?.from, "Priya Shah")
    }

    func testAskedForAReplyItReadsTheParentsThread() async throws {
        let server = FakeIntegrationServer()
        // Asked with a reply's ts, Slack sends just that reply.
        server.slack("conversations.replies", where: ("ts", T.open), #"""
        {"ok":true,"messages":[{"type":"message","ts":"1791200500.000600","user":"U0PRIYA","text":"<@U0MAYA> can you check Sam's numbers?","thread_ts":"1791200000.000100"}],
         "has_more":false}
        """#)
        server.slack("conversations.replies", where: ("ts", T.parent), T.replies)
        let names = ["U0PRIYA": "Priya Shah", "U0MAYA": "Maya Chen", "U0SAM": "Sam Lee", "U0DANA": "Dana Whitfield"]
        let thread = try await slack(server).fullThread(channel: T.channel, threadTS: T.open, myUserID: SlackFixture.me, names: names, around: nil)
        XCTAssertEqual(thread.count, 8)
        XCTAssertEqual(thread.first?.id, T.parent)
        XCTAssertEqual(SlackClient.index(of: T.open, in: thread), 6)
        XCTAssertEqual(server.calls("conversations.replies").map { FakeIntegrationServer.form($0)["ts"] }, [T.open, T.parent])

        // The parent, or a message that's alone, is read once.
        _ = try await slack(server).fullThread(channel: T.channel, threadTS: T.parent, myUserID: SlackFixture.me, names: names, around: T.open)
        XCTAssertEqual(server.calls("conversations.replies").count, 3)
        let alone = FakeIntegrationServer()
        alone.slack("conversations.replies", #"{"ok":true,"messages":[{"ts":"1791200500.000600","user":"U0PRIYA","text":"Lunch?"}],"has_more":false}"#)
        let one = try await slack(alone).fullThread(channel: "D0PRIYA", threadTS: T.open, myUserID: SlackFixture.me, names: names, around: T.open)
        XCTAssertEqual(one.map(\.text), ["Lunch?"])
        XCTAssertEqual(alone.calls("conversations.replies").count, 1)
    }

    func testAReplyAskedForStaysInTheWholeThreadSlackSends() async throws {
        // Asked with a reply's ts, Slack may send the whole thread at once. The reply is the one being looked
        // at: it stays in with nothing to show of it, as the message to keep when there's no `around`.
        let server = FakeIntegrationServer()
        server.slack("conversations.replies", T.replies)
        let empty = "1791200450.000550"
        let names = ["U0PRIYA": "Priya Shah", "U0MAYA": "Maya Chen", "U0SAM": "Sam Lee", "U0DANA": "Dana Whitfield"]
        let thread = try await slack(server).fullThread(channel: T.channel, threadTS: empty, myUserID: SlackFixture.me, names: names, around: nil)
        XCTAssertEqual(thread.count, 9)
        XCTAssertEqual(thread.first?.id, T.parent)
        let i = try XCTUnwrap(SlackClient.index(of: empty, in: thread))
        XCTAssertEqual(thread[i].from, "Sam Lee")
        XCTAssertEqual(server.calls("conversations.replies").count, 1, "the whole thread came at once")

        // A very long one is shown around that reply, not just its newest messages.
        let long = FakeIntegrationServer()
        long.slack("conversations.replies", T.page(0..<200, next: "p2"), T.page(200..<400, next: "p3"), T.page(400..<600, next: "p4"),
                   T.page(600..<700, next: nil))
        let around = try await slack(long).fullThread(channel: T.channel, threadTS: T.ts(300), myUserID: SlackFixture.me)
        XCTAssertEqual(around.map(\.id), [T.ts(0)] + (51...549).map(T.ts))
        XCTAssertEqual(SlackClient.index(of: T.ts(300), in: around), 250)
    }

    func testTheWholeThreadIsReadPageByPageEachMessageOnce() async throws {
        let server = FakeIntegrationServer()
        server.slack("conversations.replies", T.page(0..<3, next: "page2"), T.page(3..<5, next: "page3"), T.page(5..<6, next: nil))
        let thread = try await slack(server).fullThread(channel: T.channel, threadTS: T.ts(0), myUserID: SlackFixture.me)
        XCTAssertEqual(thread.map(\.id), (0..<6).map(T.ts), "the parent once, though every page starts with it")
        XCTAssertEqual(thread.map(\.text), (0..<6).map { "Message \($0)" })

        let pages = server.calls("conversations.replies")
        XCTAssertEqual(pages.map { FakeIntegrationServer.form($0)["cursor"] }, [nil, "page2", "page3"])
        XCTAssertTrue(pages.allSatisfy { FakeIntegrationServer.form($0)["ts"] == T.ts(0) && FakeIntegrationServer.form($0)["limit"] == "200" })
        XCTAssertTrue(server.calls("users.info").isEmpty, "names came with the messages")
    }

    func testAThreadIsReadFivePagesAtMostAndAStuckCursorEndsIt() async throws {
        let endless = FakeIntegrationServer()
        endless.slack("conversations.replies", replies: (0..<8).map { k in T.page(k * 3 ..< k * 3 + 3, next: "page\(k + 2)") })
        let long = try await slack(endless).fullThread(channel: T.channel, threadTS: T.ts(0), myUserID: SlackFixture.me)
        XCTAssertEqual(endless.calls("conversations.replies").count, SlackClient.fullThreadPages)
        XCTAssertEqual(long.map(\.id), (0..<15).map(T.ts))

        let stuck = FakeIntegrationServer()
        stuck.slack("conversations.replies", T.page(0..<2, next: "again"))
        let short = try await slack(stuck).fullThread(channel: T.channel, threadTS: T.ts(0), myUserID: SlackFixture.me)
        XCTAssertEqual(stuck.calls("conversations.replies").count, 2, "the same cursor again: the thread doesn't move on")
        XCTAssertEqual(short.map(\.id), [T.ts(0), T.ts(1)])
    }

    func testAVeryLongThreadShowsFiveHundredAroundTheMessage() async throws {
        func server() -> FakeIntegrationServer {
            let s = FakeIntegrationServer()
            s.slack("conversations.replies", T.page(0..<200, next: "p2"), T.page(200..<400, next: "p3"), T.page(400..<600, next: "p4"),
                    T.page(600..<700, next: nil))
            return s
        }
        let around = try await slack(server()).fullThread(channel: T.channel, threadTS: T.ts(0), myUserID: SlackFixture.me,
                                                          names: [:], around: T.ts(300))
        XCTAssertEqual(around.count, SlackClient.fullThreadLimit)
        XCTAssertEqual(around.map(\.id), [T.ts(0)] + (51...549).map(T.ts), "its start, the message and the 498 closest to it")
        XCTAssertEqual(SlackClient.index(of: T.ts(300), in: around), 250)

        let newest = try await slack(server()).fullThread(channel: T.channel, threadTS: T.ts(0), myUserID: SlackFixture.me)
        XCTAssertEqual(newest.map(\.id), [T.ts(0)] + (201..<700).map(T.ts), "no message to keep: its start and the newest")
    }

    func testWhichMessagesALongThreadShows() {
        let all = (1...10).map { "17912000\(String(format: "%02d", $0)).000100" }
        func pick(_ around: Int?, limit: Int) -> [Int] {
            SlackClient.fullThreadWindow(all.shuffled(), around: around.map { "17912000\(String(format: "%02d", $0)).000100" }, limit: limit)
                .map { Int($0.dropFirst(8).prefix(2))! }
        }
        XCTAssertEqual(pick(7, limit: 20), Array(1...10), "short enough: all of it, oldest first")
        XCTAssertEqual(pick(nil, limit: 10), Array(1...10))
        XCTAssertEqual(pick(7, limit: 4), [1, 6, 7, 8], "its start, the message, and the closest to it, earlier first")
        XCTAssertEqual(pick(nil, limit: 4), [1, 8, 9, 10], "no message: its start and the newest")
        XCTAssertEqual(pick(1, limit: 3), [1, 2, 3], "the parent: its first replies")
        XCTAssertEqual(pick(10, limit: 3), [1, 9, 10], "the newest: what led up to it")
        XCTAssertEqual(pick(42, limit: 3), [1, 9, 10], "a message that isn't there: the newest")
        XCTAssertEqual(pick(7, limit: 1), [7])
        XCTAssertEqual(pick(nil, limit: 1), [1])
        XCTAssertEqual(pick(7, limit: 0), [])
        XCTAssertEqual(SlackClient.fullThreadWindow(["2.000000", "1.500000", "1.500000"], around: nil, limit: 5), ["1.500000", "2.000000"],
                       "each once")
    }

    func testAMessageOutsideAThreadIsAConversationOfOne() async throws {
        let server = FakeIntegrationServer()
        server.slack("conversations.replies", #"""
        {"ok":true,"messages":[{"type":"message","ts":"1791200500.000600","user":"U0PRIYA","text":"Lunch at noon?","user_profile":{"real_name":"Priya Shah"}}],"has_more":false}
        """#)
        let thread = try await slack(server).fullThread(channel: "D0PRIYA", threadTS: T.open, myUserID: SlackFixture.me)
        XCTAssertEqual(thread.map(\.text), ["Lunch at noon?"])
        XCTAssertEqual(thread.map(\.from), ["Priya Shah"])
        XCTAssertEqual(server.calls("conversations.replies").count, 1)
        XCTAssertEqual(SlackClient.index(of: T.open, in: thread), 0)
        XCTAssertEqual(SlackClient.index(of: "1791200500.0006", in: thread), 0, "by time, not as text")
        XCTAssertNil(SlackClient.index(of: T.parent, in: thread))
        XCTAssertNil(SlackClient.index(of: "p1791200500000600", in: thread))
    }

    func testTheWholeThreadNeedsTheHistoryPermissionAndAGoneOneSaysSo() async throws {
        let server = FakeIntegrationServer()
        server.slack("conversations.replies", replies: [
            #"{"ok":false,"error":"missing_scope","needed":"groups:history","provided":"reactions:read,search:read,users:read"}"#,
            #"{"ok":false,"error":"thread_not_found"}"#,
            #"{"ok":false,"error":"invalid_auth"}"#,
            #"{"ok":false,"error":"channel_not_found"}"#,
        ])
        let client = slack(server)
        let expected: [IntegrationError] = [.missingPermission(.slack, "groups:history"), SlackClient.messageGone, .signedOut(.slack),
                                            .api(.slack, "That channel isn't available any more.")]
        for want in expected {
            do {
                _ = try await client.fullThread(channel: "G0PRIVATE", threadTS: T.parent, myUserID: SlackFixture.me)
                XCTFail("expected \(want)")
            } catch {
                XCTAssertEqual(error as? IntegrationError, want)
            }
        }
        XCTAssertEqual(SlackClient.messageGone.errorDescription, "That message isn't in Slack any more.")

        // Nothing to ask for: no call at all.
        let calls = server.requests.count
        for (channel, ts) in [("", T.parent), ("C0LEAD", "p1791200000000100"), ("C0LEAD", "")] {
            do {
                _ = try await client.fullThread(channel: channel, threadTS: ts, myUserID: SlackFixture.me)
                XCTFail("no thread to read")
            } catch {
                XCTAssertNotNil(error as? IntegrationError)
            }
        }
        XCTAssertEqual(server.requests.count, calls)
    }

    func testMentionsCarryTheirNamesInTheMarkup() {
        let names = ["U0SAM": "Sam Lee", "U0ODD": "Ana <QA> & Ops", "U0LINES": "Two\nLines", "C0LEAD": "leadership", "C0FIN": "finance"]
        XCTAssertEqual(SlackText.naming("<@U0SAM> and <@U0SAM|sam> in <#C0LEAD> and <#C0FIN|fin-team>, not <@U0NOBODY>, <!here> or <https://x.example|x>",
                                        names: names),
                       "<@U0SAM|Sam Lee> and <@U0SAM|Sam Lee> in <#C0LEAD|leadership> and <#C0FIN|fin-team>, not <@U0NOBODY>, <!here> or <https://x.example|x>",
                       "people by their name now; a channel keeps the name it was written with")
        XCTAssertEqual(SlackText.naming("<@U0ODD> <@U0LINES>", names: names), "<@U0ODD|Ana &lt;QA&gt; &amp; Ops> <@U0LINES|Two Lines>")
        XCTAssertEqual(SlackText.readable(SlackText.naming("<@U0ODD>", names: names)), "@Ana <QA> & Ops")
        XCTAssertEqual(SlackText.naming("no mentions &amp; no names", names: names), "no mentions &amp; no names")
        // It reads the same with the names at hand or without them.
        for markup in ["<@U0SAM> see <#C0LEAD> and <#C0FIN|fin-team>", "*<@U0SAM>* in `<@U0SAM>`", "<@U0NOBODY|someone-else> &gt; quote"] {
            let named = SlackText.naming(markup, names: names)
            XCTAssertEqual(SlackText.readable(named), SlackText.readable(markup, names: names), markup)
            XCTAssertEqual(SlackText.naming(named, names: names), named, "naming twice changes nothing")
        }
    }
}

// MARK: - Saving for later (stars)

final class SlackStarTests: XCTestCase {
    private func slack(_ server: FakeIntegrationServer) -> SlackClient {
        SlackClient(token: SlackFixture.token, transport: server.transport)
    }

    func testStarringSavesTheMessageForLaterInSlack() async throws {
        let server = FakeIntegrationServer()
        server.slack("stars.add", #"{"ok":true}"#)
        server.slack("stars.remove", #"{"ok":true}"#)
        let client = slack(server)
        try await client.setStarred(true, channel: "C0LEAD", ts: WholeThread.open)
        try await client.setStarred(false, channel: "D0PRIYA", ts: WholeThread.parent)

        let add = try XCTUnwrap(server.calls("stars.add").first)
        XCTAssertEqual(add.url?.absoluteString, "https://slack.com/api/stars.add")
        XCTAssertEqual(add.httpMethod, "POST")
        XCTAssertEqual(add.value(forHTTPHeaderField: "Authorization"), "Bearer \(SlackFixture.token)")
        XCTAssertEqual(FakeIntegrationServer.form(add), ["channel": "C0LEAD", "timestamp": WholeThread.open], "the message by channel and ts")
        let remove = try XCTUnwrap(server.calls("stars.remove").first)
        XCTAssertEqual(FakeIntegrationServer.form(remove), ["channel": "D0PRIYA", "timestamp": WholeThread.parent])
        XCTAssertEqual(server.requests.count, 2)
    }

    func testAlreadyTheWayItShouldBeIsDone() async throws {
        let server = FakeIntegrationServer()
        server.slack("stars.add", #"{"ok":false,"error":"already_starred"}"#)
        server.slack("stars.remove", replies: [#"{"ok":false,"error":"not_starred"}"#, #"{"ok":false,"error":"message_not_found"}"#,
                                              #"{"ok":false,"error":"channel_not_found"}"#])
        let client = slack(server)
        try await client.setStarred(true, channel: "C0LEAD", ts: WholeThread.open)
        for _ in 0..<3 {
            try await client.setStarred(false, channel: "C0LEAD", ts: WholeThread.open)
        }
        XCTAssertEqual(server.requests.count, 4)
    }

    func testWhenSlackWontSaveForLaterTheStarStaysInDocketOnly() async throws {
        let server = FakeIntegrationServer()
        server.slack("stars.add", replies: [
            #"{"ok":false,"error":"method_deprecated"}"#,
            #"{"ok":false,"error":"not_allowed"}"#,
            #"{"ok":false,"error":"missing_scope","needed":"stars:write","provided":"reactions:read,search:read,users:read"}"#,
            #"{"ok":false,"error":"not_allowed_token_type"}"#,
            #"{"ok":false,"error":"missing_scope"}"#,
            #"{"ok":false,"error":"missing_scope","needed":"stars:read, stars:write"}"#,
            #"{"ok":false,"error":"missing_scope","needed":"chat:write"}"#,
        ])
        server.slack("stars.remove", replies: [#"{"ok":false,"error":"method_deprecated"}"#, #"{"ok":false,"error":"missing_scope","needed":"stars:write"}"#])
        let client = slack(server)
        // The methods retired or not allowed: nothing to do about it. An app made without stars:write: update it.
        let starring: [IntegrationError] = [
            SlackClient.starsRefused(starring: true), SlackClient.starsRefused(starring: true), .missingPermission(.slack, "stars:write"),
            SlackClient.starsRefused(starring: true), .missingPermission(.slack, "stars:write"), .missingPermission(.slack, "stars:read, stars:write"),
            .missingPermission(.slack, "stars:write"),
        ]
        for want in starring {
            do {
                try await client.setStarred(true, channel: "C0LEAD", ts: WholeThread.open)
                XCTFail("Slack didn't save it")
            } catch {
                XCTAssertEqual(error as? IntegrationError, want)
                XCTAssertTrue(SlackClient.isStarRefusal(error), "\(want): the star stays in Docket")
            }
        }
        for want in [SlackClient.starsRefused(starring: false), .missingPermission(.slack, "stars:write")] {
            do {
                try await client.setStarred(false, channel: "C0LEAD", ts: WholeThread.open)
                XCTFail("Slack didn't change it")
            } catch {
                XCTAssertEqual(error as? IntegrationError, want)
                XCTAssertTrue(SlackClient.isStarRefusal(error))
            }
        }
        XCTAssertEqual(SlackClient.starsRefused(starring: true).errorDescription, "Saved in Docket only (Slack didn't allow saving it there)")
        XCTAssertEqual(SlackClient.starsRefused(starring: false).errorDescription, "Unstarred in Docket only (Slack didn't allow changing it there)")
        // Other permissions, or Gmail's, aren't about saving for later.
        XCTAssertFalse(SlackClient.isStarRefusal(IntegrationError.missingPermission(.slack, "channels:history")))
        XCTAssertFalse(SlackClient.isStarRefusal(IntegrationError.missingPermission(.slack, "stars:write,chat:write")))
        XCTAssertFalse(SlackClient.isStarRefusal(IntegrationError.missingPermission(.slack, "")))
        XCTAssertFalse(SlackClient.isStarRefusal(IntegrationError.missingPermission(.gmail, "stars:write")))
    }

    func testOtherStarFailuresAreNotRefusals() async throws {
        let server = FakeIntegrationServer()
        server.slack("stars.add", replies: [
            #"{"ok":false,"error":"invalid_auth"}"#,
            #"{"ok":false,"error":"message_not_found"}"#,
            #"{"ok":false,"error":"channel_not_found"}"#,
            #"{"ok":false,"error":"ratelimited"}"#,
            #"{"ok":false,"error":"internal_error"}"#,
        ])
        let client = slack(server)
        let expected: [IntegrationError] = [
            .signedOut(.slack), SlackClient.messageGone, .api(.slack, "That channel isn't available any more."),
            .rateLimited(.slack, retryAfter: 60), .api(.slack, "Slack said “internal_error”."),
        ]
        for want in expected {
            do {
                try await client.setStarred(true, channel: "C0LEAD", ts: WholeThread.open)
                XCTFail("expected \(want)")
            } catch {
                XCTAssertEqual(error as? IntegrationError, want)
                XCTAssertFalse(SlackClient.isStarRefusal(error), "\(want) is put back")
            }
        }

        let offline = SlackClient(token: SlackFixture.token, transport: { _ in throw URLError(.notConnectedToInternet) })
        do {
            try await offline.setStarred(true, channel: "C0LEAD", ts: WholeThread.open)
            XCTFail("offline")
        } catch {
            XCTAssertEqual(error as? IntegrationError, .offline(.slack, "You seem to be offline."))
            XCTAssertFalse(SlackClient.isStarRefusal(error))
        }
        XCTAssertFalse(SlackClient.isStarRefusal(URLError(.timedOut)))
        XCTAssertFalse(SlackClient.isStarRefusal(IntegrationError.api(.gmail, "Saved in Docket only (Slack didn't allow saving it there)")))

        // Nothing to star: no request.
        let calls = server.requests.count
        for (channel, ts) in [("", WholeThread.open), ("C0LEAD", "p1791200500000600")] {
            do {
                try await client.setStarred(true, channel: channel, ts: ts)
                XCTFail("nothing to star")
            } catch {
                XCTAssertNotNil(error as? IntegrationError)
                XCTAssertFalse(SlackClient.isStarRefusal(error))
            }
        }
        XCTAssertEqual(server.requests.count, calls)
    }
}

// MARK: - mrkdwn

final class SlackMarkupTests: XCTestCase {
    private func range(_ text: String, in s: AttributedString, file: StaticString = #filePath, line: UInt = #line) throws -> Range<AttributedString.Index> {
        try XCTUnwrap(s.range(of: text), "“\(text)” isn't in “\(String(s.characters))”", file: file, line: line)
    }

    func testEmphasisAndCode() throws {
        let s = SlackText.attributed("*Q4 budget* is _due_ ~Thursday~ `Friday`", names: [:])
        XCTAssertEqual(String(s.characters), "Q4 budget is due Thursday Friday")
        XCTAssertEqual(s[try range("Q4 budget", in: s)].inlinePresentationIntent, .stronglyEmphasized)
        XCTAssertEqual(s[try range("due", in: s)].inlinePresentationIntent, .emphasized)
        XCTAssertEqual(s[try range("Thursday", in: s)].inlinePresentationIntent, .strikethrough)
        XCTAssertEqual(s[try range("Thursday", in: s)].swiftUI.foregroundColor, Color.ink3)
        XCTAssertEqual(s[try range("Friday", in: s)].inlinePresentationIntent, .code)
        XCTAssertEqual(s[try range("Friday", in: s)].swiftUI.backgroundColor, Color.fill)
        XCTAssertNil(s[try range(" is ", in: s)].inlinePresentationIntent)

        let nested = SlackMarkup.runs("*bold _and italic_* plain", names: [:])
        XCTAssertEqual(nested.map(\.text), ["bold ", "and italic", " plain"])
        XCTAssertEqual(nested.map(\.style), [.bold, [.bold, .italic], []])
    }

    func testMarksFollowSlacksWordRules() {
        for literal in ["snake_case_name", "2*3*4 = 24", "a * b * c", "file_v2_final.pdf", "~5 to ~10 minutes", "*not closed",
                        "**double**", "`unclosed code", "Use ``` for code", "a``b", "x * y*z"] {
            XCTAssertEqual(SlackText.readable(literal), literal)
            XCTAssertTrue(SlackMarkup.runs(literal, names: [:]).allSatisfy { $0.style.isEmpty }, literal)
        }
        // Next to punctuation is fine; across lines is not.
        XCTAssertEqual(SlackMarkup.runs("(*really*), _now_!", names: [:]).filter { !$0.style.isEmpty }.map(\.text), ["really", "now"])
        XCTAssertEqual(SlackText.readable("*half\nway*"), "*half\nway*")
        // Marks inside code and links are text.
        let runs = SlackMarkup.runs("`*not bold*` <https://x.example/a_b_c|a_b_c> *<@U0SAM>*", names: ["U0SAM": "Sam Lee"])
        XCTAssertEqual(runs.map(\.text), ["*not bold*", " ", "a_b_c", " ", "@Sam Lee"])
        XCTAssertEqual(runs.map(\.style), [.code, [], [], [], [.bold, .mention]])
    }

    func testLinksAreSafeAndKeepTheirLabels() throws {
        let s = SlackText.attributed("Read <https://docs.example.com/q3?a=1&amp;b=2|the Q3 deck>, <https://acme.example> or mail <mailto:sam@northwind.example|Sam> <mailto:priya@contoso.example>",
                                     names: [:])
        XCTAssertEqual(String(s.characters), "Read the Q3 deck, https://acme.example or mail Sam priya@contoso.example")
        XCTAssertEqual(s[try range("the Q3 deck", in: s)].link, URL(string: "https://docs.example.com/q3?a=1&b=2"))
        XCTAssertEqual(s[try range("https://acme.example", in: s)].link, URL(string: "https://acme.example"))
        XCTAssertEqual(s[try range("Sam", in: s)].link, URL(string: "mailto:sam@northwind.example"))
        XCTAssertEqual(s[try range("priya@contoso.example", in: s)].link, URL(string: "mailto:priya@contoso.example"))
        XCTAssertNil(s[try range("Read ", in: s)].link)

        // Only web and mail links: a message can't make Docket open anything else.
        let unsafe = SlackText.attributed("<javascript:alert(1)|Click> <file:///etc/hosts|hosts> <slack://open|app> <tel:5550100>", names: [:])
        XCTAssertEqual(String(unsafe.characters), "Click hosts app tel:5550100")
        XCTAssertTrue(unsafe.runs.allSatisfy { $0.link == nil })
    }

    func testPeopleChannelsAndSpecialMentionsByName() throws {
        let names = ["U0SAM": "Sam Lee", "C0LEAD": "leadership"]
        let s = SlackText.attributed("<@U0SAM> <@U0PRIYA|priya> <@U0NOBODY> <#C0LEAD> <#C0GEN|general> <!here> <!channel> <!subteam^S0DES|@design> <!subteam^S0OPS>",
                                     names: names)
        XCTAssertEqual(String(s.characters), "@Sam Lee @priya @someone #leadership #general @here @channel @design @team")
        XCTAssertEqual(s[try range("@Sam Lee", in: s)].inlinePresentationIntent, .stronglyEmphasized)
        XCTAssertEqual(s[try range("#leadership", in: s)].inlinePresentationIntent, .stronglyEmphasized)
        XCTAssertEqual(SlackText.readable("1 &lt; 2 &amp;&amp; 3 &gt; 2"), "1 < 2 && 3 > 2")

        // Dates in this Mac's time zone, as real dates; the fallback when there's no time.
        let due = SlackFixture.dueDate
        XCTAssertEqual(SlackText.readable("Due <!date^1791547200^{date_short} at {time}|Fri 9 Oct>"),
                       "Due \(Fmt.absoluteDay(due)) at \(Fmt.time(due))")
        XCTAssertEqual(SlackText.readable("Due <!date^soon^{date}|whenever>"), "Due whenever")
    }

    func testCodeBlocksAndQuotes() throws {
        let block = SlackText.attributed("Run this:\n```git push &amp;&amp; deploy\n*not bold* :tada:```\nThen tell me", names: [:])
        XCTAssertEqual(String(block.characters), "Run this:\ngit push && deploy\n*not bold* :tada:\nThen tell me")
        XCTAssertEqual(block[try range("git push && deploy\n*not bold* :tada:", in: block)].inlinePresentationIntent, .code)
        XCTAssertNil(block[try range("Then tell me", in: block)].inlinePresentationIntent)
        XCTAssertEqual(SlackText.readable("See ```x = 1``` above"), "See\nx = 1\nabove", "a block mid-line gets lines of its own")

        let quote = "&gt; Can you send the deck?\nSure, sending now"
        XCTAssertEqual(SlackText.readable(quote), "> Can you send the deck?\nSure, sending now")
        let rich = SlackText.attributed(quote, names: [:])
        XCTAssertEqual(String(rich.characters), "\(SlackMarkup.quoteBar)Can you send the deck?\nSure, sending now")
        XCTAssertEqual(rich[try range("Can you send the deck?", in: rich)].swiftUI.foregroundColor, Color.ink2)
        XCTAssertEqual(rich[try range(SlackMarkup.quoteBar, in: rich)].swiftUI.foregroundColor, Color.hairStrong)
        XCTAssertNil(rich[try range("Sure, sending now", in: rich)].swiftUI.foregroundColor)
        XCTAssertEqual(SlackText.readable("Notes\n&gt;&gt;&gt; First point\nSecond point\n&gt; Third point"),
                       "Notes\n> First point\n> Second point\n> Third point")
        XCTAssertEqual(SlackText.readable("\n\n  Hello  \n\n"), "  Hello", "no blank lines around the message")
    }

    func testEmojiNamesBecomeEmoji() {
        XCTAssertEqual(SlackText.readable("Shipped :tada: :+1::skin-tone-3: :partyparrot: at 10:30:45 `:tada:`"),
                       "Shipped 🎉 \u{1F44D}\u{1F3FC} :partyparrot: at 10:30:45 :tada:")
        XCTAssertEqual(SlackEmoji.emoji(named: "heart"), "\u{2764}\u{FE0F}", "shown as an emoji, not a text heart")
        XCTAssertEqual(SlackEmoji.emoji(named: "v", skinTone: 4), "\u{270C}\u{1F3FD}")
        XCTAssertEqual(SlackEmoji.emoji(named: "tada", skinTone: 2), "🎉", "no skin tone to take")
        XCTAssertEqual(SlackEmoji.emoji(named: "one"), "1\u{FE0F}\u{20E3}")
        XCTAssertEqual(SlackEmoji.emoji(named: "flag-gb"), "🇬🇧")
        XCTAssertNil(SlackEmoji.emoji(named: "flag-gbr"))
        XCTAssertNil(SlackEmoji.emoji(named: "partyparrot"))
        XCTAssertEqual(SlackEmoji.replacingShortcodes(in: "no emoji here"), "no emoji here")
    }

    func testOutgoingTextIsEscapedOnceButKeepsLinksAndMentions() {
        XCTAssertEqual(SlackText.outgoing("a < b & c > d"), "a &lt; b &amp; c &gt; d")
        XCTAssertEqual(SlackText.outgoing("<https://docs.example.com/q4?a=1&b=2|Q&A sheet> <@U0SAM> <#C0LEAD|leadership> <!here> <b>bold</b>"),
                       "<https://docs.example.com/q4?a=1&amp;b=2|Q&amp;A sheet> <@U0SAM> <#C0LEAD|leadership> &lt;!here&gt; &lt;b&gt;bold&lt;/b&gt;")
        XCTAssertEqual(SlackText.outgoing("*bold* _italic_ ~gone~ `code`"), "*bold* _italic_ ~gone~ `code`", "formatting is left to Slack")
        for text in ["Q&A <b> & <https://x.example/?a=1&b=2|x&y> > quoted", "&amp; &lt; &gt; &quot;", "Tom & Jerry &&", ""] {
            let once = SlackText.outgoing(text)
            XCTAssertEqual(SlackText.outgoing(once), once, "escaping twice changes nothing: \(text)")
            XCTAssertEqual(SlackText.readable(once), SlackText.readable(SlackText.outgoing(once)))
        }
        XCTAssertEqual(SlackText.outgoing("&amp; &quot;"), "&amp; &amp;quot;", "only Slack's three escapes count as escaped")
        XCTAssertEqual(SlackText.readable(SlackText.outgoing("Q&A <b> & 1 < 2")), "Q&A <b> & 1 < 2", "what you wrote is what Slack shows")
    }
}
