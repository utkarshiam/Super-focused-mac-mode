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
}
