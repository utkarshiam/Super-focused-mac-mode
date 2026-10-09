import AppKit
import UniformTypeIdentifiers
import XCTest
@testable import Docket

final class MediaLibraryTests: XCTestCase {
    /// Runs `body` with the library pointed at a fresh data folder, restored afterwards.
    private func withTemporaryLibrary(_ body: (URL) throws -> Void) throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("docket-media-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let previous = MediaLibrary.dataDirectory
        MediaLibrary.dataDirectory = dir
        defer { MediaLibrary.dataDirectory = previous }
        try FileManager.default.createDirectory(at: MediaLibrary.folder, withIntermediateDirectories: true)
        try body(dir)
    }

    private func addFile(_ name: String, daysOld: Double, data: Data = Data([1, 2, 3])) throws {
        let url = MediaLibrary.folder.appendingPathComponent(name)
        try data.write(to: url)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-daysOld * 86_400)], ofItemAtPath: url.path)
    }

    private func libraryFiles() throws -> Set<String> {
        Set(try FileManager.default.contentsOfDirectory(atPath: MediaLibrary.folder.path))
    }

    /// A small red picture to encode in different formats.
    private func bitmap() throws -> NSBitmapImageRep {
        let image = NSImage(size: NSSize(width: 20, height: 10), flipped: false) { r in
            NSColor.red.setFill()
            r.fill()
            return true
        }
        return try XCTUnwrap(image.tiffRepresentation.flatMap(NSBitmapImageRep.init(data:)))
    }

    /// The picture as a two-frame GIF, like a copied animation.
    private func animatedGIF(_ rep: NSBitmapImageRep) throws -> Data {
        let data = NSMutableData()
        let frame = try XCTUnwrap(rep.cgImage)
        let gif = try XCTUnwrap(CGImageDestinationCreateWithData(data, UTType.gif.identifier as CFString, 2, nil))
        CGImageDestinationAddImage(gif, frame, nil)
        CGImageDestinationAddImage(gif, frame, nil)
        XCTAssertTrue(CGImageDestinationFinalize(gif))
        return data as Data
    }

    func testGarbageCollectionKeepsFilesTheBackupsStillMention() throws {
        try withTemporaryLibrary { dir in
            for name in ["IN-BACKUP-1.png", "IN-ASIDE-2.png", "UNUSED-3.png"] { try addFile(name, daysOld: 30) }

            // A backup written the way Persistence writes one.
            var db = Database()
            db.notes = [Note(body: "Offsite\n\n![Whiteboard](attachments/IN-BACKUP-1.png)")]
            let json = try Persistence.encoder.encode(db)
            XCTAssertTrue(String(decoding: json, as: UTF8.self).contains(#"attachments\/IN-BACKUP-1.png"#), "JSON escapes the slash")
            let backups = Persistence(directory: dir).backupsURL
            try FileManager.default.createDirectory(at: backups, withIntermediateDirectories: true)
            try json.write(to: backups.appendingPathComponent("docket-2026-09-01.json"))
            // A data file too damaged to load, set aside at launch.
            try Data(#"{"notes":[{"body":"![x](attachments\/IN-ASIDE-2.png)"#.utf8)
                .write(to: dir.appendingPathComponent("docket.unreadable-1790000000.json"))

            MediaLibrary.collectGarbage(noteBodies: [])
            XCTAssertEqual(try libraryFiles(), ["IN-BACKUP-1.png", "IN-ASIDE-2.png"])
        }
    }

    func testImportedFileGetsAWeekOfGraceEvenWhenTheOriginalIsOld() throws {
        try withTemporaryLibrary { dir in
            let original = dir.appendingPathComponent("IMG_0001.png")
            try XCTUnwrap(bitmap().representation(using: .png, properties: [:])).write(to: original)
            try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-200 * 86_400)], ofItemAtPath: original.path)

            let lines = MediaLibrary.importFiles([original])
            let name = try XCTUnwrap(MediaLibrary.referencedNames(in: lines).first)
            let copy = MediaLibrary.folder.appendingPathComponent(name)
            let modified = try XCTUnwrap(copy.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
            XCTAssertLessThan(abs(modified.timeIntervalSinceNow), 60)

            // No note mentions it yet (as while the launch clean-up races an import), so only its date protects it.
            MediaLibrary.collectGarbage(noteBodies: [])
            XCTAssertEqual(try libraryFiles(), [name])
        }
    }

    func testOnlyVideosAVFoundationCanOpenCountAsVideo() {
        for ext in ["mov", "MOV", "mp4", "m4v"] { XCTAssertEqual(MediaLibrary.kind(ofExtension: ext), .video, ext) }
        // TypeScript source, and containers AVFoundation can't play.
        for ext in ["ts", "mkv", "webm"] { XCTAssertNil(MediaLibrary.kind(ofExtension: ext), ext) }
        XCTAssertNil(MediaLibrary.kind(of: URL(fileURLWithPath: "/Users/me/site/index.ts")))
    }

    func testPastedImageDataKeepsItsOriginalBytes() throws {
        try withTemporaryLibrary { _ in
            let pb = NSPasteboard(name: NSPasteboard.Name("docket-test-\(UUID().uuidString)"))
            defer { pb.releaseGlobally() }
            let rep = try bitmap()
            func pastedFile() throws -> (ext: String, data: Data) {
                let line = try XCTUnwrap(MediaLibrary.importFromPasteboard(pb)?.first)
                let name = try XCTUnwrap(MediaLibrary.referencedNames(in: [line]).first)
                return ((name as NSString).pathExtension, try Data(contentsOf: MediaLibrary.folder.appendingPathComponent(name)))
            }

            let jpeg = try XCTUnwrap(rep.representation(using: .jpeg, properties: [:]))
            pb.clearContents()
            guard pb.setData(jpeg, forType: NSPasteboard.PasteboardType(UTType.jpeg.identifier)) else {
                throw XCTSkip("No pasteboard server in this session")
            }
            var pasted = try pastedFile()
            XCTAssertEqual(pasted.ext, "jpeg")
            XCTAssertEqual(pasted.data, jpeg)

            // An animated GIF wins over a PNG of its first frame, so it keeps moving.
            let gif = try animatedGIF(rep)
            let gifType = NSPasteboard.PasteboardType(UTType.gif.identifier)
            let png = try XCTUnwrap(rep.representation(using: .png, properties: [:]))
            pb.declareTypes([.png, gifType], owner: nil)
            pb.setData(png, forType: .png)
            pb.setData(gif, forType: gifType)
            pasted = try pastedFile()
            XCTAssertEqual(pasted.ext, "gif")
            XCTAssertEqual(pasted.data, gif)

            // A still GIF only has 256 colours: the PNG beside it is kept instead, and a GIF on its own stays one.
            let stillGIF = try XCTUnwrap(rep.representation(using: .gif, properties: [:]))
            pb.declareTypes([.png, gifType], owner: nil)
            pb.setData(png, forType: .png)
            pb.setData(stillGIF, forType: gifType)
            pasted = try pastedFile()
            XCTAssertEqual(pasted.ext, "png")
            XCTAssertEqual(pasted.data, png)
            pb.clearContents()
            pb.setData(stillGIF, forType: gifType)
            pasted = try pastedFile()
            XCTAssertEqual(pasted.ext, "gif")
            XCTAssertEqual(pasted.data, stillGIF)

            // Only TIFF: converted to PNG as before.
            pb.clearContents()
            pb.setData(try XCTUnwrap(rep.tiffRepresentation), forType: .tiff)
            XCTAssertEqual(try pastedFile().ext, "png")

            // Text on the pasteboard makes it a text paste.
            pb.clearContents()
            pb.setData(jpeg, forType: NSPasteboard.PasteboardType(UTType.jpeg.identifier))
            pb.setString("caption", forType: .string)
            XCTAssertNil(MediaLibrary.importFromPasteboard(pb))
        }
    }

    func testBackupAttachmentsComeBackOnImport() throws {
        try withTemporaryLibrary { dir in
            let photo = Data("photo".utf8)
            try addFile("PHOTO-1.png", daysOld: 0, data: photo)
            try addFile("KEPT-3.png", daysOld: 0, data: Data("library copy".utf8))
            let bodies = ["![Whiteboard](attachments/PHOTO-1.png)", "![Kept](attachments/KEPT-3.png)"]
            let backup = dir.appendingPathComponent("Backup folder", isDirectory: true)
            MediaLibrary.copyReferencedMedia(for: bodies, to: backup)
            XCTAssertEqual(Set(try FileManager.default.contentsOfDirectory(atPath: backup.appendingPathComponent("attachments").path)),
                           ["PHOTO-1.png", "KEPT-3.png"])

            // On another Mac only one of them is in the library; files already there are left alone.
            try FileManager.default.removeItem(at: MediaLibrary.folder.appendingPathComponent("PHOTO-1.png"))
            try Data("other".utf8).write(to: backup.appendingPathComponent("attachments/KEPT-3.png"))
            MediaLibrary.restoreMissingMedia(for: bodies + ["![Gone](attachments/MISSING-2.png)"], from: backup)
            XCTAssertEqual(try libraryFiles(), ["PHOTO-1.png", "KEPT-3.png"])
            XCTAssertEqual(try Data(contentsOf: MediaLibrary.folder.appendingPathComponent("PHOTO-1.png")), photo)
            XCTAssertEqual(try Data(contentsOf: MediaLibrary.folder.appendingPathComponent("KEPT-3.png")), Data("library copy".utf8))
        }
    }

    // MARK: PDFs

    func testPDFsImportAndKnowTheirPages() throws {
        try withMediaSandbox { dir in
            XCTAssertEqual(MediaLibrary.kind(ofExtension: "pdf"), .pdf)
            XCTAssertEqual(MediaLibrary.kind(ofExtension: "PDF"), .pdf)
            let original = dir.appendingPathComponent("Board Deck.pdf")
            try MediaFixtures.writePDF(pages: 3, to: original)

            let lines = MediaLibrary.importFiles([original])
            XCTAssertEqual(lines.count, 1)
            let line = try XCTUnwrap(lines.first)
            XCTAssertTrue(line.hasPrefix("![Board Deck](attachments/"), line)
            XCTAssertTrue(line.hasSuffix(".pdf)"), line)
            let name = try XCTUnwrap(MediaLibrary.referencedNames(in: lines).first)
            let copy = MediaLibrary.folder.appendingPathComponent(name)
            XCTAssertEqual(MediaLibrary.kind(of: copy), .pdf)

            let summary = try XCTUnwrap(PDFSummary.make(for: copy))
            XCTAssertEqual(summary.pageCount, 3)
            XCTAssertEqual(summary.subtitle, "PDF · 3 pages")
            XCTAssertNotNil(summary.thumbnail)
            XCTAssertEqual(PDFSummary(pageCount: 1, thumbnail: nil).subtitle, "PDF · 1 page")
            XCTAssertNil(PDFSummary.make(for: dir.appendingPathComponent("nothing.pdf")))

            XCTAssertEqual(Note(body: line).title, "PDF: Board Deck")
            XCTAssertEqual(Note(body: "![Clip](https://example.com/clip.mp4?t=3)").title, "Video: Clip")
        }
    }

    func testPastedPDFFilesAreMedia() throws {
        try withMediaSandbox { dir in
            let pb = NSPasteboard(name: NSPasteboard.Name("docket-test-\(UUID().uuidString)"))
            defer { pb.releaseGlobally() }
            let pdf = dir.appendingPathComponent("Memo.pdf")
            try MediaFixtures.writePDF(pages: 1, to: pdf)
            pb.clearContents()
            guard pb.writeObjects([pdf as NSURL]) else { throw XCTSkip("No pasteboard server in this session") }
            // Finder also puts the file's name on the pasteboard as text: it's still a file paste.
            pb.setString("Memo.pdf", forType: .string)
            XCTAssertEqual(MediaLibrary.mediaFileURLs(on: pb), [pdf])
            XCTAssertTrue(MediaLibrary.pasteboardHasMedia(pb))
            XCTAssertTrue(MediaLibrary.dropHasMedia(pb))
            let line = try XCTUnwrap(MediaLibrary.importFromPasteboard(pb)?.first)
            XCTAssertTrue(line.hasPrefix("![Memo](attachments/") && line.hasSuffix(".pdf)"), line)

            // A link to a picture on the web is media too; a link to a page and plain text aren't.
            pb.clearContents()
            pb.writeObjects([URL(string: "https://example.com/shots/Q3%20chart.PNG")! as NSURL])
            XCTAssertTrue(MediaLibrary.dropHasMedia(pb))
            XCTAssertEqual(MediaLibrary.remoteMediaURLs(on: pb).map(MediaLibrary.markdown(forRemote:)),
                           ["![Q3 chart](https://example.com/shots/Q3%20chart.PNG)"])
            pb.clearContents()
            pb.writeObjects([URL(string: "https://example.com/about")! as NSURL])
            XCTAssertFalse(MediaLibrary.dropHasMedia(pb))
            pb.clearContents()
            pb.setString("just words", forType: .string)
            XCTAssertFalse(MediaLibrary.dropHasMedia(pb))
        }
    }

    // MARK: Media on the web

    func testRemoteKindsComeFromTheExtension() {
        func kind(_ s: String) -> MediaLibrary.Kind? { MediaLibrary.remoteKind(of: URL(string: s)!) }
        XCTAssertEqual(kind("https://example.com/a.png"), .image)
        XCTAssertEqual(kind("https://example.com/a/B.JPG?w=800"), .image)
        XCTAssertEqual(kind("http://example.com/a.webp"), .image)
        XCTAssertEqual(kind("https://example.com/a.heic"), .image)
        XCTAssertEqual(kind("https://example.com/a.gif#x"), .image)
        XCTAssertEqual(kind("https://cdn.example.com/v/clip.mp4"), .video)
        XCTAssertEqual(kind("https://example.com/clip.MOV"), .video)
        XCTAssertEqual(kind("https://example.com/report.pdf?dl=1"), .pdf)
        XCTAssertNil(kind("https://example.com/watch?v=abc"))
        XCTAssertNil(kind("https://example.com/"))
        XCTAssertNil(kind("https://example.com/a.mkv"))
        XCTAssertNil(kind("ftp://example.com/a.png"))
        XCTAssertNil(MediaLibrary.remoteKind(of: URL(fileURLWithPath: "/tmp/a.png")))
    }

    func testCacheNamesAreStableAndKeepTheFormat() {
        let url = URL(string: "https://example.com/Photos/Team.JPG?size=large")!
        let key = RemoteMedia.cacheKey(for: url)
        XCTAssertEqual(key.count, 32)
        XCTAssertTrue(key.allSatisfy { $0.isHexDigit && !$0.isUppercase })
        XCTAssertEqual(RemoteMedia.cacheKey(for: URL(string: "https://example.com/Photos/Team.JPG?size=large")!), key, "same link, same file")
        XCTAssertNotEqual(RemoteMedia.cacheKey(for: URL(string: "https://example.com/Photos/Team.JPG?size=small")!), key)
        XCTAssertEqual(RemoteMedia.cacheName(for: url, mimeType: "text/html"), "\(key).jpg", "the link's own extension wins")
        // No extension in the link: the server's type decides, and a web page isn't media.
        let bare = URL(string: "https://images.example.com/photo-123")!
        let bareKey = RemoteMedia.cacheKey(for: bare)
        XCTAssertEqual(RemoteMedia.cacheName(for: bare, mimeType: "image/png"), "\(bareKey).png")
        XCTAssertEqual(RemoteMedia.cacheName(for: bare, mimeType: "application/pdf"), "\(bareKey).pdf")
        XCTAssertNil(RemoteMedia.cacheName(for: bare, mimeType: "text/html"))
        XCTAssertNil(RemoteMedia.cacheName(for: bare, mimeType: nil))
        XCTAssertEqual(RemoteMedia.posterName(for: url), "\(key)-poster.png")
    }

    func testFetchedMediaIsCachedInTheDataFolder() throws {
        let web = MediaFixtures.FakeWeb(data: try MediaFixtures.png(), mimeType: "image/png")
        try withMediaSandbox(web: web) { dir in
            let url = URL(string: "https://example.com/chart.png")!
            let remote = RemoteMedia.shared
            XCTAssertEqual(remote.file(for: url), .loading)
            waitForMedia { remote.file(for: url) != .loading }
            let expected = dir.appendingPathComponent("MediaCache/\(RemoteMedia.cacheKey(for: url)).png")
            XCTAssertEqual(remote.file(for: url), .ready(expected))
            XCTAssertTrue(FileManager.default.fileExists(atPath: expected.path))
            XCTAssertEqual(web.requests, [url], "fetched once")

            // Next launch (a fresh cache object) finds it on disk without the network.
            let offline = MediaFixtures.FakeWeb(data: nil)
            let relaunched = RemoteMedia(loader: offline.loader)
            XCTAssertEqual(relaunched.file(for: url), .ready(expected))
            XCTAssertTrue(offline.requests.isEmpty)
        }
    }

    func testFailedFetchesReportFailure() throws {
        let web = MediaFixtures.FakeWeb(data: nil)
        try withMediaSandbox(web: web) { _ in
            let url = URL(string: "https://example.com/gone.png")!
            XCTAssertEqual(RemoteMedia.shared.file(for: url), .loading)
            waitForMedia { RemoteMedia.shared.file(for: url) != .loading }
            XCTAssertEqual(RemoteMedia.shared.file(for: url), .failed)
            XCTAssertEqual(web.requests.count, 1, "not retried on every redraw")

            // A link without an extension that turns out to be a web page isn't kept.
            web.data = Data("<html></html>".utf8)
            web.mimeType = "text/html"
            let page = URL(string: "https://example.com/photo-page")!
            XCTAssertEqual(RemoteMedia.shared.file(for: page), .loading)
            waitForMedia { RemoteMedia.shared.file(for: page) != .loading }
            XCTAssertEqual(RemoteMedia.shared.file(for: page), .failed)
        }
    }

    func testCacheTrimDropsTheLeastRecentlyUsedFirst() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("docket-trim-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for (name, age) in [("old", 30.0), ("middle", 10.0), ("new", 1.0)] {
            let url = dir.appendingPathComponent(name)
            try Data(count: 1000).write(to: url)
            try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-age * 86_400)], ofItemAtPath: url.path)
        }
        RemoteMedia.trim(dir, to: 2500)
        XCTAssertEqual(Set(try FileManager.default.contentsOfDirectory(atPath: dir.path)), ["middle", "new"])
        // The file just fetched stays even if it's the oldest.
        RemoteMedia.trim(dir, to: 1500, keeping: dir.appendingPathComponent("middle"))
        XCTAssertEqual(Set(try FileManager.default.contentsOfDirectory(atPath: dir.path)), ["middle"])
    }

    func testNoteViewsTakeMediaDropsAndTheEditorStillTakesText() {
        func make<T: NSTextView>(_ type: T.Type) -> T {
            let storage = NSTextStorage()
            let layout = NSLayoutManager()
            storage.addLayoutManager(layout)
            let container = NSTextContainer(size: NSSize(width: 400, height: CGFloat.greatestFiniteMagnitude))
            layout.addTextContainer(container)
            return T(frame: NSRect(x: 0, y: 0, width: 400, height: 300), textContainer: container)
        }
        let promised = NSPasteboard.PasteboardType(NSFilePromiseReceiver.readableDraggedTypes.first ?? "com.apple.NSFilePromiseItemMetaData")

        let reader = make(ReaderTextView.self)
        reader.isEditable = false
        reader.updateDragTypeRegistration()
        for type in [NSPasteboard.PasteboardType.fileURL, .URL, .tiff, promised] {
            XCTAssertTrue(reader.registeredDraggedTypes.contains(type), "Read mode takes \(type.rawValue)")
        }

        let editor = make(MarkdownTextView.self)
        editor.isRichText = false
        editor.updateDragTypeRegistration()
        // As in the app: registered before it's shown, then again once it's in a window.
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.titled], backing: .buffered, defer: true)
        window.contentView = editor
        defer { window.contentView = nil }
        for type in [NSPasteboard.PasteboardType.fileURL, promised] {
            XCTAssertTrue(editor.registeredDraggedTypes.contains(type), "Edit mode takes \(type.rawValue)")
        }
        XCTAssertTrue(editor.registeredDraggedTypes.contains(NSPasteboard.PasteboardType("NSStringPboardType"))
            || editor.registeredDraggedTypes.contains(.string), "text can still be dragged into the editor")
    }
}
