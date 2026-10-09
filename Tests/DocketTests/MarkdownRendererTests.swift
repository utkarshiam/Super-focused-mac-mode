import AppKit
import XCTest
@testable import Docket

final class MarkdownRendererTests: XCTestCase {
    private func render(_ md: String) -> NSAttributedString { MarkdownRenderer.render(md) }

    private func font(of text: String, in s: NSAttributedString) -> NSFont? {
        let r = (s.string as NSString).range(of: text)
        guard r.location != NSNotFound else { return nil }
        return s.attribute(.font, at: r.location, effectiveRange: nil) as? NSFont
    }

    private func paragraphStyle(of text: String, in s: NSAttributedString) -> NSParagraphStyle? {
        let r = (s.string as NSString).range(of: text)
        guard r.location != NSNotFound else { return nil }
        return s.attribute(.paragraphStyle, at: r.location, effectiveRange: nil) as? NSParagraphStyle
    }

    private func taskLines(_ s: NSAttributedString) -> [Int] {
        var lines: [Int] = []
        s.enumerateAttribute(.docketTaskLine, in: NSRange(location: 0, length: s.length)) { value, _, _ in
            if let line = value as? Int { lines.append(line) }
        }
        return lines
    }

    /// Lays the text out (TextKit 1, as Read mode does): for each paragraph, how many lines it takes
    /// and where the text after its tab starts.
    private func layOut(_ s: NSAttributedString, width: CGFloat = 500) -> [(lines: Int, textX: CGFloat)] {
        let storage = NSTextStorage(attributedString: s)
        let layout = NSLayoutManager()
        storage.addLayoutManager(layout)
        let container = NSTextContainer(size: NSSize(width: width, height: .greatestFiniteMagnitude))
        layout.addTextContainer(container)
        layout.ensureLayout(for: container)
        let ns = storage.string as NSString
        var result: [(lines: Int, textX: CGFloat)] = []
        ns.enumerateSubstrings(in: NSRange(location: 0, length: ns.length), options: [.byParagraphs, .substringNotRequired]) { _, range, _, _ in
            let glyphs = layout.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
            var lines = 0
            var g = glyphs.location
            while g < NSMaxRange(glyphs) {
                var line = NSRange()
                _ = layout.lineFragmentRect(forGlyphAt: g, effectiveRange: &line)
                lines += 1
                g = NSMaxRange(line)
            }
            let tab = ns.range(of: "\t", range: range)
            let glyph = layout.glyphIndexForCharacter(at: tab.location == NSNotFound ? range.location : NSMaxRange(tab))
            let x = layout.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil).minX + layout.location(forGlyphAt: glyph).x
            result.append((lines, x))
        }
        return result
    }

    func testHeadingsLoseTheirHashesAndGetBigger() {
        let s = render("# Big\n## Medium\nBody text")
        XCTAssertFalse(s.string.contains("#"))
        XCTAssertEqual(font(of: "Big", in: s)?.pointSize, 28)
        XCTAssertEqual(font(of: "Medium", in: s)?.pointSize, 22)
        XCTAssertEqual(font(of: "Body", in: s)?.pointSize, MarkdownRenderer.bodySize)
    }

    func testInlineEmphasisCodeAndLinks() {
        let s = render("Some **bold**, *italic*, `code` and [a link](https://example.com).")
        XCTAssertEqual(s.string, "Some bold, italic, code and a link.")
        XCTAssertTrue(font(of: "bold", in: s)!.fontDescriptor.symbolicTraits.contains(.bold))
        XCTAssertTrue(font(of: "italic", in: s)!.fontDescriptor.symbolicTraits.contains(.italic))
        XCTAssertTrue(font(of: "code", in: s)!.isFixedPitch)
        let link = s.attribute(.link, at: (s.string as NSString).range(of: "a link").location, effectiveRange: nil) as? URL
        XCTAssertEqual(link?.absoluteString, "https://example.com")
    }

    func testBareURLsBecomeLinks() {
        let s = render("See https://docket.app for more")
        let r = (s.string as NSString).range(of: "https://docket.app")
        XCTAssertNotNil(s.attribute(.link, at: r.location, effectiveRange: nil))
    }

    func testListsGetBulletsAndRenumberedNumbers() {
        let s = render("- one\n- two\n  - nested\n\n1. first\n1. second\n1. third")
        XCTAssertTrue(s.string.contains("•\tone"))
        XCTAssertTrue(s.string.contains("◦\tnested"))
        XCTAssertTrue(s.string.contains("1.\tfirst"))
        XCTAssertTrue(s.string.contains("2.\tsecond"))
        XCTAssertTrue(s.string.contains("3.\tthird"))
    }

    func testTaskCheckboxesRememberTheirSourceLine() {
        let md = "# Plan\n\n- [ ] open item\n- [x] done item\n> - [ ] quoted item"
        let s = render(md)
        var lines: [Int] = []
        s.enumerateAttribute(.docketTaskLine, in: NSRange(location: 0, length: s.length)) { value, _, _ in
            if let line = value as? Int { lines.append(line) }
        }
        XCTAssertEqual(lines, [2, 3, 4])
        // Toggling by those line numbers flips exactly that line, quotes included.
        let toggled = NoteChecklist.toggle(lineAt: 4, in: NoteChecklist.toggle(lineAt: 2, in: md)!)!
        XCTAssertEqual(toggled, "# Plan\n\n- [x] open item\n- [x] done item\n> - [x] quoted item")
    }

    func testCodeBlocksAreMonospacedAndKeepTheirText() {
        let s = render("```swift\nlet x = 1\nprint(x)\n```")
        XCTAssertTrue(s.string.contains("let x = 1"))
        XCTAssertFalse(s.string.contains("```"))
        XCTAssertTrue(font(of: "print", in: s)!.isFixedPitch)
        let style = s.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle
        XCTAssertFalse(style?.textBlocks.isEmpty ?? true, "code sits in a shaded block")
    }

    func testTablesBecomeRealTables() {
        let s = render("| Name | Amount |\n|:-----|-------:|\n| Rent | 1200 |\n| Food | 300 |")
        var cells = 0
        var tables = Set<ObjectIdentifier>()
        s.enumerateAttribute(.paragraphStyle, in: NSRange(location: 0, length: s.length)) { value, _, _ in
            guard let p = value as? NSParagraphStyle, let block = p.textBlocks.first as? NSTextTableBlock else { return }
            cells += 1
            tables.insert(ObjectIdentifier(block.table))
        }
        XCTAssertEqual(cells, 6)
        XCTAssertEqual(tables.count, 1)
        XCTAssertFalse(s.string.contains("|"))
        XCTAssertTrue(font(of: "Name", in: s)!.fontDescriptor.symbolicTraits.contains(.bold), "header row is bold")
    }

    func testRulesAndQuotes() {
        let s = render("Before\n\n---\n\n> A quote\n\nAfter")
        XCTAssertFalse(s.string.contains("---"))
        XCTAssertFalse(s.string.contains(">"))
        XCTAssertTrue(s.string.contains("A quote"))
    }

    func testSetextHeading() {
        let s = render("Title\n=====\nText")
        XCTAssertEqual(font(of: "Title", in: s)?.pointSize, 28)
        XCTAssertFalse(s.string.contains("="))
    }

    func testEmphasisAtALineBreakStillRenders() {
        let s = render("**Summary:**\nThis tool does X.")
        XCTAssertEqual(s.string, "Summary:\u{2028}This tool does X.")
        XCTAssertTrue(font(of: "Summary:", in: s)!.fontDescriptor.symbolicTraits.contains(.bold))
        let italic = render("_Note_\nnext")
        XCTAssertEqual(italic.string, "Note\u{2028}next")
        XCTAssertTrue(font(of: "Note", in: italic)!.fontDescriptor.symbolicTraits.contains(.italic))
        let item = render("- **Step 1:**\n  Install it")
        XCTAssertEqual(item.string, "•\tStep 1:\u{2028}Install it")
        XCTAssertTrue(font(of: "Step 1:", in: item)!.fontDescriptor.symbolicTraits.contains(.bold))
        XCTAssertEqual(render("line one\\\nline two").string, "line one\u{2028}line two", "a backslash break leaves no backslash")
    }

    func testFenceClosesOnlyOnAFenceAsLongAsItsOpener() {
        let s = render("````markdown\n# Title\n```python\nprint(1)\n```\n````\nAfter")
        XCTAssertEqual(s.string, "# Title\u{2028}```python\u{2028}print(1)\u{2028}```\nAfter")
        XCTAssertFalse(font(of: "After", in: s)!.isFixedPitch)
        let t = render("```\nexample:\n```python\nx\n```\nAfter")
        XCTAssertEqual(t.string, "example:\u{2028}```python\u{2028}x\nAfter")
        XCTAssertFalse(font(of: "After", in: t)!.isFixedPitch)
    }

    func testFencesWithInfoStringsAndIndents() {
        let s = render("```js title=\"app.js\"\nconst a = 1\n```\n\n- [ ] task after")
        XCTAssertEqual(s.string, "const a = 1\n\u{FFFC}\ttask after")
        XCTAssertTrue(font(of: "const", in: s)!.isFixedPitch)
        XCTAssertEqual(taskLines(s), [4])
        // Code under a list item loses the indent it was typed with.
        XCTAssertEqual(render("1. **Install**\n\n   ```bash\n   npm install\n   ```").string, "1.\tInstall\nnpm install")
        XCTAssertEqual(render("- a\n   - b\n     ```js\n     const x = 1\n     ```\n- c").string, "•\ta\n◦\tb\nconst x = 1\n•\tc")
        XCTAssertEqual(render("```js``` is inline").string, "js is inline")
    }

    func testNumberedTasksToggleAndKeepTheCount() {
        let s = render("1. a\n2. [ ] b\n3. c")
        XCTAssertEqual(s.string, "1.\ta\n\u{FFFC}\tb\n3.\tc")
        XCTAssertEqual(taskLines(s), [1])
        let md = "1. [ ] first\n2) [x] second\n> 3. [ ] quoted\n  10. [X] nested"
        XCTAssertEqual(taskLines(render(md)), [0, 1, 2, 3])
        var body = md
        for line in 0..<4 { body = NoteChecklist.toggle(lineAt: line, in: body) ?? body }
        XCTAssertEqual(body, "1. [x] first\n2) [ ] second\n> 3. [x] quoted\n  10. [ ] nested")
        XCTAssertEqual(NoteChecklist.uncheckedText("1. [ ] Book the room"), "Book the room")
        XCTAssertEqual(Note(body: "# Plan\n1. [ ] a\n2. [x] b\n- [ ] c").openChecklistCount, 2)
    }

    func testTasksInSpacedNestedQuotesToggle() throws {
        // Read mode allows spaces before each ">", so ">  > - [ ]" is a nested quote's checkbox too.
        let md = ">  > - [ ] spaced\n> >   1. [x] numbered"
        XCTAssertEqual(taskLines(render(md)), [0, 1])
        let once = try XCTUnwrap(NoteChecklist.toggle(lineAt: 0, in: md))
        XCTAssertEqual(NoteChecklist.toggle(lineAt: 1, in: once), ">  > - [x] spaced\n> >   1. [ ] numbered")
    }

    func testNumbersFromTenKeepTheirTextOnTheSameLine() {
        let items = layOut(render((1...12).map { "\($0). Step \($0)" }.joined(separator: "\n")))
        XCTAssertEqual(items.count, 12)
        XCTAssertEqual(items.filter { $0.lines != 1 }.count, 0, "no number sits on a line of its own")
        XCTAssertEqual(Set(items.map(\.textX)).count, 1, "the whole run shares one text column")
    }

    func testHeadingsKeepHashesThatArePartOfTheText() {
        let s = render("## Learning C#\n### F#\n# Title #\n# Issue #5\n#######")
        XCTAssertEqual(s.string, "Learning C#\nF#\nTitle\nIssue #5\n#######")
        XCTAssertEqual(font(of: "Learning C#", in: s)?.pointSize, 22)
        XCTAssertEqual(font(of: "#######", in: s)?.pointSize, MarkdownRenderer.bodySize, "seven #s are a paragraph")
    }

    func testLongRunsOfSpacesRenderQuickly() {
        // The fence and closing-# patterns used to backtrack for seconds on lines like these.
        let spaces = String(repeating: " ", count: 20_000)
        let start = Date()
        XCTAssertEqual(render("```" + spaces + "`").string, "```" + spaces + "`")
        XCTAssertEqual(render("# a" + spaces + "b").string, "a" + spaces + "b")
        XCTAssertLessThan(Date().timeIntervalSince(start), 2)
    }

    func testCellLineBreaksAndHiddenHTML() {
        let table = render("| a | b |\n|---|---|\n| x<br>y | z<BR/>w |")
        XCTAssertTrue(table.string.contains("x\u{2028}y"))
        XCTAssertTrue(table.string.contains("z\u{2028}w"))
        XCTAssertEqual(render("Press <kbd>⌘</kbd> to search").string, "Press ⌘ to search")
        XCTAssertEqual(render("git checkout <branch>").string, "git checkout <branch>", "a placeholder isn't hidden")
        // A commented-out task is no checkbox, and the real one keeps its source line.
        let s = render("<!--\n- [ ] commented\n-->\n- [ ] real")
        XCTAssertEqual(s.string, "\u{FFFC}\treal")
        XCTAssertEqual(taskLines(s), [3])
        XCTAssertEqual(render("## Notes\n<!-- Describe your changes -->\nText").string, "Notes\nText")
    }

    func testBlocksIndentedUnderAnItemStayInTheList() {
        let md = "1. **Install**\n\n   Run the installer.\n\n1. **Configure**\n\n   ```\n   edit config\n   ```\n\n1. **Run**\n\n- [ ] after"
        let s = render(md)
        XCTAssertEqual(s.string, "1.\tInstall\nRun the installer.\n2.\tConfigure\nedit config\n3.\tRun\n\u{FFFC}\tafter")
        // The paragraph sits at the item's text, not at the margin.
        let item = paragraphStyle(of: "Install", in: s)
        let para = paragraphStyle(of: "Run the installer.", in: s)
        XCTAssertEqual(para?.textBlocks.last?.width(for: .margin, edge: .minX), item?.headIndent)
        XCTAssertTrue(font(of: "edit config", in: s)!.isFixedPitch)
        XCTAssertEqual(taskLines(s), [12])
        // A list after an item's paragraph is still nested under it.
        XCTAssertEqual(render("1. Step\n\n   Details.\n\n   - sub\n2. Next").string, "1.\tStep\nDetails.\n◦\tsub\n2.\tNext")
        // Code pasted into an item's fence stays in it even where its lines aren't indented.
        XCTAssertEqual(render("1. Run this:\n   ```\nSELECT 1;\n   ```\n2. Then this").string, "1.\tRun this:\nSELECT 1;\n2.\tThen this")
    }

    func testTablesInsideQuotesStayInTheQuote() {
        let s = render("> | a | b |\n> |---|---|\n> | 1 | 2 |")
        let blocks = paragraphStyle(of: "a", in: s)?.textBlocks ?? []
        XCTAssertEqual(blocks.count, 2)
        XCTAssertFalse(blocks.first is NSTextTableBlock, "the quote's block comes first")
        XCTAssertTrue(blocks.last is NSTextTableBlock)
    }

    func testPhotosRenderInlineAndMissingOnesBecomeLinks() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("docket-media-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let previous = MediaLibrary.dataDirectory
        MediaLibrary.dataDirectory = dir
        defer { MediaLibrary.dataDirectory = previous }

        // A real 20x10 PNG imported the way the app does it.
        let image = NSImage(size: NSSize(width: 20, height: 10), flipped: false) { r in
            NSColor.red.setFill()
            r.fill()
            return true
        }
        let line = try XCTUnwrap(MediaLibrary.importImage(image, alt: "Chart"))
        XCTAssertTrue(line.hasPrefix("![Chart](attachments/"))

        let s = render("Intro\n\n\(line)\n\n![Gone](attachments/missing.png)")
        var media: [URL] = []
        s.enumerateAttribute(.docketMediaURL, in: NSRange(location: 0, length: s.length)) { value, _, _ in
            if let url = value as? URL { media.append(url) }
        }
        XCTAssertEqual(media.count, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: media[0].path))
        XCTAssertTrue(s.string.contains("Image: Gone"), "a missing file shows as a link, not a broken box")
        XCTAssertEqual(Note(body: line).title, "Photo: Chart")
    }

    @MainActor
    func testFormattedCopyCarriesPhotos() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("docket-copy-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let previous = MediaLibrary.dataDirectory
        MediaLibrary.dataDirectory = dir
        defer { MediaLibrary.dataDirectory = previous }
        let image = NSImage(size: NSSize(width: 20, height: 10), flipped: false) { r in
            NSColor.red.setFill()
            r.fill()
            return true
        }
        let line = try XCTUnwrap(MediaLibrary.importImage(image, alt: "Chart"))

        let flavors = Dictionary(MarkdownExport.formattedData("Intro\n\n\(line)"), uniquingKeysWith: { first, _ in first })
        // RTF can't hold the photo; RTFD and the web archive can.
        let rtfd = try XCTUnwrap(flavors[.rtfd])
        let back = try XCTUnwrap(NSAttributedString(rtfd: rtfd, documentAttributes: nil))
        var attachments = 0
        back.enumerateAttribute(.attachment, in: NSRange(location: 0, length: back.length)) { value, _, _ in
            if value != nil { attachments += 1 }
        }
        XCTAssertEqual(attachments, 1)
        XCTAssertLessThan(rtfd.count, 50_000, "no file icon rides along with the photo")
        XCTAssertNotNil(flavors[NSPasteboard.PasteboardType("com.apple.webarchive")])
        // Browsers get the photo itself, not a file:// path they can't open.
        let html = String(decoding: try XCTUnwrap(flavors[.html]), as: UTF8.self)
        XCTAssertTrue(html.contains("src=\"data:image/png;base64,"))
        XCTAssertFalse(html.contains("file:"))
    }

    func testMediaKinds() {
        XCTAssertEqual(MediaLibrary.kind(ofExtension: "MOV"), .video)
        XCTAssertEqual(MediaLibrary.kind(ofExtension: "mp4"), .video)
        XCTAssertEqual(MediaLibrary.kind(ofExtension: "heic"), .image)
        XCTAssertEqual(MediaLibrary.kind(ofExtension: "png"), .image)
        XCTAssertEqual(MediaLibrary.kind(ofExtension: "pdf"), .pdf)
        XCTAssertNil(MediaLibrary.kind(ofExtension: "mp3"))
    }

    func testPDFsRenderAsCards() throws {
        try withMediaSandbox { dir in
            let original = dir.appendingPathComponent("Q3 Deck.pdf")
            try MediaFixtures.writePDF(pages: 2, to: original)
            let line = try XCTUnwrap(MediaLibrary.importFiles([original]).first)

            var cells = render("Intro\n\n\(line)\n\nAfter").mediaCells
            XCTAssertEqual(cells.count, 1)
            var card = try XCTUnwrap(cells.first?.cell as? MediaCardCell)
            XCTAssertEqual(card.cardTitle, "Q3 Deck")
            XCTAssertEqual(card.cardSubtitle, "PDF", "pages are counted in the background")
            let opens = try XCTUnwrap(cells.first?.opens)
            XCTAssertTrue(opens.isFileURL, "a click opens the copy in Quick Look")
            XCTAssertEqual(opens.deletingLastPathComponent().lastPathComponent, "attachments")

            waitForMedia { MediaCache.shared.pdf(for: opens) != nil }
            cells = render("Intro\n\n\(line)\n\nAfter").mediaCells
            card = try XCTUnwrap(cells.first?.cell as? MediaCardCell)
            XCTAssertEqual(card.cardSubtitle, "PDF · 2 pages")
            XCTAssertNotNil(card.thumbnail)

            // An export doesn't wait: the card is complete at once.
            let exported = try XCTUnwrap(MarkdownRenderer.render(line, forExport: true).mediaCells.first?.cell as? MediaCardCell)
            XCTAssertEqual(exported.cardSubtitle, "PDF · 2 pages")
        }
    }

    @MainActor
    func testFormattedCopyNamesPDFsRatherThanDroppingThem() throws {
        try withMediaSandbox { dir in
            let original = dir.appendingPathComponent("Q3 Deck.pdf")
            try MediaFixtures.writePDF(pages: 2, to: original)
            let line = try XCTUnwrap(MediaLibrary.importFiles([original]).first)
            let flavors = Dictionary(MarkdownExport.formattedData("Intro\n\n\(line)\n\nEnd"), uniquingKeysWith: { first, _ in first })
            let rtf = try XCTUnwrap(NSAttributedString(rtf: try XCTUnwrap(flavors[.rtf]), documentAttributes: nil))
            XCTAssertTrue(rtf.string.contains("PDF: Q3 Deck"), rtf.string)
            XCTAssertTrue(String(decoding: try XCTUnwrap(flavors[.html]), as: UTF8.self).contains("PDF: Q3 Deck"))
        }
    }

    func testBareMediaLinksOnTheirOwnLine() {
        func detects(_ line: String) -> Bool { MarkdownRenderer.bareMediaURL(line) != nil }
        XCTAssertTrue(detects("https://example.com/shots/chart.png"))
        XCTAssertTrue(detects("  <https://example.com/clip.mp4>  "))
        XCTAssertTrue(detects("https://example.com/report.pdf?dl=1"))
        XCTAssertTrue(detects("http://example.com/a.JPEG"))
        XCTAssertFalse(detects("https://example.com/about"))
        XCTAssertFalse(detects("See https://example.com/chart.png for details"))
        XCTAssertFalse(detects("[chart](https://example.com/chart.png)"))
        XCTAssertFalse(detects("- https://example.com/chart.png"))
        XCTAssertFalse(detects("/Users/me/chart.png"))
        XCTAssertFalse(detects("https://"))
    }

    func testMediaOnTheWebLoadsThenShows() throws {
        let web = MediaFixtures.FakeWeb(data: try MediaFixtures.png(width: 60, height: 30), mimeType: "image/png")
        try withMediaSandbox(web: web) { _ in
            let titled = URL(string: "https://example.com/chart.png")!
            let bare = URL(string: "https://example.com/photo.jpg")!
            let note = "Numbers\n![Chart](\(titled.absoluteString))\nSee the team:\n\(bare.absoluteString)\nThat's all."

            // While loading: a placeholder card each, and the text around them keeps its own paragraphs.
            var s = render(note)
            var cells = s.mediaCells
            XCTAssertEqual(cells.count, 2)
            XCTAssertEqual((cells[0].cell as? MediaCardCell)?.cardTitle, "Chart")
            XCTAssertEqual((cells[1].cell as? MediaCardCell)?.cardTitle, "photo")
            XCTAssertEqual(cells.map(\.opens), [titled, bare], "a click while loading opens the link")
            XCTAssertTrue(s.string.contains("See the team:\n"))
            XCTAssertFalse(s.string.contains("https://"), "the bare link is shown as media, not text")

            waitForMedia { !render(note).mediaCells.contains { $0.cell is MediaCardCell } }
            s = render(note)
            cells = s.mediaCells
            XCTAssertEqual(cells.count, 2)
            for (cell, opens) in cells {
                let picture = try XCTUnwrap(cell as? MediaAttachmentCell)
                XCTAssertEqual(picture.picture?.size.width, 60)
                XCTAssertEqual(opens?.deletingLastPathComponent().lastPathComponent, "MediaCache", "Quick Look opens the cached copy")
            }
            XCTAssertEqual(Set(web.requests), [titled, bare])

            // Links in a sentence and in a list stay links, and nothing is fetched for them.
            let before = web.requests.count
            let inline = render("See https://example.com/other.png for details\n\n- https://example.com/third.png")
            XCTAssertTrue(inline.mediaCells.isEmpty)
            XCTAssertEqual(web.requests.count, before)

            // Exports keep media on the web as links, without fetching.
            let exported = MarkdownRenderer.render("![Fresh](https://example.com/fresh.png)\n\nhttps://example.com/fresh2.png", forExport: true)
            XCTAssertTrue(exported.mediaCells.isEmpty)
            XCTAssertTrue(exported.string.contains("Image: Fresh"))
            XCTAssertTrue(exported.string.contains("https://example.com/fresh2.png"))
            XCTAssertEqual(web.requests.count, before)
        }
    }

    func testMediaThatFailsToLoadFallsBackToLinks() throws {
        try withMediaSandbox(web: .init(data: nil), posters: nil) { _ in
            let note = "![Chart](https://example.com/chart.png)\n\nhttps://example.com/deck.pdf\n\n![Demo](https://example.com/demo.mp4)"
            XCTAssertEqual(render(note).mediaCells.count, 3, "placeholders while loading")
            waitForMedia { render(note).mediaCells.isEmpty }
            let s = render(note)
            func link(of text: String) -> URL? {
                let r = (s.string as NSString).range(of: text)
                guard r.location != NSNotFound else { return nil }
                return s.attribute(.link, at: r.location, effectiveRange: nil) as? URL
            }
            XCTAssertTrue(s.string.contains("Image: Chart"))
            XCTAssertEqual(link(of: "Chart"), URL(string: "https://example.com/chart.png"))
            XCTAssertEqual(link(of: "https://example.com/deck.pdf"), URL(string: "https://example.com/deck.pdf"))
            XCTAssertTrue(s.string.contains("Video: Demo"))
            XCTAssertEqual(link(of: "Demo"), URL(string: "https://example.com/demo.mp4"))
        }
    }

    func testVideosOnTheWebShowTheirPosterAndOpenTheLink() throws {
        let poster = NSImage(size: NSSize(width: 320, height: 180), flipped: false) { r in
            NSColor.darkGray.setFill()
            r.fill()
            return true
        }
        try withMediaSandbox(posters: poster) { _ in
            let url = URL(string: "https://example.com/demo.mov")!
            XCTAssertTrue(render(url.absoluteString).mediaCells.first?.cell is MediaCardCell)
            waitForMedia { render(url.absoluteString).mediaCells.first?.cell is MediaAttachmentCell }
            let cells = render(url.absoluteString).mediaCells
            let cell = try XCTUnwrap(cells.first?.cell as? MediaAttachmentCell)
            XCTAssertTrue(cell.isVideo)
            XCTAssertEqual(cell.picture?.size.width, 320)
            XCTAssertEqual(cells.first?.opens, url, "a click plays it in the browser")
        }
    }

    func testVideoLinksBecomeCardsWithTheirTitle() throws {
        func endpoint(_ s: String) -> String? { RemoteMedia.embedEndpoint(for: URL(string: s)!)?.provider }
        XCTAssertEqual(endpoint("https://www.youtube.com/watch?v=dQw4w9WgXcQ"), "YouTube")
        XCTAssertEqual(endpoint("https://youtu.be/dQw4w9WgXcQ"), "YouTube")
        XCTAssertEqual(endpoint("https://m.youtube.com/shorts/abc123"), "YouTube")
        XCTAssertEqual(endpoint("https://vimeo.com/76979871"), "Vimeo")
        XCTAssertEqual(endpoint("https://www.loom.com/share/0123abcd"), "Loom")
        XCTAssertNil(endpoint("https://www.youtube.com/"))
        XCTAssertNil(endpoint("https://www.youtube.com/@channel"))
        XCTAssertNil(endpoint("https://vimeo.com/about"))
        XCTAssertNil(endpoint("https://example.com/watch?v=1"))
        XCTAssertNil(MarkdownRenderer.bareVideoLink("Watch https://youtu.be/dQw4w9WgXcQ later"))

        let web = MediaFixtures.FakeWeb(data: nil)
        web.hosts["www.youtube.com"] = (Data(#"{"title":"Launch keynote","provider_name":"YouTube","thumbnail_url":"https://i.ytimg.com/vi/x/hqdefault.jpg"}"#.utf8), "application/json")
        web.hosts["i.ytimg.com"] = (try MediaFixtures.png(width: 64, height: 36), "image/jpeg")
        try withMediaSandbox(web: web) { _ in
            let link = "https://youtu.be/dQw4w9WgXcQ"
            XCTAssertEqual((render(link).mediaCells.first?.cell as? MediaCardCell)?.cardSubtitle, "Loading…")
            waitForMedia { (render(link).mediaCells.first?.cell as? MediaCardCell)?.thumbnail != nil }
            let cells = render(link).mediaCells
            let card = try XCTUnwrap(cells.first?.cell as? MediaCardCell)
            XCTAssertEqual(card.cardTitle, "Launch keynote")
            XCTAssertEqual(card.cardSubtitle, "YouTube · Video")
            XCTAssertEqual(cells.first?.opens, URL(string: link))
            XCTAssertTrue(web.requests.contains { $0.absoluteString.hasPrefix("https://www.youtube.com/oembed?") })

            // A site that can't describe the video leaves the link as it was.
            let other = "https://vimeo.com/76979871"
            waitForMedia { render(other).mediaCells.isEmpty }
            let s = render(other)
            XCTAssertNotNil(s.attribute(.link, at: 0, effectiveRange: nil))
            XCTAssertEqual(s.string, other)
        }
    }

    func testPicturesThatCantBeDecodedBecomeLinks() throws {
        try withMediaSandbox { _ in
            let broken = MediaLibrary.folder.appendingPathComponent("BROKEN-1.png")
            try Data("not a picture".utf8).write(to: broken)
            let s = render("![Scan](attachments/BROKEN-1.png)")
            XCTAssertTrue(s.mediaCells.isEmpty, "no empty box")
            XCTAssertTrue(s.string.contains("Attachment: Scan"))
        }
    }

    func testGarbageCollectionKeepsReferencedAndRecentFiles() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("docket-gc-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let previous = MediaLibrary.dataDirectory
        MediaLibrary.dataDirectory = dir
        defer { MediaLibrary.dataDirectory = previous }
        let fm = FileManager.default
        try fm.createDirectory(at: MediaLibrary.folder, withIntermediateDirectories: true)
        let old = Date().addingTimeInterval(-30 * 86_400)
        for name in ["KEEP-1.png", "OLD-2.png", "NEW-3.png"] {
            let url = MediaLibrary.folder.appendingPathComponent(name)
            try Data([1, 2, 3]).write(to: url)
            if name != "NEW-3.png" { try fm.setAttributes([.modificationDate: old], ofItemAtPath: url.path) }
        }
        MediaLibrary.collectGarbage(noteBodies: ["![x](attachments/KEEP-1.png)"])
        let left = Set(try fm.contentsOfDirectory(atPath: MediaLibrary.folder.path))
        XCTAssertEqual(left, ["KEEP-1.png", "NEW-3.png"])
    }
}
