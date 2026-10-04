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

    func testMediaKinds() {
        XCTAssertEqual(MediaLibrary.kind(ofExtension: "MOV"), .video)
        XCTAssertEqual(MediaLibrary.kind(ofExtension: "mp4"), .video)
        XCTAssertEqual(MediaLibrary.kind(ofExtension: "heic"), .image)
        XCTAssertEqual(MediaLibrary.kind(ofExtension: "png"), .image)
        XCTAssertNil(MediaLibrary.kind(ofExtension: "pdf"))
        XCTAssertNil(MediaLibrary.kind(ofExtension: "mp3"))
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
