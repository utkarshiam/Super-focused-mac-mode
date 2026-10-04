import AppKit
import AVFoundation
import UniformTypeIdentifiers

extension NSAttributedString.Key {
    /// On a rendered photo or video: the file it shows (a click opens it full size / plays it).
    static let docketMediaURL = NSAttributedString.Key("DocketMediaURL")
}

/// Photos and videos added to notes. Files are copied into the data folder's "attachments"
/// directory and referenced from the note's Markdown as `![name](attachments/<id>.<ext>)`,
/// so notes keep working if the originals move, and exports stay plain Markdown.
enum MediaLibrary {
    enum Kind { case image, video }

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
        if type.conforms(to: .movie) { return playableTypes.contains(type.identifier) ? .video : nil }
        if type.conforms(to: .image) { return .image }
        return nil
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

    /// Copies media files into the library and returns a Markdown line for each.
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

    /// True when the pasteboard holds photos/videos (files or raw image data) rather than text.
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

    /// Image formats a paste keeps byte for byte, best first: GIF so animations survive, then
    /// camera originals. A pasteboard with only TIFF goes through `importImage` as PNG instead.
    private static let pastedImageTypes: [UTType] = [.gif, .heic, .jpeg, .png]

    /// Saves the pasteboard's original image bytes (a copied JPEG stays a small JPEG);
    /// nil when it has none in those formats.
    private static func importImageData(from pb: NSPasteboard) -> String? {
        for type in pastedImageTypes {
            guard let data = pb.data(forType: NSPasteboard.PasteboardType(type.identifier)),
                  let source = CGImageSourceCreateWithData(data as CFData, nil), CGImageSourceGetCount(source) > 0,
                  let ext = type.preferredFilenameExtension else { continue }
            return save(data, ext: ext, alt: "Image")
        }
        return nil
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

/// Decoded photos and video poster frames, kept in memory. Posters are made in the background;
/// `didLoad` fires when one is ready so open notes can redraw.
final class MediaCache {
    static let shared = MediaCache()
    static let didLoad = Notification.Name("DocketMediaDidLoad")

    private var images: [URL: NSImage] = [:]
    private var posters: [URL: NSImage] = [:]
    private var pending: Set<URL> = []

    func image(for url: URL) -> NSImage? {
        if let cached = images[url] { return cached }
        guard let image = NSImage(contentsOf: url) else { return nil }
        images[url] = image
        return image
    }

    /// The video's first frame, or nil while it's still being made.
    func poster(for url: URL) -> NSImage? {
        if let cached = posters[url] { return cached }
        guard !pending.contains(url) else { return nil }
        pending.insert(url)
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 1600, height: 1600)
        let time = NSValue(time: CMTime(seconds: 0.4, preferredTimescale: 600))
        generator.generateCGImagesAsynchronously(forTimes: [time]) { [weak self] _, cgImage, _, _, _ in
            let image = cgImage.map { NSImage(cgImage: $0, size: NSSize(width: $0.width, height: $0.height)) }
            DispatchQueue.main.async {
                guard let self else { return }
                self.pending.remove(url)
                self.posters[url] = image ?? NSImage(size: NSSize(width: 1280, height: 720))
                NotificationCenter.default.post(name: MediaCache.didLoad, object: url)
            }
        }
        return nil
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
