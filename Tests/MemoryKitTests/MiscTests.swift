import XCTest
@testable import MemoryKit

final class VectorIndexTests: XCTestCase {
    func testSetRemoveAndScores() {
        var index = VectorIndex()
        let a = UUID(), b = UUID(), c = UUID()
        index.set([1, 0], for: a, model: "m")
        index.set([0, 1], for: b, model: "m")
        index.set([1, 1], for: c, model: "m")
        XCTAssertEqual(index.count, 3)
        let scores = index.scores(for: [2, 0])
        XCTAssertEqual(scores[0], 1, accuracy: 1e-6)
        XCTAssertEqual(scores[1], 0, accuracy: 1e-6)
        XCTAssertEqual(scores[2], 0.7071, accuracy: 1e-3)
        XCTAssertEqual(index.nearest(to: [1, 0], limit: 2).map(\.id), [a, c])
        XCTAssertEqual(index.nearest(to: [1, 0], limit: 5, minScore: 0.5, excluding: [a]).map(\.id), [c])

        index.remove(a)
        XCTAssertEqual(index.count, 2)
        XCTAssertNil(index.vector(for: a))
        XCTAssertEqual(index.vector(for: c)![0], 0.7071, accuracy: 1e-3, "the moved row is still right")
        index.set([0, 5], for: c, model: "m")
        XCTAssertEqual(index.vector(for: c)!, [0, 1], "replacing keeps one row")
        XCTAssertEqual(index.count, 2)

        XCTAssertTrue(index.scores(for: [1, 0, 0]).isEmpty, "size mismatch")
        index.set([0, 0], for: UUID(), model: "m")
        XCTAssertEqual(index.count, 2, "zero vectors are ignored")
    }

    func testBinaryRoundTrip() throws {
        var index = VectorIndex()
        for _ in 0..<10 { index.set((0..<16).map { _ in Float.random(in: -1...1) }, for: UUID(), model: "gemini-embedding-2") }
        let data = index.encoded()
        XCTAssertEqual(data.prefix(4), Data("DMV1".utf8))
        XCTAssertEqual(try VectorIndex(data: data), index)
        XCTAssertThrowsError(try VectorIndex(data: Data("nope".utf8)))
        XCTAssertThrowsError(try VectorIndex(data: data.prefix(40)))
        XCTAssertEqual(try VectorIndex(data: VectorIndex().encoded()).count, 0)
    }

    func testCosine() {
        XCTAssertEqual(VectorIndex.cosine([1, 0], [0, 1]), 0)
        XCTAssertEqual(VectorIndex.cosine([1, 1], [2, 2]), 1, accuracy: 1e-6)
        XCTAssertEqual(VectorIndex.cosine([], []), 0)
        XCTAssertNil(VectorIndex.normalized([0, 0]))
    }
}

final class LinkFetcherTests: XCTestCase {
    func testExtractReadableText() {
        let html = """
        <html><head><title>Fallback &amp; title</title>
        <meta property="og:title" content="The Real Title">
        <meta content="https://cdn.example.com/x.jpg" property="og:image">
        <meta name="description" content="A page about things.">
        <style>.a{color:red}</style><script>var x = "<p>no</p>";</script></head>
        <body><header>Site header</header><nav><a>Home</a></nav>
        <main><h1>Heading</h1><p>First paragraph with &ldquo;quotes&rdquo; &#8212; and a dash.</p>
        <ul><li>One</li><li>Two</li></ul>
        <p>\(String(repeating: "More text. ", count: 50))</p></main>
        <footer>Copyright</footer></body></html>
        """
        let page = LinkFetcher.extract(html: html, baseURL: URL(string: "https://example.com/a"))
        XCTAssertEqual(page.title, "The Real Title")
        XCTAssertEqual(page.imageURL, "https://cdn.example.com/x.jpg")
        XCTAssertEqual(page.description, "A page about things.")
        XCTAssertTrue(page.text.hasPrefix("Heading\nFirst paragraph with “quotes” — and a dash."))
        XCTAssertTrue(page.text.contains("- One"))
        XCTAssertFalse(page.text.contains("color:red"))
        XCTAssertFalse(page.text.contains("Site header"))
        XCTAssertFalse(page.text.contains("Copyright"))
        XCTAssertFalse(page.text.contains("no</p>"))
    }

    func testFetchErrors() async {
        let fake = FakeTransport()
        fake.reply(status: 404, body: Data())
        fake.fail(URLError(.timedOut))
        let fetcher = LinkFetcher(transport: fake.transport)
        do { _ = try await fetcher.fetch("https://example.com/missing"); XCTFail() } catch {
            XCTAssertEqual((error as? MemoryAIError)?.isTransient, false)
        }
        do { _ = try await fetcher.fetch("https://example.com/slow"); XCTFail() } catch {
            XCTAssertEqual((error as? MemoryAIError)?.isTransient, true)
        }
        do { _ = try await fetcher.fetch("file:///etc/hosts"); XCTFail() } catch {
            XCTAssertEqual(fake.requests.count, 2, "non-web addresses are never requested")
        }
    }

    func testOfflineUnderTestsByDefault() async {
        do { _ = try await LinkFetcher().fetch("https://example.com"); XCTFail() } catch {
            XCTAssertEqual((error as? MemoryAIError)?.isTransient, true)
        }
    }
}

@MainActor
final class ResurfacingAndSeedTests: XCTestCase {
    var dir: URL!

    override func setUp() async throws { dir = makeTempDirectory() }
    override func tearDown() async throws { try? FileManager.default.removeItem(at: dir) }

    func testOnThisDay() {
        let library = MemoryLibrary(directory: dir, saveDelay: 60)
        let lastYear = library.addNote("Last year", createdAt: Calendar.current.date(byAdding: .year, value: -1, to: day(0))!)
        let twoYears = library.addNote("Two years", createdAt: Calendar.current.date(byAdding: .year, value: -2, to: day(0, hour: 8))!)
        library.addNote("Today", createdAt: day(0))
        library.addNote("Other day", createdAt: Calendar.current.date(byAdding: .year, value: -1, to: day(-1))!)
        XCTAssertEqual(library.onThisDay(day(0, hour: 18)).map(\.id), [lastYear.id, twoYears.id])
    }

    func testWorthRevisiting() {
        let library = MemoryLibrary(directory: dir, saveDelay: 60)
        let pinned = library.add(MemoryItem(title: "Pinned", pinned: true, createdAt: day(-60)))
        let promise = library.add(MemoryItem(title: "Owed", moments: [Moment(kind: .promise, text: "Send", due: day(-5))], createdAt: day(-30)))
        let related = library.add(MemoryItem(title: "Related", createdAt: day(-90)))
        let recent = library.add(MemoryItem(title: "This week", createdAt: day(-1)))
        let viewed = library.add(MemoryItem(title: "Seen", pinned: true, createdAt: day(-60), lastViewedAt: day(-2)))
        library.add(MemoryItem(title: "Plain", createdAt: day(-90)))
        library.setVector([1, 0.1, 0], for: related.id, model: "m")
        library.setVector([1, 0, 0], for: recent.id, model: "m")

        let picks = library.worthRevisiting(limit: 10, now: day(0))
        XCTAssertEqual(Set(picks.map(\.id)), [pinned.id, promise.id, related.id])
        XCTAssertEqual(picks.first { $0.id == related.id }?.reason, .relatedToRecent)
        XCTAssertEqual(picks.first { $0.id == promise.id }?.reason, .openPromise)
        XCTAssertFalse(picks.contains { $0.id == viewed.id })
        XCTAssertEqual(library.worthRevisiting(limit: 1, now: day(0)).count, 1)
    }

    func testDebugSeedLooksReal() throws {
        let library = MemoryLibrary(directory: dir, saveDelay: 60)
        library.addNote("Will be replaced")
        library.debugSeed(now: day(0))
        XCTAssertGreaterThanOrEqual(library.count, 15)
        XCTAssertFalse(library.items.contains { $0.body == "Will be replaced" })
        XCTAssertGreaterThanOrEqual(Set(library.items.map(\.kind)).count, 7, "many kinds")
        XCTAssertFalse(library.items.contains { TaskContext.isTaskItem($0) }, "tasks aren't memories")
        XCTAssertGreaterThanOrEqual(library.people().count, 6)
        XCTAssertGreaterThanOrEqual(library.projects().count, 8)
        XCTAssertFalse(library.moments(.promise, openOnly: true).isEmpty)
        XCTAssertEqual(library.vectors.model, MemoryLibrary.debugSeedModel)
        XCTAssertGreaterThanOrEqual(library.vectors.count, 14)
        XCTAssertEqual(library.lenses, [.founder, .manager])
        XCTAssertGreaterThanOrEqual(library.profile.facts.count, 5)
        XCTAssertFalse(library.onThisDay(day(0)).isEmpty)
        XCTAssertFalse(library.worthRevisiting(now: day(0)).isEmpty)

        let photo = try XCTUnwrap(library.items.first { $0.kind == .image && !$0.attachments.isEmpty })
        XCTAssertTrue(FileManager.default.fileExists(atPath: library.fileURL(for: photo.attachments[0], of: photo.id).path))

        // Fake vectors cluster: the billing incident relates to the event pipeline post.
        let incident = try XCTUnwrap(library.items.first { $0.title == "Billing API incident follow-up" })
        let related = library.related(toItem: incident.id, limit: 2).map(\.item.title)
        XCTAssertTrue(related.contains("Designing an event pipeline that doesn't lose data"))

        // With a real key the seed vectors are replaced.
        library.flush()
        XCTAssertEqual(MemoryLibrary(directory: dir).count, library.count)
    }
}
