import AppKit
import CryptoKit
import UniformTypeIdentifiers

/// Pictures, PDFs and video posters from the web, for notes that link to them. Files are fetched
/// off the main thread into the data folder's "MediaCache" directory (oldest dropped past a size cap),
/// so a note shows them again at once, offline too. `MediaCache.didLoad` fires when one arrives or
/// fails, and open notes redraw. Everything but the fetching runs on the main thread.
final class RemoteMedia {
    /// Swapped in tests for one with a fake loader (no network).
    static var shared = RemoteMedia()

    enum State: Equatable {
        case loading
        /// The local copy.
        case ready(URL)
        case failed
    }

    enum PosterState {
        case loading
        case ready(NSImage)
        case failed
    }

    /// What a YouTube, Vimeo or Loom link shows as: the video's title, from the site's oEmbed.
    struct Embed: Codable, Equatable {
        var title: String
        var provider: String
        var thumbnail: URL?
    }

    enum EmbedState: Equatable {
        case loading
        case ready(Embed)
        case failed
    }

    struct Download {
        /// A temporary file the cache may move.
        var file: URL
        var mimeType: String?
    }

    enum LoadError: Error { case badResponse, tooLarge, notMedia }

    /// Fetches a web address into a temporary file. Calls back on any queue.
    typealias Loader = (URL, @escaping (Result<Download, Error>) -> Void) -> Void
    /// Makes a video's poster frame from its web address. Calls back on any queue.
    typealias PosterMaker = (URL, @escaping (NSImage?) -> Void) -> Void

    /// The whole cache stays under this; the least recently used files go first.
    static let cacheLimit: Int64 = 300 * 1024 * 1024
    /// Bigger files show as links rather than fill the cache.
    static let fileLimit: Int64 = 60 * 1024 * 1024

    private let directory: URL?
    private let loader: Loader
    private let posterMaker: PosterMaker
    private let io = DispatchQueue(label: "Docket.RemoteMedia", qos: .utility)

    private var index: [String: URL] = [:]
    private var indexedFolder: URL?
    private var pending: Set<URL> = []
    /// When each failed fetch failed; it's tried again after a while (the Mac may have been offline).
    private var failed: [URL: Date] = [:]
    private static let retryAfter: TimeInterval = 300
    private var touched: Set<URL> = []
    private var posters: [URL: NSImage] = [:]
    private var pendingPosters: Set<URL> = []
    private var failedPosters: Set<URL> = []
    private var embeds: [URL: Embed] = [:]
    private var pendingEmbeds: Set<URL> = []
    private var failedEmbeds: Set<URL> = []

    /// `directory` defaults to "MediaCache" in the data folder.
    init(directory: URL? = nil, loader: @escaping Loader = RemoteMedia.download, posterMaker: @escaping PosterMaker = MediaCache.makePoster) {
        self.directory = directory
        self.loader = loader
        self.posterMaker = posterMaker
    }

    var folder: URL { directory ?? MediaLibrary.dataDirectory.appendingPathComponent("MediaCache", isDirectory: true) }

    // MARK: Naming

    /// A stable name for a web address: the same link always finds the same file.
    static func cacheKey(for url: URL) -> String {
        SHA256.hash(data: Data(url.absoluteString.utf8)).prefix(16).map { String(format: "%02x", $0) }.joined()
    }

    /// The cache file's name: the key and an extension from the address, else from the server's
    /// MIME type. Nil when neither says it's a picture, video or PDF.
    static func cacheName(for url: URL, mimeType: String?) -> String? {
        let key = cacheKey(for: url)
        let fromURL = url.pathExtension.lowercased()
        if MediaLibrary.remoteKind(of: url) != nil { return "\(key).\(fromURL)" }
        guard let mimeType, let ext = UTType(mimeType: mimeType)?.preferredFilenameExtension?.lowercased(),
              MediaLibrary.kind(ofExtension: ext) != nil else { return nil }
        return "\(key).\(ext)"
    }

    static func posterName(for url: URL) -> String { "\(cacheKey(for: url))-poster.png" }
    static func embedName(for url: URL) -> String { "\(cacheKey(for: url))-embed.json" }

    // MARK: Files

    /// The local copy of a picture or PDF on the web, starting the fetch the first time it's asked for.
    func file(for url: URL) -> State {
        if let local = cachedFile(for: url) {
            touch(local, for: url)
            return .ready(local)
        }
        if let when = failed[url] {
            guard Date().timeIntervalSince(when) > Self.retryAfter else { return .failed }
            failed[url] = nil
        }
        if !pending.contains(url) { start(url) }
        return .loading
    }

    private func cachedFile(for url: URL) -> URL? {
        if indexedFolder != folder { rebuildIndex() }
        guard let file = index[Self.cacheKey(for: url)] else { return nil }
        guard FileManager.default.fileExists(atPath: file.path) else {
            // Dropped to keep the cache under its cap (or cleared by hand): fetch it again.
            index[Self.cacheKey(for: url)] = nil
            return nil
        }
        return file
    }

    private static let cachedName = try! NSRegularExpression(pattern: #"^([0-9a-f]{32})\.[a-z0-9]+$"#)

    private func rebuildIndex() {
        indexedFolder = folder
        index = [:]
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        for name in names {
            let ns = name as NSString
            guard let m = Self.cachedName.firstMatch(in: name, range: NSRange(location: 0, length: ns.length)) else { continue }
            index[ns.substring(with: m.range(at: 1))] = folder.appendingPathComponent(name)
        }
    }

    /// Marks a file as used this session, so the size cap drops others first.
    private func touch(_ file: URL, for url: URL) {
        guard touched.insert(url).inserted else { return }
        io.async { try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: file.path) }
    }

    private func start(_ url: URL) {
        pending.insert(url)
        let folder = folder
        loader(url) { [weak self] result in
            guard let self else { return }
            self.io.async {
                let stored = Self.store(result, for: url, in: folder)
                DispatchQueue.main.async {
                    self.pending.remove(url)
                    if let stored {
                        if self.indexedFolder == folder { self.index[Self.cacheKey(for: url)] = stored }
                        self.touched.insert(url)
                    } else {
                        self.failed[url] = Date()
                    }
                    NotificationCenter.default.post(name: MediaCache.didLoad, object: url)
                }
            }
        }
    }

    /// Moves a finished download into the cache; nil if it failed or isn't media.
    private static func store(_ result: Result<Download, Error>, for url: URL, in folder: URL) -> URL? {
        guard case let .success(download) = result else { return nil }
        let fm = FileManager.default
        defer { try? fm.removeItem(at: download.file) }
        let size = (try? download.file.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
        guard size > 0, Int64(size) <= fileLimit,
              download.mimeType.map({ !$0.lowercased().hasPrefix("text/") }) ?? true,
              let name = cacheName(for: url, mimeType: download.mimeType) else { return nil }
        try? fm.createDirectory(at: folder, withIntermediateDirectories: true)
        let dest = folder.appendingPathComponent(name)
        try? fm.removeItem(at: dest)
        do {
            try fm.moveItem(at: download.file, to: dest)
        } catch {
            return nil
        }
        trim(folder, to: cacheLimit, keeping: dest)
        return dest
    }

    /// Deletes the least recently used files until the folder is under `limit` bytes.
    static func trim(_ folder: URL, to limit: Int64, keeping kept: URL? = nil) {
        let fm = FileManager.default
        let keys: [URLResourceKey] = [.fileSizeKey, .contentModificationDateKey]
        let files = (try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: keys)) ?? []
        var entries = files.map { url -> (url: URL, size: Int64, date: Date) in
            let values = try? url.resourceValues(forKeys: Set(keys))
            return (url, Int64(values?.fileSize ?? 0), values?.contentModificationDate ?? .distantPast)
        }
        var total = entries.reduce(0) { $0 + $1.size }
        guard total > limit else { return }
        entries.sort { $0.date < $1.date }
        for entry in entries where total > limit && entry.url.lastPathComponent != kept?.lastPathComponent {
            try? fm.removeItem(at: entry.url)
            total -= entry.size
        }
    }

    // MARK: Posters

    /// The poster frame of a video on the web. The video itself isn't downloaded: a click opens it.
    func poster(for url: URL) -> PosterState {
        if let image = posters[url] { return .ready(image) }
        if failedPosters.contains(url) { return .failed }
        let file = folder.appendingPathComponent(Self.posterName(for: url))
        if let image = NSImage(contentsOf: file), image.size.width > 1 {
            posters[url] = image
            return .ready(image)
        }
        guard !pendingPosters.contains(url) else { return .loading }
        pendingPosters.insert(url)
        let folder = folder
        posterMaker(url) { [weak self] image in
            guard let self else { return }
            DispatchQueue.main.async {
                self.pendingPosters.remove(url)
                if let image, image.size.width > 1 {
                    self.posters[url] = image
                    self.io.async { Self.savePoster(image, to: folder.appendingPathComponent(Self.posterName(for: url))) }
                } else {
                    self.failedPosters.insert(url)
                }
                NotificationCenter.default.post(name: MediaCache.didLoad, object: url)
            }
        }
        return .loading
    }

    private static func savePoster(_ image: NSImage, to file: URL) {
        guard let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else { return }
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? png.write(to: file, options: .atomic)
    }

    // MARK: Video links

    /// The oEmbed address that describes a YouTube, Vimeo or Loom video link, and the site's name.
    static func embedEndpoint(for url: URL) -> (endpoint: URL, provider: String)? {
        guard MediaLibrary.isWebURL(url), let rawHost = url.host?.lowercased() else { return nil }
        let host = rawHost.hasPrefix("www.") ? String(rawHost.dropFirst(4)) : (rawHost.hasPrefix("m.") ? String(rawHost.dropFirst(2)) : rawHost)
        let parts = url.path.split(separator: "/").map(String.init)
        let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let base: String
        let provider: String
        switch host {
        case "youtube.com":
            let watch = parts.first == "watch" && query.contains { $0.name == "v" && $0.value?.isEmpty == false }
            let shortOrLive = parts.count >= 2 && ["shorts", "live"].contains(parts[0])
            guard watch || shortOrLive else { return nil }
            (base, provider) = ("https://www.youtube.com/oembed?format=json&url=", "YouTube")
        case "youtu.be":
            guard parts.count == 1 else { return nil }
            (base, provider) = ("https://www.youtube.com/oembed?format=json&url=", "YouTube")
        case "vimeo.com":
            guard let id = parts.first, id.allSatisfy(\.isNumber) else { return nil }
            (base, provider) = ("https://vimeo.com/api/oembed.json?url=", "Vimeo")
        case "loom.com":
            guard parts.count >= 2, ["share", "embed"].contains(parts[0]) else { return nil }
            (base, provider) = ("https://www.loom.com/v1/oembed?url=", "Loom")
        default:
            return nil
        }
        let encoded = url.absoluteString.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? url.absoluteString
        return URL(string: base + encoded).map { ($0, provider) }
    }

    /// The title (and thumbnail) of a YouTube, Vimeo or Loom link, fetched once and kept in the cache.
    func embed(for url: URL) -> EmbedState {
        if let embed = embeds[url] { return .ready(embed) }
        if failedEmbeds.contains(url) { return .failed }
        guard let (endpoint, provider) = Self.embedEndpoint(for: url) else { return .failed }
        let file = folder.appendingPathComponent(Self.embedName(for: url))
        if let data = try? Data(contentsOf: file), let embed = try? JSONDecoder().decode(Embed.self, from: data) {
            embeds[url] = embed
            return .ready(embed)
        }
        guard pendingEmbeds.insert(url).inserted else { return .loading }
        loader(endpoint) { [weak self] result in
            let embed = Self.parseEmbed(result, provider: provider)
            if let embed, let data = try? JSONEncoder().encode(embed) {
                try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
                try? data.write(to: file, options: .atomic)
            }
            DispatchQueue.main.async {
                guard let self else { return }
                self.pendingEmbeds.remove(url)
                if let embed { self.embeds[url] = embed } else { self.failedEmbeds.insert(url) }
                NotificationCenter.default.post(name: MediaCache.didLoad, object: url)
            }
        }
        return .loading
    }

    private static func parseEmbed(_ result: Result<Download, Error>, provider: String) -> Embed? {
        guard case let .success(download) = result else { return nil }
        defer { try? FileManager.default.removeItem(at: download.file) }
        guard let data = try? Data(contentsOf: download.file), data.count < 1_000_000,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let title = (json["title"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty else { return nil }
        let thumbnail = (json["thumbnail_url"] as? String).flatMap(URL.init(string:)).flatMap { MediaLibrary.isWebURL($0) ? $0 : nil }
        return Embed(title: title, provider: (json["provider_name"] as? String) ?? provider, thumbnail: thumbnail)
    }

    // MARK: Network

    private static let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.urlCache = nil // the cache folder is the cache
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 120
        return URLSession(configuration: config)
    }()

    /// The real loader: an ordinary GET, off the main thread.
    static func download(_ url: URL, done: @escaping (Result<Download, Error>) -> Void) {
        session.downloadTask(with: url) { temp, response, error in
            if let error {
                done(.failure(error))
                return
            }
            guard let temp, let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                done(.failure(LoadError.badResponse))
                return
            }
            if http.expectedContentLength > fileLimit {
                done(.failure(LoadError.tooLarge))
                return
            }
            // The system deletes `temp` when this returns.
            let kept = FileManager.default.temporaryDirectory.appendingPathComponent("Docket-download-\(UUID().uuidString)")
            do {
                try FileManager.default.moveItem(at: temp, to: kept)
            } catch {
                done(.failure(error))
                return
            }
            done(.success(Download(file: kept, mimeType: http.mimeType)))
        }.resume()
    }
}
