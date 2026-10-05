import XCTest
@testable import Docket

@MainActor
final class SearchTests: XCTestCase {
    var dir: URL!

    override func setUp() async throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("docket-search-\(UUID().uuidString)")
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private func makeStore(tasks: [TaskItem] = [], notes: [Note] = [], lists: [TaskList] = []) -> Store {
        let store = Store(persistence: Persistence(directory: dir), seedIfEmpty: false)
        // Loaded in one go, like opening a saved file (no undo steps, timestamps kept).
        var db = Database()
        db.tasks = tasks
        db.notes = notes
        db.lists = lists
        store.apply(db)
        return store
    }

    private func titles(_ results: SearchResults) -> [String] { results.tasks.map(\.title) }

    private func task(_ title: String, _ configure: (inout TaskItem) -> Void = { _ in }) -> TaskItem {
        var t = TaskItem(title: title)
        configure(&t)
        return t
    }

    private func note(_ body: String, pinned: Bool = false, edited: Date = Date()) -> Note {
        var n = Note(body: body)
        n.isPinned = pinned
        n.updatedAt = edited
        return n
    }

    // MARK: Query

    func testQueryWordsPhrasesAndTags() {
        let q = SearchQuery(#"Board  "Q3  Numbers" #Hiring, café?"#)
        XCTAssertEqual(q.words, ["board", "cafe"])
        XCTAssertEqual(q.phrases, ["q3 numbers"])
        XCTAssertEqual(q.tagNames, ["hiring"])

        XCTAssertEqual(SearchQuery("“board deck”").phrases, ["board deck"], "typographic quotes work too")
        XCTAssertEqual(SearchQuery(#"plan "board de"#).phrases, ["board de"], "an unclosed quote is a phrase being typed")
        XCTAssertEqual(SearchQuery(#"plan "board de"#).words, ["plan"])
        XCTAssertEqual(SearchQuery("##q3").tagNames, ["q3"])
        XCTAssertEqual(SearchQuery("ZOË Straße").words, ["zoe", "strasse"])
        XCTAssertEqual(SearchQuery("(sign-off)").words, ["sign-off"], "only the ends lose punctuation")

        for nothing in ["", "   ", "#", #""""#, "?!", "“ ”"] {
            XCTAssertTrue(SearchQuery(nothing).isEmpty, "“\(nothing)” searches for nothing")
        }
    }

    func testEmptyQueryFindsNothing() {
        let store = makeStore(tasks: [task("Anything")], notes: [note("# Anything")])
        for text in ["", "  ", "#", "\"\""] {
            let r = store.search(text)
            XCTAssertTrue(r.isEmpty)
            XCTAssertTrue(r.query.isEmpty)
            XCTAssertNil(r.summary)
        }
    }

    // MARK: Matching

    func testMatchesEveryFieldIgnoringCaseAndAccents() {
        let fundraising = TaskList(name: "Fundraising")
        let store = makeStore(tasks: [
            task("Call the Café about catering"),
            task("Prep") { $0.notes = "Ask Zoë about the term sheet" },
            task("Plan offsite") { $0.tags = ["Leadership"] },
            task("Update model") { $0.listID = fundraising.id },
            task("Ship v2") { $0.subtasks = [Subtask(title: "Write release notes")] },
            task("Contract redlines") { $0.waitingOn = "Legal team" },
            task("Reply") {
                $0.source = TaskSource(kind: .slack, externalID: "slack:C024BE91L/1712345678.000100", url: nil, label: "#growth · Priya")
            },
        ], lists: [fundraising])

        XCTAssertEqual(titles(store.search("CAFE")), ["Call the Café about catering"])
        XCTAssertEqual(titles(store.search("café")), ["Call the Café about catering"])
        XCTAssertEqual(titles(store.search("zoe")), ["Prep"], "notes")
        XCTAssertEqual(titles(store.search("leadership")), ["Plan offsite"], "tags")
        XCTAssertEqual(titles(store.search("fundraising")), ["Update model"], "list name")
        XCTAssertEqual(titles(store.search("release notes")), ["Ship v2"], "steps")
        XCTAssertEqual(titles(store.search("legal")), ["Contract redlines"], "waiting on")
        XCTAssertEqual(titles(store.search("priya")), ["Reply"], "where it came from")
        XCTAssertTrue(store.search("northwind").isEmpty)
    }

    func testEveryWordHasToMatchSomewhere() {
        let store = makeStore(tasks: [
            task("Send deck") { $0.waitingOn = "Sam" },
            task("Send invoice"),
        ])
        XCTAssertEqual(Set(titles(store.search("send"))), ["Send deck", "Send invoice"])
        XCTAssertEqual(titles(store.search("send sam")), ["Send deck"], "words can match in different fields")
        XCTAssertEqual(titles(store.search("sam deck")), ["Send deck"])
        XCTAssertTrue(store.search("send pricing").isEmpty, "every word has to be found")
    }

    func testQuotedPhraseMatchesAsWritten() {
        let store = makeStore(tasks: [task("Board deck review"), task("Deck for the board")])
        XCTAssertEqual(titles(store.search(#""board deck""#)), ["Board deck review"])
        XCTAssertEqual(titles(store.search(#""Board   Deck""#)), ["Board deck review"], "spacing in the phrase doesn't matter")
        XCTAssertEqual(store.search("board deck").tasks.count, 2, "without quotes the words can be anywhere")
    }

    func testCurlyApostrophesMatchStraightOnes() {
        let store = makeStore(tasks: [task("Review Sam’s deck"), task("Book Sam's flight")],
                              notes: [note("# Prep\nSend Priya’s numbers to the board")])
        XCTAssertEqual(Set(titles(store.search("sam's"))), ["Review Sam’s deck", "Book Sam's flight"])
        XCTAssertEqual(Set(titles(store.search("sam’s"))), ["Review Sam’s deck", "Book Sam's flight"], "and the other way round")
        XCTAssertEqual(titles(store.search(#""sam's deck""#)), ["Review Sam’s deck"])

        XCTAssertEqual(store.search("priya's").notes.count, 1)
        XCTAssertEqual(SearchQuery("priya's").snippet(in: store.notes[0].body), "Send Priya’s numbers to the board")
        let line = "Send Priya’s numbers"
        XCTAssertEqual(SearchQuery("priya's").highlights(in: line).map { String(line[$0]) }, ["Priya’s"])
    }

    func testPhrasesDontRunAcrossFields() {
        let store = makeStore(tasks: [task("Plan") { $0.tags = ["board"]; $0.notes = "deck" }])
        XCTAssertTrue(store.search(#""board deck""#).isEmpty)
        XCTAssertEqual(store.search("board deck").tasks.count, 1)
    }

    func testTagFilter() {
        let store = makeStore(tasks: [
            task("Screen candidates") { $0.tags = ["Hiring"] },
            task("Draft job post") { $0.tags = ["hiring-2026", "ops"] },
            task("Hiring plan"),
        ], notes: [
            note("# Sync\nNotes from the #hiring sync"),
            note("# Languages\nC#hiring is not a tag"),
            note("# Hiring\nA heading, not a tag"),
        ])
        XCTAssertEqual(Set(titles(store.search("#hiring"))), ["Screen candidates", "Draft job post"],
                       "a tag filter only looks at tags (and longer tags that start the same)")
        XCTAssertEqual(titles(store.search("#HIRING screen")), ["Screen candidates"], "tags and words combine")
        XCTAssertEqual(titles(store.search("#ops")), ["Draft job post"])
        XCTAssertTrue(store.search("#legal").tasks.isEmpty)
        XCTAssertEqual(store.search("#hiring").notes.map(\.title), ["Sync"], "notes match a #hashtag they mention")
        XCTAssertEqual(Set(titles(store.search("hiring"))), ["Screen candidates", "Draft job post", "Hiring plan"],
                       "a plain word finds tags too")
    }

    // MARK: Ranking

    func testTitleStartBeatsTitleWordBeatsInsideBeatsOtherFields() {
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        let store = makeStore(tasks: [
            // Dates are set so that date order alone would come out exactly backwards.
            task("Budget") { $0.notes = "Pricing questions from Northwind"; $0.dueDate = today },
            task("Ask the sprint team") { $0.dueDate = cal.date(byAdding: .day, value: 1, to: today) },
            task("Update pricing page") { $0.dueDate = cal.date(byAdding: .day, value: 2, to: today) },
            task("Pricing review") { $0.dueDate = cal.date(byAdding: .day, value: 3, to: today) },
        ])
        XCTAssertEqual(titles(store.search("pri")), ["Pricing review", "Update pricing page", "Ask the sprint team", "Budget"])
    }

    func testTypingTheStartOfATitleRanksItFirst() {
        let store = makeStore(tasks: [
            task("Review the board deck"),
            task("Deck for the board"),
            task("Board deck review"),
            task("Board deck"),
            task("“Board deck” notes"),
        ])
        XCTAssertEqual(titles(store.search("board deck")),
                       ["Board deck", "Board deck review", "“Board deck” notes", "Deck for the board", "Review the board deck"],
                       "the exact title, then titles starting with what was typed, then more words in the title")
    }

    func testEqualMatchesOrderByDateThenPriority() {
        let cal = Calendar.current
        let now = Date()
        let today = cal.startOfDay(for: now)
        let store = makeStore(tasks: [
            task("Call bank"),
            task("Call landlord") { $0.priority = .urgent },
            task("Call investor") { $0.dueDate = cal.date(byAdding: .day, value: 3, to: today) },
            task("Call accountant") { $0.dueDate = cal.date(byAdding: .day, value: -1, to: today) },
            task("Call printer") { $0.scheduledDate = cal.date(byAdding: .day, value: 1, to: today) },
        ])
        XCTAssertEqual(titles(store.search("call", now: now)),
                       ["Call accountant", "Call printer", "Call investor", "Call landlord", "Call bank"],
                       "overdue first, then by the date on the row (deadline or plan), undated last by priority")
    }

    func testEqualMatchesFallBackToTitleOrder() {
        let store = makeStore(tasks: [
            task("Call Zoë"), task("Call investors re Q3 plan"), task("Call Émile"), task("call amy"), task("Call investors re Q2 plan"),
        ])
        XCTAssertEqual(titles(store.search("call")),
                       ["call amy", "Call Émile", "Call investors re Q2 plan", "Call investors re Q3 plan", "Call Zoë"],
                       "case and accents ignored, and titles told apart past their first few letters")
    }

    func testOverdueComesFirstAmongEqualMatches() throws {
        let cal = Calendar.current
        // Mid-afternoon, so two hours earlier and later are both today.
        let now = try XCTUnwrap(cal.date(bySettingHour: 15, minute: 0, second: 0, of: Date()))
        let today = cal.startOfDay(for: now)
        let store = makeStore(tasks: [
            task("Send deck today") { $0.dueDate = today },
            task("Send deck at five") { $0.dueDate = now.addingTimeInterval(2 * 3600); $0.dueHasTime = true },
            task("Send deck at one") { $0.dueDate = now.addingTimeInterval(-2 * 3600); $0.dueHasTime = true },
            task("Send deck yesterday") { $0.dueDate = cal.date(byAdding: .day, value: -1, to: today) },
        ])
        XCTAssertEqual(titles(store.search("send deck", now: now)),
                       ["Send deck yesterday", "Send deck at one", "Send deck at five", "Send deck today"],
                       "overdue first (an earlier day, or a time that has passed); a timed deadline before the day's date-only ones")
    }

    func testOpenThenCompletedNewestFirstLimitedToFifty() {
        let now = Date()
        var tasks = [task("Weekly report draft")]
        for i in 0..<55 {
            tasks.append(task("Weekly report \(i)") { $0.completedAt = now.addingTimeInterval(Double(-i) * 3600) })
        }
        let store = makeStore(tasks: tasks)
        let r = store.search("weekly report")
        XCTAssertEqual(titles(r), ["Weekly report draft"])
        XCTAssertEqual(r.completed.count, Store.searchCompletedLimit)
        XCTAssertEqual(r.completedTotal, 55)
        XCTAssertEqual(r.completed.first?.title, "Weekly report 0", "newest first")
        XCTAssertEqual(r.completed.last?.title, "Weekly report 49")
        XCTAssertEqual(r.taskOrder, r.tasks.map(\.id) + r.completed.map(\.id))
        XCTAssertEqual(r.summary, "1 task · 55 completed")
    }

    func testJustTickedTasksStayWithTheOpenOnes() {
        let done = task("Book flights") { $0.completedAt = Date() }
        let store = makeStore(tasks: [done, task("Book hotel")])
        XCTAssertEqual(titles(store.search("book")), ["Book hotel"])
        XCTAssertEqual(store.search("book").completed.map(\.title), ["Book flights"])

        let kept = store.search("book", keeping: [done.id])
        XCTAssertEqual(Set(titles(kept)), ["Book flights", "Book hotel"])
        XCTAssertTrue(kept.completed.isEmpty)
        XCTAssertEqual(kept.summary, "1 task · 1 completed")
    }

    func testNotesComeAfterTasksTitleMatchesFirst() {
        let old = Date(timeIntervalSinceNow: -86_400 * 3)
        let store = makeStore(tasks: [task("Board pack")], notes: [
            note("# Weekly\nPrep the board pack", edited: Date()),
            note("# Ideas\nBoard games night", pinned: true, edited: old),
            note("# Board offsite\nAgenda and travel", edited: old),
            note("   \n  "),
        ])
        let r = store.search("board")
        XCTAssertEqual(titles(r), ["Board pack"])
        XCTAssertEqual(r.notes.map(\.title), ["Board offsite", "Ideas", "Weekly"],
                       "title matches first; then pinned before the rest; blank notes never match")
        XCTAssertEqual(r.summary, "1 task · 3 notes")
    }

    // MARK: Staying current

    func testSearchSeesEditsRenamesAndUndo() {
        let store = makeStore()
        let ops = store.addList(name: "Operations", color: .gray)
        let memo = store.addTask(task("Draft memo") { $0.listID = ops.id })
        XCTAssertEqual(titles(store.search("memo")), ["Draft memo"])

        let undo = UndoManager()
        undo.groupsByEvent = false
        store.undoManager = undo
        undo.beginUndoGrouping()
        store.mutateTask(memo.id, undo: "Rename") { $0.title = "Draft letter" }
        undo.endUndoGrouping()
        XCTAssertTrue(store.search("memo").isEmpty)
        XCTAssertEqual(titles(store.search("letter")), ["Draft letter"])

        undo.undo()
        XCTAssertEqual(titles(store.search("memo")), ["Draft memo"], "undo brings the old title back into search")
        store.undoManager = nil

        var renamed = ops
        renamed.name = "Admin"
        store.updateList(renamed)
        XCTAssertEqual(titles(store.search("admin")), ["Draft memo"], "list renames show up at once")
        XCTAssertTrue(store.search("operations").isEmpty)

        let n = store.addNote(body: "# Retro\nWhat went well")
        XCTAssertEqual(store.search("went").notes.map(\.id), [n.id])
        store.updateNoteBody(n.id, "# Retro\nWhat to change")
        XCTAssertTrue(store.search("went").notes.isEmpty)
        XCTAssertEqual(store.search("change").notes.map(\.id), [n.id])

        store.deleteTasks([memo.id])
        XCTAssertTrue(store.search("draft").isEmpty)
    }

    func testTenThousandTasksStayFast() {
        // A reproducible mix of titles, notes, tags, steps and people.
        var seed: UInt64 = 42
        func next(_ n: Int) -> Int {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            return Int((seed >> 33) % UInt64(n))
        }
        let words = ["board", "deck", "review", "call", "budget", "numbers", "hiring", "plan", "café", "investor", "update",
                     "send", "draft", "contract", "pricing", "roadmap", "launch", "sync", "metrics", "offsite", "renewal", "Zoë"]
        func phrase(_ n: Int) -> String { (0..<n).map { _ in words[next(words.count)] }.joined(separator: " ") }
        var tasks: [TaskItem] = []
        for i in 0..<10_000 {
            tasks.append(task("\(phrase(3 + next(5))) \(i)") { t in
                if next(10) < 3 { t.notes = phrase(30) }
                if next(10) < 4 { t.tags = [words[next(words.count)].lowercased()] }
                if next(10) < 2 { t.subtasks = (0..<3).map { _ in Subtask(title: phrase(4)) } }
                if next(10) == 0 { t.waitingOn = "Sam" }
                if next(5) == 0 { t.completedAt = Date(timeIntervalSinceNow: Double(-next(100_000))) }
            })
        }
        let notes = (0..<300).map { _ in note("# \(phrase(4))\n\(phrase(120))") }
        let store = makeStore(tasks: tasks, notes: notes)

        var start = Date()
        let first = store.search("zoe")
        let cold = Date().timeIntervalSince(start)
        XCTAssertFalse(first.tasks.isEmpty)

        start = Date()
        let r = store.search("board review")
        let warm = Date().timeIntervalSince(start)
        let expected = tasks.filter { t in
            ["board", "review"].allSatisfy { w in
                ([t.title, t.notes, t.waitingOn ?? ""] + t.tags + t.subtasks.map(\.title)).contains { $0.localizedCaseInsensitiveContains(w) }
            }
        }
        XCTAssertEqual(r.tasks.count + r.completedTotal, expected.count)
        XCTAssertTrue(r.tasks.allSatisfy { !$0.isCompleted })

        // One letter matches nearly everything: the most results there are to put in order.
        start = Date()
        let broad = store.search("e")
        let broadTime = Date().timeIntervalSince(start)
        XCTAssertGreaterThan(broad.tasks.count, 5_000)

        // Generous limits for a debug build on a busy machine; release builds are far faster.
        XCTAssertLessThan(cold, 3, "first search, folding every task and note")
        XCTAssertLessThan(warm, 0.75, "later searches reuse the folded text")
        XCTAssertLessThan(broadTime, 1.5, "ordering thousands of matches")
    }

    func testPreparingFoldsAheadWithoutChangingResults() {
        let store = makeStore(tasks: [task("Draft board memo"), task("Board pack") { $0.completedAt = Date() }],
                              notes: [note("# Board\nAgenda")])
        let before = store.search("board")
        store.prepareSearch()
        let after = store.search("board", now: Date().addingTimeInterval(1))
        XCTAssertEqual(after.tasks.map(\.id), before.tasks.map(\.id))
        XCTAssertEqual(after.completed.map(\.id), before.completed.map(\.id))
        XCTAssertEqual(after.notes.map(\.id), before.notes.map(\.id))
    }

    // MARK: Highlights and excerpts

    func testHighlightsFindWordsIgnoringCaseAndAccents() {
        let text = "The Board met at the Café; board again"
        let ranges = SearchQuery("board cafe").highlights(in: text)
        XCTAssertEqual(ranges.map { String(text[$0]) }, ["Board", "Café", "board"])
        XCTAssertEqual(SearchQuery("boa board").highlights(in: "Onboarding").map { String("Onboarding"[$0]) }, ["board"],
                       "overlapping matches merge")
        XCTAssertEqual(SearchQuery("#q3").highlights(in: "Plan #Q3 offsite").count, 1)
        XCTAssertTrue(SearchQuery("xyz").highlights(in: text).isEmpty)
    }

    func testSnippetShowsTheMatchingLineWithoutMarkdown() {
        let body = "# Weekly sync\n\n- [ ] Send the **board** pack to Priya\n> quoted board line"
        XCTAssertEqual(SearchQuery("board").snippet(in: body), "Send the board pack to Priya")
        XCTAssertNil(SearchQuery("weekly").snippet(in: body), "a match in the title uses the usual preview")
        XCTAssertNil(SearchQuery("missing").snippet(in: body))

        let long = "# Notes\n" + String(repeating: "Lots of earlier context words here. ", count: 8)
            + "The renewal terms for Northwind are due" + String(repeating: " and then more trailing words", count: 8)
        let snippet = SearchQuery("renewal").snippet(in: long, maxLength: 80) ?? ""
        XCTAssertTrue(snippet.hasPrefix("…"), snippet)
        XCTAssertTrue(snippet.hasSuffix("…"), snippet)
        XCTAssertTrue(snippet.contains("renewal terms"), snippet)
        XCTAssertLessThanOrEqual(snippet.count, 82)
    }

    func testSnippetFindsMatchesAcrossMarkdownInLongNotes() {
        let body = "# Plans\n" + String(repeating: "Nothing to look at on this line\n", count: 3_000)
            + "See **board** deck and ![Offsite venue](attachments/venue.jpg)\nRename snake_case_name"
        XCTAssertEqual(SearchQuery(#""board deck""#).snippet(in: body), "See board deck and Photo: Offsite venue",
                       "a phrase across emphasis marks")
        XCTAssertEqual(SearchQuery("photo").snippet(in: body), "See board deck and Photo: Offsite venue", "photos by what they show")
        XCTAssertEqual(SearchQuery("snake_case").snippet(in: body), "Rename snake_case_name", "underscores inside words stay")
        XCTAssertNil(SearchQuery("plans").snippet(in: body), "only the title matches")
    }

    func testNoteExcerptFollowsEdits() {
        let store = makeStore(notes: [note("# Weekly\nSend the board pack")])
        let id = store.notes[0].id
        XCTAssertEqual(SearchQuery("board").excerpt(for: store.notes[0]), "Send the board pack")
        store.updateNoteBody(id, "# Weekly\nAgenda\nBoard review moved to Friday")
        XCTAssertEqual(SearchQuery("board").excerpt(for: store.notes[0]), "Board review moved to Friday",
                       "an edited note shows its new matching line")
        XCTAssertEqual(SearchQuery("agenda").excerpt(for: store.notes[0]), "Agenda", "each query gets its own line")
        XCTAssertEqual(SearchQuery("weekly").excerpt(for: store.notes[0]), store.notes[0].preview,
                       "a match in the title shows the opening lines")
    }

    // MARK: Navigation

    func testEnteringAndEndingSearchGoesBackWhereYouWere() {
        let store = makeStore()
        let list = store.addList(name: "Board", color: .gray)
        let t = store.addTask(task("Prep deck") { $0.listID = list.id })
        let app = AppState()
        app.selection = .list(list.id)
        app.selectedTaskID = t.id

        app.searchText = "deck"
        app.enterSearch()
        XCTAssertEqual(app.selection, .search)
        XCTAssertEqual(app.selectionBeforeSearch, .list(list.id))
        XCTAssertNil(app.selectedTaskID)
        XCTAssertEqual(app.searchTaskOrder(in: store), [t.id])

        app.enterSearch()
        XCTAssertEqual(app.selectionBeforeSearch, .list(list.id), "already searching: where to go back to is kept")

        app.endSearch(in: store)
        XCTAssertEqual(app.searchText, "")
        XCTAssertEqual(app.selection, .list(list.id))
        XCTAssertEqual(app.selectedTaskID, t.id, "the task that was open is open again")

        // A list deleted in the meantime falls back to the Inbox.
        app.searchText = "deck"
        app.enterSearch()
        store.deleteList(list.id)
        app.endSearch(in: store)
        XCTAssertEqual(app.selection, .inbox)

        // Away from the Search view, ending a search only clears the text.
        app.searchText = "left over"
        app.selection = .important
        app.endSearch(in: store)
        XCTAssertEqual(app.searchText, "")
        XCTAssertEqual(app.selection, .important)
    }

    func testEndingSearchFromATagNoOpenTaskHasGoesToTheInbox() {
        let store = makeStore()
        let tagged = store.addTask(task("Screen candidates") { $0.tags = ["hiring"] })
        let app = AppState()
        app.selection = .tag("hiring")
        app.searchText = "screen"
        app.enterSearch()
        store.mutateTask(tagged.id) { $0.tags = [] }
        app.endSearch(in: store)
        XCTAssertEqual(app.selection, .inbox)

        app.selection = .tag("ops")
        store.mutateTask(tagged.id) { $0.tags = ["Ops"] }
        app.searchText = "screen"
        app.enterSearch()
        app.endSearch(in: store)
        XCTAssertEqual(app.selection, .tag("ops"), "a tag still in use is where you go back to, whatever its case")
    }

    func testEachAppStateRemembersItsOwnOpenTask() {
        let store = makeStore()
        let t = store.addTask(task("Prep deck"))
        let first = AppState(), second = AppState()
        first.selection = .inbox
        first.selectedTaskID = t.id
        first.searchText = "deck"
        first.enterSearch()
        second.selection = .inbox
        second.searchText = "deck"
        second.enterSearch()

        second.endSearch(in: store)
        XCTAssertNil(second.selectedTaskID, "nothing was open in this one")
        first.endSearch(in: store)
        XCTAssertEqual(first.selectedTaskID, t.id)
    }

    /// Search lists its own rows, so arrows, ⇧-click ranges and ⌘A go through `searchResultIDs`, which the
    /// Search view keeps equal to the task results in on-screen order (open, then completed).
    func testArrowsRangesAndSelectAllFollowTheResultsOnScreen() {
        let deck = task("Board deck")
        let offsite = task("Plan board offsite")
        let minutes = task("Board minutes") { $0.completedAt = Date() }
        let store = makeStore(tasks: [offsite, task("Lunch with Sam"), minutes, deck])
        let app = AppState()
        app.searchText = "board"
        app.enterSearch()
        // What the Search view does whenever its results change.
        app.searchResultIDs = app.searchTaskOrder(in: store)
        XCTAssertEqual(app.visibleTaskOrder(in: store), [deck.id, offsite.id, minutes.id], "open by rank, then completed")

        XCTAssertTrue(app.moveSelection(by: 1, in: store))
        XCTAssertEqual(app.selectedTaskID, deck.id)
        app.moveSelection(by: 1, in: store)
        app.moveSelection(by: 1, in: store)
        XCTAssertEqual(app.selectedTaskID, minutes.id, "down into the completed ones")

        app.click(deck.id, .plain, in: store)
        app.click(minutes.id, .range, in: store)
        XCTAssertEqual(app.selectedTaskIDs, [deck.id, offsite.id, minutes.id], "⇧-click takes the rows in between")

        XCTAssertTrue(app.selectAllVisible(in: store))
        XCTAssertEqual(app.selectedTaskIDs, [deck.id, offsite.id], "⌘A takes the open results")

        app.searchText = "offsite"
        app.searchResultIDs = app.searchTaskOrder(in: store)
        XCTAssertEqual(app.visibleTaskOrder(in: store), [offsite.id], "a new query, new rows")

        app.endSearch(in: store)
        XCTAssertTrue(app.searchResultIDs.isEmpty, "nothing left over for the next search")
    }
}
