import AppKit
import XCTest
@testable import Docket

/// Shared by the media tests: real files to import, and a web without a network.
enum MediaFixtures {
    /// A PDF with `pages` pages, written the way any app would.
    static func writePDF(pages: Int, to url: URL) throws {
        var box = CGRect(x: 0, y: 0, width: 200, height: 300)
        let context = try XCTUnwrap(CGContext(url as CFURL, mediaBox: &box, nil))
        for _ in 0..<pages {
            context.beginPDFPage(nil)
            context.setFillColor(NSColor.red.cgColor)
            context.fill(CGRect(x: 20, y: 20, width: 80, height: 120))
            context.endPDFPage()
        }
        context.closePDF()
    }

    static func png(width: CGFloat = 40, height: CGFloat = 20) throws -> Data {
        let image = NSImage(size: NSSize(width: width, height: height), flipped: false) { r in
            NSColor.red.setFill()
            r.fill()
            return true
        }
        let rep = try XCTUnwrap(image.tiffRepresentation.flatMap(NSBitmapImageRep.init(data:)))
        return try XCTUnwrap(rep.representation(using: .png, properties: [:]))
    }

    /// Serves `data` for every request (or fails when nil), counting the requests.
    final class FakeWeb {
        var data: Data?
        var mimeType: String?
        /// Answers for particular hosts, in place of `data`.
        var hosts: [String: (data: Data, mimeType: String?)] = [:]
        private(set) var requests: [URL] = []

        init(data: Data?, mimeType: String? = nil) {
            self.data = data
            self.mimeType = mimeType
        }

        lazy var loader: RemoteMedia.Loader = { [unowned self] url, done in
            self.requests.append(url)
            let answer = url.host.flatMap { self.hosts[$0] }
            guard let data = answer?.data ?? self.data else {
                done(.failure(URLError(.notConnectedToInternet)))
                return
            }
            let file = FileManager.default.temporaryDirectory.appendingPathComponent("docket-fake-\(UUID().uuidString)")
            do {
                try data.write(to: file)
                done(.success(RemoteMedia.Download(file: file, mimeType: answer.map { $0.mimeType } ?? self.mimeType)))
            } catch {
                done(.failure(error))
            }
        }
    }
}

extension XCTestCase {
    /// Runs `body` with the library pointed at a fresh data folder and `RemoteMedia.shared` using `web`
    /// (and a poster maker that finds no frame), both restored afterwards.
    func withMediaSandbox(web: MediaFixtures.FakeWeb = .init(data: nil), posters: NSImage? = nil,
                          _ body: (URL) throws -> Void) throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("docket-media-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let previousDirectory = MediaLibrary.dataDirectory
        let previousRemote = RemoteMedia.shared
        MediaLibrary.dataDirectory = dir
        RemoteMedia.shared = RemoteMedia(loader: web.loader, posterMaker: { _, done in done(posters) })
        defer {
            MediaLibrary.dataDirectory = previousDirectory
            RemoteMedia.shared = previousRemote
        }
        try FileManager.default.createDirectory(at: MediaLibrary.folder, withIntermediateDirectories: true)
        try body(dir)
    }

    /// Runs the main run loop (where fetches, posters and PDF summaries land) until `done` holds.
    func waitForMedia(timeout: TimeInterval = 5, file: StaticString = #filePath, line: UInt = #line, until done: () -> Bool) {
        let deadline = Date().addingTimeInterval(timeout)
        while !done(), Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
        XCTAssertTrue(done(), "media didn't finish loading", file: file, line: line)
    }
}

extension NSAttributedString {
    /// The attachment cells in order, with what a click on each opens.
    var mediaCells: [(cell: NSTextAttachmentCell, opens: URL?)] {
        var cells: [(NSTextAttachmentCell, URL?)] = []
        enumerateAttribute(.attachment, in: NSRange(location: 0, length: length)) { value, range, _ in
            guard let cell = (value as? NSTextAttachment)?.attachmentCell as? NSTextAttachmentCell else { return }
            cells.append((cell, attribute(.docketMediaURL, at: range.location, effectiveRange: nil) as? URL))
        }
        return cells
    }
}
