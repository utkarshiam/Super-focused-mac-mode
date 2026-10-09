import AppKit
import AVFoundation
import PDFKit
import UniformTypeIdentifiers

extension NSAttributedString.Key {
    /// On rendered media: what a click opens. A file opens in Quick Look (photos full size, videos
    /// play, PDFs page through); a web address (a remote video, a card still loading) opens in the browser.
    static let docketMediaURL = NSAttributedString.Key("DocketMediaURL")
    /// On rendered media: what it is in words ("PDF: Board deck"), for formats that can't hold the card.
    static let docketMediaLabel = NSAttributedString.Key("DocketMediaLabel")
}

/// Photos, videos and PDFs added to notes. Files are copied into the data folder's "attachments"
/// directory and referenced from the note's Markdown as `![name](attachments/<id>.<ext>)`,
/// so notes keep working if the originals move, and exports stay plain Markdown.
/// Media on the web (`![](https://…)`, or a bare link to a picture, video or PDF on its own line)
/// is fetched into a cache by `RemoteMedia`.
enum MediaLibrary {
    enum Kind { case image, video, pdf }

    /// Set at launch to the store's data directory.
    static var dataDirectory: URL = Persistence.defaultDirectory
    static let prefix = "attachments/"
    static var folder: URL { dataDirectory.appendingPathComponent("attachments", isDirectory: true) }

    /// Movie formats AVFoundation can open. Others (mkv, webm) would only show a blank tile.
    private static let playableTypes = Set(AVURLAsset.audiovisualTypes().map(\.rawValue))

    static func kind(of url: URL) -> Kind? { kind(ofExtension: url.pathExtension) }

    static func kind(ofExtension ext: String) -> Kind? {
        let ext = ext.lowercased()
        // A ".ts" file is far more likely TypeScript than an MPEG transport stream.
        guard ext != "ts", let type = UTType(filenameExtension: ext) else { return nil }
        if type.conforms(to: .pdf) { return .pdf }
        if type.conforms(to: .movie) { return playableTypes.contains(type.identifier) ? .video : nil }
        if type.conforms(to: .image) { return .image }
        return nil
    }

    /// Web formats a link may point at to show as media. Kept to what every Mac can show or play.
    static let remoteImageExtensions: Set<String> = ["png", "jpg", "jpeg", "gif", "heic", "webp"]
    static let remoteVideoExtensions: Set<String> = ["mp4", "mov", "m4v"]

    /// What an http(s) address points at, judged by its file extension; nil for a web page.
    static func remoteKind(of url: URL) -> Kind? {
        guard isWebURL(url) else { return nil }
        let ext = url.pathExtension.lowercased()
        if remoteImageExtensions.contains(ext) { return .image }
        if remoteVideoExtensions.contains(ext) { return .video }
        if ext == "pdf" { return .pdf }
        return nil
    }

    static func isWebURL(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http" else { return false }
        return url.host?.isEmpty == false
    }

    /// Resolves a path from a note ("attachments/…", a file URL or an absolute path).
    static func resolve(_ path: String) -> URL? {
        let p = path.removingPercentEncoding ?? path
        if p.hasPrefix(prefix) { return dataDirectory.appendingPathComponent(p) }
        if let u = URL(string: path), u.isFileURL { return u }
        if p.hasPrefix("/") { return URL(fileURLWithPath: p) }
        if p.hasPrefix("~/") { return URL(fileURLWithPath: (p as NSString).expandingTildeInPath) }
        return nil
    }

    /// Copies photos, videos and PDFs into the library and returns a Markdown line for each.
    /// Safe to call from a background queue (a big video from another disk takes a while).
    static func importFiles(_ urls: [URL]) -> [String] {
        let fm = FileManager.default
        try? fm.createDirectory(at: folder, withIntermediateDirectories: true)
        return urls.compactMap { url in
            guard kind(of: url) != nil else { return nil }
            let name = "\(UUID().uuidString).\(url.pathExtension.lowercased())"
            do {
                try copyIn(url, to: folder.appendingPathComponent(name))
            } catch {
                NSLog("Docket: couldn't add \(url.lastPathComponent): \(error)")
                return nil
            }
            return markdown(alt: url.deletingPathExtension().lastPathComponent, name: name)
        }
    }

    /// A copy keeps the original's date, so it's reset: the clean-up's week of grace
    /// should count from when the file joined the library.
    private static func copyIn(_ source: URL, to dest: URL) throws {
        try FileManager.default.copyItem(at: source, to: dest)
        try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: dest.path)
    }

    /// Saves a pasted image (a screenshot, an image copied from a web page) as PNG.
    static func importImage(_ image: NSImage, alt: String = "Image") -> String? {
        guard let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else { return nil }
        return save(png, ext: "png", alt: alt)
    }

    private static func save(_ data: Data, ext: String, alt: String) -> String? {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let name = "\(UUID().uuidString).\(ext)"
        do {
            try data.write(to: folder.appendingPathComponent(name), options: .atomic)
        } catch {
            return nil
        }
        return markdown(alt: alt, name: name)
    }

    private static func markdown(alt: String, name: String) -> String {
        let clean = alt.replacingOccurrences(of: "[", with: "(").replacingOccurrences(of: "]", with: ")")
        return "![\(clean)](\(prefix)\(name))"
    }

    // MARK: Pasteboard

    static func mediaFileURLs(on pb: NSPasteboard) -> [URL] {
        let urls = pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        return urls.filter { kind(of: $0) != nil }
    }

    /// True when the pasteboard holds photos, videos or PDFs (files or raw image data) rather than text.
    static func pasteboardHasMedia(_ pb: NSPasteboard) -> Bool {
        if !mediaFileURLs(on: pb).isEmpty { return true }
        let hasText = pb.availableType(from: [.string]) != nil
        return !hasText && NSImage.canInit(with: pb)
    }

    /// Imports whatever media the pasteboard holds; nil when it holds none.
    static func importFromPasteboard(_ pb: NSPasteboard) -> [String]? {
        let files = mediaFileURLs(on: pb)
        if !files.isEmpty {
            let lines = importFiles(files)
            return lines.isEmpty ? nil : lines
        }
        guard pb.availableType(from: [.string]) == nil else { return nil }
        if let line = importImageData(from: pb) { return [line] }
        if let image = NSImage(pasteboard: pb), let line = importImage(image) { return [line] }
        return nil
    }

    // MARK: Drops

    /// What a note registers for drops: files, files promised by Photos or a browser, web links, image data.
    static var dropTypes: [NSPasteboard.PasteboardType] {
        [.fileURL, .URL, .tiff, .png] + pastedImageTypes.map { NSPasteboard.PasteboardType($0.identifier) }
            + NSFilePromiseReceiver.readableDraggedTypes.map { NSPasteboard.PasteboardType($0) }
    }

    /// Links to pictures, videos and PDFs on the web (not files).
    static func remoteMediaURLs(on pb: NSPasteboard) -> [URL] {
        let urls = pb.readObjects(forClasses: [NSURL.self], options: nil) as? [URL] ?? []
        return urls.filter { !$0.isFileURL && remoteKind(of: $0) != nil }
    }

    /// Files another app (Photos, a browser) promises to write once dropped, if they're media.
    private static func mediaPromises(on pb: NSPasteboard) -> [NSFilePromiseReceiver] {
        let receivers = pb.readObjects(forClasses: [NSFilePromiseReceiver.self], options: nil) as? [NSFilePromiseReceiver] ?? []
        return receivers.filter { receiver in
            receiver.fileTypes.contains { id in
                guard let type = UTType(id) else { return false }
                return type.conforms(to: .image) || type.conforms(to: .movie) || type.conforms(to: .pdf)
            }
        }
    }

    /// Image bytes with no text or file beside them (text with a picture in it is a text drop).
    private static func hasLooseImageData(_ pb: NSPasteboard) -> Bool {
        pb.availableType(from: [.string, .fileURL]) == nil && NSImage.canInit(with: pb)
    }

    /// True when a drop brings media: files, promised files, image data, or links to media on the web.
    static func dropHasMedia(_ pb: NSPasteboard) -> Bool {
        !mediaFileURLs(on: pb).isEmpty || !mediaPromises(on: pb).isEmpty || hasLooseImageData(pb) || !remoteMediaURLs(on: pb).isEmpty
    }

    /// Turns a drop into Markdown lines and hands them to `done` on the main queue (empty if nothing
    /// could be added). Files are copied in the background; the pasteboard is read before this returns,
    /// as a drag's pasteboard doesn't outlive the drop.
    static func importDrop(_ pb: NSPasteboard, then done: @escaping @MainActor ([String]) -> Void) {
        let files = mediaFileURLs(on: pb)
        if !files.isEmpty {
            importFilesInBackground(files, then: done)
            return
        }
        let promises = mediaPromises(on: pb)
        if !promises.isEmpty {
            receive(promises, then: done)
            return
        }
        if hasLooseImageData(pb), let lines = importFromPasteboard(pb) {
            DispatchQueue.main.async { done(lines) }
            return
        }
        let links = remoteMediaURLs(on: pb).map(markdown(forRemote:))
        DispatchQueue.main.async { done(links) }
    }

    /// `![name](https://…)` for a link to media on the web.
    static func markdown(forRemote url: URL) -> String {
        let name = url.deletingPathExtension().lastPathComponent
        let alt = name.removingPercentEncoding ?? name
        return "![\(alt.replacingOccurrences(of: "[", with: "(").replacingOccurrences(of: "]", with: ")"))](\(url.absoluteString))"
    }

    /// Copies files on a background queue (a large video from another disk or from iCloud can
    /// take a while) and hands their Markdown lines to `done` on the main queue: empty if none was added.
    static func importFilesInBackground(_ urls: [URL], then done: @escaping @MainActor ([String]) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let lines = importFiles(urls)
            DispatchQueue.main.async { done(lines) }
        }
    }

    /// Lets the other app write its promised files into a scratch folder, then imports them.
    private static func receive(_ promises: [NSFilePromiseReceiver], then done: @escaping @MainActor ([String]) -> Void) {
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("Docket-drop-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        let queue = OperationQueue()
        queue.qualityOfService = .userInitiated
        let group = DispatchGroup()
        let lock = NSLock()
        var received: [URL] = []
        for promise in promises {
            for _ in promise.fileTypes { group.enter() }
            promise.receivePromisedFiles(atDestination: scratch, options: [:], operationQueue: queue) { url, error in
                if error == nil {
                    lock.lock()
                    received.append(url)
                    lock.unlock()
                }
                group.leave()
            }
        }
        DispatchQueue.global(qos: .userInitiated).async {
            // A promise that never arrives (the other app quit) doesn't hold up the ones that did.
            _ = group.wait(timeout: .now() + 120)
            lock.lock()
            let files = received
            lock.unlock()
            let lines = importFiles(files)
            try? FileManager.default.removeItem(at: scratch)
            DispatchQueue.main.async { done(lines) }
        }
    }

    /// Image formats a paste keeps byte for byte, best first: an animated GIF so it keeps moving,
    /// then camera originals. A still GIF (256 colours) is the last choice, and a pasteboard with
    /// only TIFF goes through `importImage` as PNG instead.
    private static let pastedImageTypes: [UTType] = [.gif, .heic, .jpeg, .png]

    /// Saves the pasteboard's original image bytes (a copied JPEG stays a small JPEG);
    /// nil when it has none in those formats.
    private static func importImageData(from pb: NSPasteboard) -> String? {
        var stillGIF: Data?
        for type in pastedImageTypes {
            guard let data = pb.data(forType: NSPasteboard.PasteboardType(type.identifier)),
                  let source = CGImageSourceCreateWithData(data as CFData, nil), CGImageSourceGetCount(source) > 0,
                  let ext = type.preferredFilenameExtension else { continue }
            if type == .gif, CGImageSourceGetCount(source) == 1 {
                stillGIF = data
                continue
            }
            return save(data, ext: ext, alt: "Image")
        }
        return stillGIF.flatMap { save($0, ext: "gif", alt: "Image") }
    }

    // MARK: Housekeeping

    // Also matches "attachments\/…", the way the JSON data files and backups write it.
    private static let reference = try! NSRegularExpression(pattern: #"attachments\\?/([A-Za-z0-9\-]+\.[A-Za-z0-9]+)"#)

    static func referencedNames(in bodies: [String]) -> Set<String> {
        var names = Set<String>()
        for body in bodies {
            let ns = body as NSString
            for m in reference.matches(in: body, range: NSRange(location: 0, length: ns.length)) {
                names.insert(ns.substring(with: m.range(at: 1)))
            }
        }
        return names
    }

    /// Deletes files no note mentions any more, once they're a week old. Files that a daily backup
    /// or a set-aside unreadable data file still mentions stay, so restoring one finds its photos.
    static func collectGarbage(noteBodies: [String]) {
        let fm = FileManager.default
        let keep = referencedNames(in: noteBodies)
        let cutoff = Date().addingTimeInterval(-7 * 86_400)
        let items = (try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        let unused = items.filter { url in
            let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? Date()
            return modified < cutoff && !keep.contains(url.lastPathComponent)
        }
        guard !unused.isEmpty else { return }
        var saved = Set<String>()
        for file in Persistence(directory: dataDirectory).savedCopies() {
            // Read as text, so a file too damaged to decode still protects what it mentions.
            // One that can't be read at all stops the clean-up rather than risk its photos.
            guard let data = try? Data(contentsOf: file) else { return }
            saved.formUnion(referencedNames(in: [String(decoding: data, as: UTF8.self)]))
        }
        for url in unused where !saved.contains(url.lastPathComponent) { try? fm.removeItem(at: url) }
    }

    /// Copies the media a set of notes uses into `destination/attachments` (for exports and backups).
    static func copyReferencedMedia(for bodies: [String], to destination: URL) {
        let names = referencedNames(in: bodies)
        guard !names.isEmpty else { return }
        let fm = FileManager.default
        let target = destination.appendingPathComponent("attachments", isDirectory: true)
        try? fm.createDirectory(at: target, withIntermediateDirectories: true)
        for name in names {
            let src = folder.appendingPathComponent(name), dst = target.appendingPathComponent(name)
            if fm.fileExists(atPath: src.path), !fm.fileExists(atPath: dst.path) { try? fm.copyItem(at: src, to: dst) }
        }
    }

    /// The reverse, for an imported backup: copies media the notes use but the library lacks
    /// from the `attachments` folder next to it.
    static func restoreMissingMedia(for bodies: [String], from source: URL) {
        let fm = FileManager.default
        let origin = source.appendingPathComponent("attachments", isDirectory: true)
        let names = referencedNames(in: bodies).filter {
            !fm.fileExists(atPath: folder.appendingPathComponent($0).path) && fm.fileExists(atPath: origin.appendingPathComponent($0).path)
        }
        guard !names.isEmpty else { return }
        try? fm.createDirectory(at: folder, withIntermediateDirectories: true)
        for name in names {
            do {
                try copyIn(origin.appendingPathComponent(name), to: folder.appendingPathComponent(name))
            } catch {
                NSLog("Docket: couldn't restore \(name): \(error)")
            }
        }
    }
}

/// What a PDF card shows: how many pages, and the first one small.
struct PDFSummary {
    var pageCount: Int
    var thumbnail: NSImage?

    /// Opens the file with PDFKit; nil when it isn't a PDF PDFKit can read.
    static func make(for url: URL, thumbnailSize: NSSize = NSSize(width: 160, height: 208)) -> PDFSummary? {
        guard let document = PDFDocument(url: url) else { return nil }
        let thumbnail = document.page(at: 0)?.thumbnail(of: thumbnailSize, for: .cropBox)
        return PDFSummary(pageCount: document.pageCount, thumbnail: thumbnail)
    }

    /// "PDF · 12 pages"
    var subtitle: String { pageCount > 0 ? "PDF · \(Fmt.plural(pageCount, "page"))" : "PDF" }
}

/// Decoded photos, video poster frames and PDF summaries, kept in memory. Posters and summaries are
/// made in the background; `didLoad` fires when one is ready so open notes can redraw.
final class MediaCache {
    static let shared = MediaCache()
    static let didLoad = Notification.Name("DocketMediaDidLoad")

    private var images: [URL: NSImage] = [:]
    private var posters: [URL: NSImage] = [:]
    private var pdfs: [URL: PDFSummary] = [:]
    private var pending: Set<URL> = []

    func image(for url: URL) -> NSImage? {
        if let cached = images[url] { return cached }
        guard let image = NSImage(contentsOf: url), image.isValid, image.size.width > 0 else { return nil }
        images[url] = image
        return image
    }

    /// The video's first frame, or nil while it's still being made.
    func poster(for url: URL) -> NSImage? {
        if let cached = posters[url] { return cached }
        guard !pending.contains(url) else { return nil }
        pending.insert(url)
        Self.makePoster(for: url) { [weak self] image in
            DispatchQueue.main.async {
                guard let self else { return }
                self.pending.remove(url)
                self.posters[url] = image ?? NSImage(size: NSSize(width: 1280, height: 720))
                NotificationCenter.default.post(name: MediaCache.didLoad, object: url)
            }
        }
        return nil
    }

    /// The PDF's page count and first page, or nil while they're being read.
    func pdf(for url: URL) -> PDFSummary? {
        if let cached = pdfs[url] { return cached }
        guard !pending.contains(url) else { return nil }
        pending.insert(url)
        DispatchQueue.global(qos: .userInitiated).async {
            let summary = PDFSummary.make(for: url) ?? PDFSummary(pageCount: 0, thumbnail: nil)
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.pending.remove(url)
                self.pdfs[url] = summary
                NotificationCenter.default.post(name: MediaCache.didLoad, object: url)
            }
        }
        return nil
    }

    /// A frame from early in the video (a local file or a web address); nil if it can't be read.
    /// `done` runs on a background queue.
    static func makePoster(for url: URL, done: @escaping (NSImage?) -> Void) {
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 1600, height: 1600)
        let time = NSValue(time: CMTime(seconds: 0.4, preferredTimescale: 600))
        generator.generateCGImagesAsynchronously(forTimes: [time]) { _, cgImage, _, _, _ in
            done(cgImage.map { NSImage(cgImage: $0, size: NSSize(width: $0.width, height: $0.height)) })
        }
    }
}

/// Draws a photo or video inline in rendered notes: full text width (capped), rounded corners,
/// a hairline, and a play button on videos.
final class MediaAttachmentCell: NSTextAttachmentCell {
    let url: URL
    let isVideo: Bool
    let picture: NSImage?

    init(url: URL, isVideo: Bool, picture: NSImage?) {
        self.url = url
        self.isVideo = isVideo
        self.picture = picture
        super.init(imageCell: nil)
    }

    required init(coder: NSCoder) { fatalError("not used") }

    private var natural: NSSize {
        if let size = picture?.size, size.width > 1, size.height > 1 { return size }
        return NSSize(width: 1280, height: 720)
    }

    override func cellSize() -> NSSize { natural }

    override func cellBaselineOffset() -> NSPoint { .zero }

    override func cellFrame(for textContainer: NSTextContainer, proposedLineFragment lineFrag: NSRect,
                            glyphPosition position: NSPoint, characterIndex charIndex: Int) -> NSRect {
        let available = max(60, lineFrag.width - textContainer.lineFragmentPadding * 2 - 4)
        var width = min(natural.width, available, 720)
        var height = natural.height * width / natural.width
        if height > 520 {
            height = 520
            width = natural.width * height / natural.height
        }
        return NSRect(x: 0, y: 0, width: width.rounded(), height: height.rounded())
    }

    override func draw(withFrame cellFrame: NSRect, in controlView: NSView?) {
        let shape = NSBezierPath(roundedRect: cellFrame, xRadius: 14, yRadius: 14)
        NSGraphicsContext.saveGraphicsState()
        shape.addClip()
        if let picture, picture.size.width > 1 {
            picture.draw(in: cellFrame, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true,
                         hints: [.interpolation: NSImageInterpolation.high])
        } else {
            Palette.fill.setFill()
            cellFrame.fill()
        }
        if isVideo {
            NSColor.black.withAlphaComponent(0.18).setFill()
            cellFrame.fill(using: .sourceOver)
            let d: CGFloat = min(64, cellFrame.width / 4)
            let disc = NSRect(x: cellFrame.midX - d / 2, y: cellFrame.midY - d / 2, width: d, height: d)
            NSColor.white.withAlphaComponent(0.95).setFill()
            NSBezierPath(ovalIn: disc).fill()
            let tri = NSBezierPath()
            let s = d * 0.3
            // The text view is flipped: y grows downward.
            tri.move(to: NSPoint(x: disc.midX - s * 0.45, y: disc.midY - s * 0.6))
            tri.line(to: NSPoint(x: disc.midX - s * 0.45, y: disc.midY + s * 0.6))
            tri.line(to: NSPoint(x: disc.midX + s * 0.65, y: disc.midY))
            tri.close()
            NSColor(hex: 0x0E0E0C).setFill()
            tri.fill()
        }
        NSGraphicsContext.restoreGraphicsState()
        Palette.hair.setStroke()
        shape.lineWidth = 1
        shape.stroke()
    }

    override func wantsToTrackMouse() -> Bool { false }
}

/// A card in rendered notes for a PDF (its first page, name and page count), a YouTube, Vimeo or
/// Loom link (its thumbnail and title), and the stand-in for media still on its way from the web.
final class MediaCardCell: NSTextAttachmentCell {
    let cardTitle: String
    let cardSubtitle: String
    let thumbnail: NSImage?
    /// Shown in place of a thumbnail (an SF Symbol name).
    let symbol: String
    /// A video frame (16:9) rather than a page.
    let landscape: Bool

    static let height: CGFloat = 92
    static let maxWidth: CGFloat = 460

    init(title: String, subtitle: String, thumbnail: NSImage?, symbol: String, landscape: Bool = false) {
        cardTitle = title
        cardSubtitle = subtitle
        self.thumbnail = thumbnail
        self.symbol = symbol
        self.landscape = landscape
        super.init(imageCell: nil)
    }

    required init(coder: NSCoder) { fatalError("not used") }

    override func cellSize() -> NSSize { NSSize(width: Self.maxWidth, height: Self.height) }

    override func cellBaselineOffset() -> NSPoint { .zero }

    override func cellFrame(for textContainer: NSTextContainer, proposedLineFragment lineFrag: NSRect,
                            glyphPosition position: NSPoint, characterIndex charIndex: Int) -> NSRect {
        let available = max(160, lineFrag.width - textContainer.lineFragmentPadding * 2 - 4)
        return NSRect(x: 0, y: 0, width: min(Self.maxWidth, available).rounded(), height: Self.height)
    }

    override func draw(withFrame cellFrame: NSRect, in controlView: NSView?) {
        let card = cellFrame.insetBy(dx: 0.5, dy: 0.5)
        let shape = NSBezierPath(roundedRect: card, xRadius: 12, yRadius: 12)
        Palette.card.setFill()
        shape.fill()
        Palette.hair.setStroke()
        shape.lineWidth = 1
        shape.stroke()

        // The page (or a placeholder for it) on the left, portrait like a sheet of paper; a video's frame is wide.
        let slotHeight = card.height - 24
        let slotWidth = (slotHeight * (landscape ? 16.0 / 9.0 : 0.77)).rounded()
        var slot = NSRect(x: card.minX + 12, y: card.minY + 12, width: slotWidth, height: slotHeight)
        if let thumbnail, thumbnail.size.width > 1, thumbnail.size.height > 1 {
            let scale = min(slot.width / thumbnail.size.width, slot.height / thumbnail.size.height)
            let size = NSSize(width: (thumbnail.size.width * scale).rounded(), height: (thumbnail.size.height * scale).rounded())
            slot = NSRect(x: slot.minX, y: slot.midY - size.height / 2, width: size.width, height: size.height)
            NSColor.white.setFill()
            slot.fill()
            thumbnail.draw(in: slot, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true,
                           hints: [.interpolation: NSImageInterpolation.high])
            Palette.hairStrong.setStroke()
            let edge = NSBezierPath(rect: slot.insetBy(dx: 0.5, dy: 0.5))
            edge.lineWidth = 1
            edge.stroke()
        } else {
            let well = NSBezierPath(roundedRect: slot, xRadius: 6, yRadius: 6)
            Palette.fill.setFill()
            well.fill()
            let config = NSImage.SymbolConfiguration(pointSize: 18, weight: .regular)
                .applying(NSImage.SymbolConfiguration(paletteColors: [Palette.ink3]))
            if let glyph = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?.withSymbolConfiguration(config) {
                let r = NSRect(x: slot.midX - glyph.size.width / 2, y: slot.midY - glyph.size.height / 2,
                               width: glyph.size.width, height: glyph.size.height)
                glyph.draw(in: r, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
            }
        }

        let textX = slot.maxX + 14
        let textWidth = max(20, card.maxX - 14 - textX)
        let truncating = NSMutableParagraphStyle()
        truncating.lineBreakMode = .byTruncatingTail
        let titleAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 14, weight: .semibold), .foregroundColor: Palette.ink, .paragraphStyle: truncating,
        ]
        let subtitleAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 12, weight: .medium), .foregroundColor: Palette.ink2, .paragraphStyle: truncating,
        ]
        let block: CGFloat = 18 + 4 + 16
        let top = card.midY - block / 2
        (cardTitle as NSString).draw(in: NSRect(x: textX, y: top, width: textWidth, height: 18), withAttributes: titleAttrs)
        (cardSubtitle as NSString).draw(in: NSRect(x: textX, y: top + 22, width: textWidth, height: 16), withAttributes: subtitleAttrs)
    }

    override func wantsToTrackMouse() -> Bool { false }
}
