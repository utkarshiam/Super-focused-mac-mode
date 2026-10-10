import MemoryKit
import XCTest
@testable import Docket

// The Memory screens' rules, without a window: what each filter shows, how an answer's [n] markers become
// citation chips, which typed text ⌘K treats as a question and where asking takes you, the real dates and
// words the screens use, where a memory's source opens, and Ask without a key (a search, no network).
// Made-up people (Priya Shah, Jordan Lee) and a throwaway library folder.

@MainActor
final class MemoryViewsTests: XCTestCase {
    private var folders: [URL] = []

    override func tearDown() async throws {
        for folder in folders { try? FileManager.default.removeItem(at: folder) }
        folders = []
    }

    private func library() -> MemoryLibrary {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("docket-memory-views-\(UUID().uuidString)")
        folders.append(folder)
        return MemoryLibrary(directory: folder, saveDelay: 0)
    }

    // MARK: Filters

    func testKindFiltersMapToKinds() {
        XCTAssertEqual(MemoryScope.all.filter, MemoryFilter())
        XCTAssertEqual(MemoryScope.notes.filter.kinds, [.note, .text, .engram])
        XCTAssertEqual(MemoryScope.links.filter.kinds, [.link])
        XCTAssertEqual(MemoryScope.media.filter.kinds, [.image, .video, .audio])
        XCTAssertEqual(MemoryScope.files.filter.kinds, [.pdf, .file])
        XCTAssertEqual(MemoryScope.messages.filter.kinds, [.message])
        XCTAssertEqual(MemoryScope.tasks.filter.kinds, [.task])
        // Every kind is reachable from one of the chips.
        let covered = MemoryScope.kinds.reduce(into: Set<MemoryKind>()) { $0.formUnion($1.filter.kinds) }
        XCTAssertEqual(covered, Set(MemoryKind.allCases))
    }

    func testBrowseFiltersMapToPeopleProjectsAndMoments() {
        XCTAssertEqual(MemoryScope.person("Priya Shah").filter.person, "Priya Shah")
        XCTAssertEqual(MemoryScope.project("Seed round").filter.project, "Seed round")
        XCTAssertEqual(MemoryScope.moments(.promise).filter.momentKind, .promise)
        XCTAssertTrue(MemoryScope.moments(.idea).isBrowse)
        XCTAssertFalse(MemoryScope.media.isBrowse)

        let promise = MemoryItem(title: "Deck", moments: [Moment(kind: .promise, text: "Send the deck")])
        let plain = MemoryItem(title: "Plain")
        XCTAssertTrue(MemoryScope.moments(.promise).filter.matches(promise))
        XCTAssertFalse(MemoryScope.moments(.promise).filter.matches(plain))
    }

    func testBrowseLabelsUseTheLensWords() {
        let sales = Lens.sales.vocabulary
        XCTAssertEqual(MemoryScope.moments(.promise).label(sales), "Next steps")
        XCTAssertEqual(MemoryScope.moments(.insight).label(sales), "Objections")
        XCTAssertEqual(MemoryScope.moments(.promise).label(.neutral), "Promises")
        XCTAssertEqual(MemoryScope.person("Jordan Lee").label(sales), "Jordan Lee")
        XCTAssertEqual(MemoryScope.media.label(sales), "Media")
    }

    func testGridForMediaAndMostlyPictures() {
        XCTAssertTrue(MemoryScope.usesGrid(.media, kinds: []))
        XCTAssertTrue(MemoryScope.usesGrid(.all, kinds: [.image, .image, .video, .note]))
        XCTAssertFalse(MemoryScope.usesGrid(.all, kinds: [.image, .note, .note, .link]))
        XCTAssertFalse(MemoryScope.usesGrid(.all, kinds: [.image, .image]), "a couple of photos stay a list")
    }

    // MARK: Citations

    func testCitationsSplitIntoChipsAfterTheWord() {
        let segments = CitationText.segments("Raised on a SAFE [1][2]. Priya sends terms [3].", valid: 1...3)
        XCTAssertEqual(segments, [.text("Raised on a SAFE"), .citation(1), .citation(2), .text(". Priya sends terms"), .citation(3), .text(".")])
    }

    func testCitationsOutsideTheSourcesStayText() {
        let segments = CitationText.segments("Pricing changed [4] and [1].", valid: 1...2)
        XCTAssertEqual(segments, [.text("Pricing changed [4] and"), .citation(1), .text(".")])
        XCTAssertEqual(CitationText.segments("No sources here."), [.text("No sources here.")])
    }

    func testCitationNumbersInOrderWithoutRepeats() {
        XCTAssertEqual(CitationText.numbers(in: "A [2]. B [1][2]. C [3]"), [2, 1, 3])
        XCTAssertEqual(CitationText.numbers(in: "Nothing cited"), [])
    }

    // MARK: ⌘K

    func testQuestionsAreRecognised() {
        XCTAssertTrue(PaletteMemory.looksLikeQuestion("what did investors push back on"))
        XCTAssertTrue(PaletteMemory.looksLikeQuestion("pricing?"))
        XCTAssertTrue(PaletteMemory.looksLikeQuestion("Who is the champion at Acme"))
        XCTAssertTrue(PaletteMemory.looksLikeQuestion("did I send the deck to Priya"))
        XCTAssertFalse(PaletteMemory.looksLikeQuestion("call Priya tomorrow 10am"))
        XCTAssertFalse(PaletteMemory.looksLikeQuestion("what"), "one word is a search, not a question")
        XCTAssertFalse(PaletteMemory.looksLikeQuestion("   "))
    }

    func testAskingFromThePaletteOpensMemoryWithTheQuestion() {
        let app = AppState()
        var shown = 0
        app.showMainWindow = { shown += 1 }
        app.selection = .calendar
        app.selectedMemoryID = UUID()
        app.askMemory("  What did I promise Jordan Lee?  ")
        XCTAssertEqual(app.selection, .memory)
        XCTAssertEqual(app.memoryQuestion, "What did I promise Jordan Lee?")
        XCTAssertNil(app.selectedMemoryID, "the answer shows without an item open over it")
        XCTAssertEqual(shown, 1)

        app.memoryQuestion = nil
        app.askMemory("   ")
        XCTAssertNil(app.memoryQuestion, "blank text asks nothing")
    }

    func testRevealingAMemoryOpensIt() {
        let app = AppState()
        let id = UUID()
        app.selection = .notes
        app.reveal(memory: id)
        XCTAssertEqual(app.selection, .memory)
        XCTAssertEqual(app.selectedMemoryID, id)
        XCTAssertFalse(SidebarItem.memory.isTaskView)
    }

    // MARK: Words and dates

    func testDatesAreAlwaysRealDates() {
        let cal = Calendar.current
        let now = cal.date(bySettingHour: 12, minute: 0, second: 0, of: Date())!
        for offset in [-1, 0, 1, 2] {
            let d = cal.date(byAdding: .day, value: offset, to: now)!
            let label = MemoryText.date(d, now: now)
            XCTAssertEqual(label, Fmt.absoluteDay(d, now: now))
            for word in ["Today", "Tomorrow", "Yesterday"] {
                XCTAssertFalse(label.contains(word), "\(label) uses a relative word")
                XCTAssertFalse(MemoryText.dateTime(d, now: now).contains(word))
            }
        }
        let lastYear = cal.date(byAdding: .year, value: -1, to: now)!
        XCTAssertTrue(MemoryText.date(lastYear, now: now).contains(String(cal.component(.year, from: lastYear))))
    }

    func testPromiseLines() {
        let now = Date()
        let due = Calendar.current.date(byAdding: .day, value: 3, to: Calendar.current.startOfDay(for: now))!
        let theirs = Moment(kind: .promise, text: "Send the term sheet", who: "Priya Shah", due: due, direction: .theirs)
        XCTAssertEqual(MemoryText.promiseLine(theirs, now: now), "Priya Shah · due \(Fmt.absoluteDay(due, now: now))")
        let mine = Moment(kind: .promise, text: "Send the letter", who: "Jordan Lee", due: due, direction: .mine)
        XCTAssertEqual(MemoryText.promiseLine(mine, now: now), "You · due \(Fmt.absoluteDay(due, now: now))")
        XCTAssertNil(MemoryText.promiseLine(Moment(kind: .promise, text: "Someday"), now: now))
    }

    func testCountsAndMatches() {
        XCTAssertEqual(MemoryText.count(1), "1 memory")
        XCTAssertEqual(MemoryText.count(12), "12 memories")
        XCTAssertEqual(MemoryText.matches(0, "pricing"), "Nothing matches “pricing”")
        XCTAssertEqual(MemoryText.matches(1, "pricing"), "1 memory matches “pricing”")
        XCTAssertEqual(MemoryText.matches(3, "pricing"), "3 memories match “pricing”")
    }

    func testPlaceholderUsesAnExampleTheChipsDontShow() {
        let chips = MemoryText.askChips([.founder])
        XCTAssertEqual(chips.count, 3)
        let placeholder = MemoryText.askPlaceholder([.founder])
        XCTAssertTrue(placeholder.hasPrefix("Ask your memory"))
        XCTAssertFalse(chips.contains { placeholder.contains($0) })
    }

    // MARK: Sources

    func testSourceLinks() {
        let task = UUID(), note = UUID()
        XCTAssertEqual(MemorySourceLink.resolve(MemoryItem(sourceRef: SourceRef.task(task)), messageIDs: []), .task(task))
        XCTAssertEqual(MemorySourceLink.resolve(MemoryItem(sourceRef: SourceRef.note(note)), messageIDs: []), .note(note))

        let ids = ["slack:C0B/1700.0001", "gmail:18c2/18c9", "gmail:18c2/18ca"]
        let slack = MemoryItem(sourceRef: SourceRef.slack(channel: "C0B", ts: "1700.0001"))
        XCTAssertEqual(MemorySourceLink.resolve(slack, messageIDs: ids), .message("slack:C0B/1700.0001"))
        let mail = MemoryItem(sourceRef: SourceRef.gmail(threadID: "18c2"))
        XCTAssertEqual(MemorySourceLink.resolve(mail, messageIDs: ids), .message("gmail:18c2/18c9"))
        // Gone from Messages: nothing to open (unless it has a web address).
        XCTAssertNil(MemorySourceLink.resolve(slack, messageIDs: []))
        let link = MemoryItem(kind: .link, sourceRef: SourceRef.url("https://example.com/a"), url: "https://example.com/a")
        XCTAssertEqual(MemorySourceLink.resolve(link, messageIDs: []), .web(URL(string: "https://example.com/a")!))
        XCTAssertNil(MemorySourceLink.resolve(MemoryItem(url: "file:///etc/hosts"), messageIDs: []))
    }

    // MARK: Ask without a key

    func testAskWithoutAKeySearchesInstead() async {
        let library = library()
        library.addNote("Outcome-led headlines convert best on pricing pages.", title: "Pricing page teardown")
        library.addNote("Lunch with Jordan Lee.", title: "Lunch")
        let ask = MemoryAskModel()
        ask.ask("pricing", library: library, ai: nil)
        XCTAssertEqual(ask.phase, .noKey)
        XCTAssertTrue(ask.showsSearch)
        for _ in 0..<100 where ask.searching { try? await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertEqual(ask.hits.map(\.item.title), ["Pricing page teardown"])
        XCTAssertNil(ask.answer)

        // Typing something else goes back to filtering as you type.
        ask.query = "lunch"
        ask.textChanged()
        XCTAssertFalse(ask.showsSearch)
        XCTAssertEqual(ask.phase, .idle)

        ask.clear()
        XCTAssertEqual(ask.query, "")
        XCTAssertTrue(ask.hits.isEmpty)
    }
}
