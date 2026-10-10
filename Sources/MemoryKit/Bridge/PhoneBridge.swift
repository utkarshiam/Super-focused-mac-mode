import CryptoKit
import Foundation
import ImageIO

/// The phone ↔ Mac bridge through a shared folder (iCloud Drive), no server. Pure file operations on
/// `root`; no iCloud APIs. The iPhone app writes captures to `Inbox/` and reads `Library/`; the Mac
/// ingests `Inbox/` and publishes `Library/`.
///
/// ```
/// <root>/Inbox/      <uuid>.capture.json  (CaptureEnvelope; see its doc comment for the JSON)
///                    <uuid>--<original name>   the envelope's attachment, if any
///                    any other file            a capture of that file by itself ("Save to Files", Shortcuts)
/// <root>/Library/    snapshot.json        (LibrarySnapshot, compact JSON)
///                    vectors.bin          (VectorIndex binary; rewritten only when it changes)
///                    vectors.sha256       hex digest of vectors.bin, so unchanged vectors aren't re-uploaded
///                    Thumbs/<itemID>.jpg  (≤ 400 px JPEG of an item's first image)
/// ```
/// Inbox rules (Mac): hidden files and iCloud placeholders (`.name.icloud`) are skipped, and so is
/// anything modified less than 3 s ago (still being written or synced). An envelope whose attachment
/// hasn't arrived waits up to 10 minutes, then is ingested without it. An attachment whose envelope
/// hasn't arrived waits 10 minutes, then counts as a loose file. Ingested files are removed.
public struct PhoneBridge: Sendable {
    public let root: URL

    public init(root: URL) {
        self.root = root
    }

    public var inboxURL: URL { root.appendingPathComponent("Inbox", isDirectory: true) }
    public var libraryURL: URL { root.appendingPathComponent("Library", isDirectory: true) }
    public var snapshotURL: URL { libraryURL.appendingPathComponent("snapshot.json") }
    public var vectorsURL: URL { libraryURL.appendingPathComponent("vectors.bin") }
    var vectorsDigestURL: URL { libraryURL.appendingPathComponent("vectors.sha256") }
    public var thumbsURL: URL { libraryURL.appendingPathComponent("Thumbs", isDirectory: true) }

    public func thumbnailURL(for itemID: UUID) -> URL {
        thumbsURL.appendingPathComponent("\(itemID.uuidString).jpg")
    }

    /// Files younger than this are left alone (still being written or synced).
    public static let minimumAge: TimeInterval = 3
    /// How long half of a capture (envelope or attachment) waits for the other half.
    public static let pairingWait: TimeInterval = 10 * 60
    /// Longest side of a thumbnail, in pixels.
    public static let thumbnailPixels = 400
    /// Characters of an item's text in the snapshot.
    public static let snapshotTextLimit = 4000

    static let envelopeSuffix = ".capture.json"

    // MARK: Phone: writing captures

    /// Writes a capture (attachment first, envelope last, both atomically). `attachment` is copied;
    /// its name is used as `attachmentName` when the envelope has none. Returns the envelope's URL.
    @discardableResult
    public func writeCapture(_ envelope: CaptureEnvelope, attachment: URL? = nil) throws -> URL {
        var env = envelope
        if let attachment {
            if env.attachmentName == nil { env.attachmentName = attachment.lastPathComponent }
            try FileManager.default.createDirectory(at: inboxURL, withIntermediateDirectories: true)
            let target = inboxURL.appendingPathComponent(env.attachmentFileName!)
            try? FileManager.default.removeItem(at: target)
            try FileManager.default.copyItem(at: attachment, to: target)
        }
        return try writeEnvelope(env)
    }

    /// Writes a capture whose attachment is in memory (a photo just taken, a recording).
    @discardableResult
    public func writeCapture(_ envelope: CaptureEnvelope, attachmentData: Data, name: String) throws -> URL {
        var env = envelope
        env.attachmentName = name
        try FileManager.default.createDirectory(at: inboxURL, withIntermediateDirectories: true)
        try attachmentData.write(to: inboxURL.appendingPathComponent(env.attachmentFileName!), options: .atomic)
        return try writeEnvelope(env)
    }

    private func writeEnvelope(_ envelope: CaptureEnvelope) throws -> URL {
        try FileManager.default.createDirectory(at: inboxURL, withIntermediateDirectories: true)
        let url = inboxURL.appendingPathComponent(envelope.fileName)
        try MemoryCoding.encoder.encode(envelope).write(to: url, options: .atomic)
        return url
    }

    // MARK: Mac: reading the inbox

    /// Something in the inbox that's ready to ingest.
    public enum InboxEntry: Equatable, Sendable {
        /// An envelope, with its attachment when it has one and it has arrived.
        case capture(CaptureEnvelope, envelopeURL: URL, attachmentURL: URL?)
        /// A file dropped on its own.
        case looseFile(URL)
    }

    /// What's ready in the inbox now, oldest first. Unreadable envelopes are skipped (left in place).
    public func pendingEntries(now: Date = Date()) -> [InboxEntry] {
        let fm = FileManager.default
        let keys: [URLResourceKey] = [.contentModificationDateKey, .isDirectoryKey]
        guard let urls = try? fm.contentsOfDirectory(at: inboxURL, includingPropertiesForKeys: keys, options: []) else { return [] }
        func modified(_ url: URL) -> Date {
            (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
        }
        func settled(_ url: URL) -> Bool { now.timeIntervalSince(modified(url)) >= Self.minimumAge }

        var files: [URL] = []
        for url in urls {
            let name = url.lastPathComponent
            guard !name.hasPrefix("."), !name.hasSuffix(".icloud") else { continue }
            if (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true { continue }
            files.append(url)
        }
        let names = Set(files.map(\.lastPathComponent))
        var claimed = Set<String>()
        var entries: [(date: Date, entry: InboxEntry)] = []

        for url in files where url.lastPathComponent.hasSuffix(Self.envelopeSuffix) {
            guard settled(url), let data = try? Data(contentsOf: url),
                  let env = try? MemoryCoding.decoder.decode(CaptureEnvelope.self, from: data) else { continue }
            var attachment: URL?
            if let fileName = env.attachmentFileName {
                // Claimed even while waiting, so it isn't taken for a loose file.
                claimed.insert(fileName)
                let candidate = inboxURL.appendingPathComponent(fileName)
                if names.contains(fileName) {
                    guard settled(candidate) else { continue }
                    attachment = candidate
                } else if now.timeIntervalSince(modified(url)) < Self.pairingWait {
                    continue
                }
            }
            entries.append((env.createdAt, .capture(env, envelopeURL: url, attachmentURL: attachment)))
        }

        for url in files where !url.lastPathComponent.hasSuffix(Self.envelopeSuffix) && !claimed.contains(url.lastPathComponent) {
            guard settled(url) else { continue }
            // "<uuid>--name" belongs to an envelope that may still be syncing.
            if Self.envelopeID(fromAttachmentName: url.lastPathComponent) != nil,
               now.timeIntervalSince(modified(url)) < Self.pairingWait { continue }
            entries.append((modified(url), .looseFile(url)))
        }
        return entries.sorted { $0.date < $1.date }.map(\.entry)
    }

    /// The envelope id in "<uuid>--<name>", if the name has that shape.
    static func envelopeID(fromAttachmentName name: String) -> UUID? {
        guard let range = name.range(of: "--") else { return nil }
        return UUID(uuidString: String(name[..<range.lowerBound]))
    }

    /// What one ingest pass did.
    public struct IngestReport: Equatable, Sendable {
        /// Memory items created (or updated, for a link already saved).
        public var itemIDs: [UUID] = []
        /// Task envelopes (task, taskDone, taskUndone, taskDelete) handled by `handleTask`.
        public var tasksHandled = 0
        /// Voice envelopes handled by `handleVoice`.
        public var voiceHandled = 0
        /// Captures that couldn't be ingested (their files stay for another try), as sentences.
        public var problems: [String] = []
    }

    /// Ingests every ready capture into `library` and removes its files. Task envelopes go to
    /// `handleTask` (return true when applied; nil or false leaves them in the inbox for later).
    /// Voice envelopes go to `handleVoice` when it's given, with their recording (nil when it never came):
    /// it makes the tasks and the memory itself (it may move the recording into the library) and returns
    /// true when done; false leaves both files for a later pass (e.g. while Gemini works on it). Without
    /// `handleVoice` a voice capture becomes a plain audio memory.
    @MainActor @discardableResult
    public func ingest(into library: MemoryLibrary, now: Date = Date(),
                       handleTask: ((CaptureEnvelope) -> Bool)? = nil,
                       handleVoice: ((CaptureEnvelope, _ attachmentURL: URL?) -> Bool)? = nil) -> IngestReport {
        var report = IngestReport()
        let fm = FileManager.default
        for entry in pendingEntries(now: now) {
            switch entry {
            case .looseFile(let url):
                let fileName = url.lastPathComponent
                // "<uuid>--name" whose envelope never came: show "name".
                let name = Self.envelopeID(fromAttachmentName: fileName) != nil
                    ? String(fileName[fileName.range(of: "--")!.upperBound...]) : fileName
                let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? now
                do {
                    let item = try library.addFile(at: url, name: name, origin: .phone, capturedFrom: "Docket folder",
                                                   createdAt: date, move: true)
                    report.itemIDs.append(item.id)
                } catch {
                    report.problems.append("Couldn't import “\(name)”: \(error.localizedDescription)")
                }

            case .capture(let env, let envelopeURL, let attachmentURL):
                if env.kind.isTask {
                    guard let handleTask, handleTask(env) else { continue }
                    report.tasksHandled += 1
                    try? fm.removeItem(at: envelopeURL)
                    if let attachmentURL { try? fm.removeItem(at: attachmentURL) }
                    continue
                }
                if env.kind == .voice, let handleVoice {
                    guard handleVoice(env, attachmentURL) else { continue }
                    report.voiceHandled += 1
                    try? fm.removeItem(at: envelopeURL)
                    if let attachmentURL, fm.fileExists(atPath: attachmentURL.path) { try? fm.removeItem(at: attachmentURL) }
                    continue
                }
                if let existing = library.item(sourceRef: SourceRef.phone(env.id)) {
                    // Already ingested (the files came back from a sync conflict): just clean up.
                    report.itemIDs.append(existing.id)
                } else {
                    do {
                        let item = try makeItem(env, attachmentURL: attachmentURL, library: library)
                        report.itemIDs.append(item.id)
                    } catch {
                        report.problems.append("Couldn't import a capture from \(MemoryDates.label(env.createdAt, now: now)): \(error.localizedDescription)")
                        continue
                    }
                }
                try? fm.removeItem(at: envelopeURL)
                if let attachmentURL, fm.fileExists(atPath: attachmentURL.path) { try? fm.removeItem(at: attachmentURL) }
            }
        }
        return report
    }

    @MainActor
    private func makeItem(_ env: CaptureEnvelope, attachmentURL: URL?, library: MemoryLibrary) throws -> MemoryItem {
        let from = env.device?.isEmpty == false ? env.device! : "iPhone"
        let title = env.title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let text = env.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let ref = SourceRef.phone(env.id)

        if env.kind == .link, let url = env.url, !url.isEmpty {
            return library.addLink(url, note: text, title: title, origin: .phone, capturedFrom: from, createdAt: env.createdAt)
        }
        let ext = (env.attachmentName.map { ($0 as NSString).pathExtension }) ?? ""
        if let attachmentURL {
            let kind: MemoryKind = switch env.kind {
            case .photo: .image
            case .voice: .audio
            default: MemoryKind.forFile(extension: ext)
            }
            return try library.addFile(at: attachmentURL, kind: kind, name: env.attachmentName, title: title, note: text,
                                       origin: .phone, sourceRef: ref, capturedFrom: from, createdAt: env.createdAt, move: true)
        }
        // A note, or a capture whose attachment never arrived: keep what there is.
        let kind: MemoryKind = env.kind == .note ? .note : env.kind == .voice ? .audio : env.kind == .photo ? .image : .note
        return library.add(MemoryItem(kind: kind, origin: .phone, sourceRef: ref, title: title, body: text,
                                      url: env.url, capturedFrom: from, createdAt: env.createdAt))
    }

    // MARK: Mac: publishing the library

    /// Builds the snapshot from the library and writes it with vectors and thumbnails (the file work
    /// runs off the main actor). `tasks` are the open tasks the phone should show (overdue, today,
    /// next 7 days, and recent ones from voice notes); `listNames` the user's task lists, so a debrief made
    /// on the phone can file tasks; `brain` adds the organised brain (`BrainSnapshot`). Debounce calls (e.g. on
    /// `library.changes` and `brain.changes`).
    @MainActor
    public func publish(_ library: MemoryLibrary, tasks: [TaskSnapshot], listNames: [String] = [], now: Date = Date(),
                        itemLimit: Int? = nil, brain: MemoryBrain? = nil) async throws {
        let snapshot = Self.makeSnapshot(library, tasks: tasks, listNames: listNames, now: now, itemLimit: itemLimit, brain: brain)
        let vectors = library.vectors
        // Thumbnails for items whose first image attachment is on disk.
        var images: [(UUID, URL)] = []
        for item in snapshot.items {
            if let image = item.attachments.first(where: \.isImage) { images.append((item.id, library.fileURL(for: image, of: item.id))) }
        }
        let bridge = self
        try await Task.detached(priority: .utility) {
            try bridge.writeSnapshot(snapshot, vectors: vectors)
            bridge.syncThumbnails(images)
        }.value
    }

    /// The snapshot for the phone: items newest first with text capped, profile, lenses, tasks, list names, and
    /// the brain when given.
    @MainActor
    public static func makeSnapshot(_ library: MemoryLibrary, tasks: [TaskSnapshot], listNames: [String] = [], now: Date = Date(),
                                    itemLimit: Int? = nil, brain: MemoryBrain? = nil) -> LibrarySnapshot {
        let source = itemLimit.map { Array(library.items.prefix($0)) } ?? library.items
        let items = source.map { item -> MemoryItem in
            var copy = item
            copy.body = TextFold.cap(item.body, snapshotTextLimit)
            copy.extractedText = TextFold.cap(item.extractedText, max(0, snapshotTextLimit - copy.body.count))
            return copy
        }
        let vectors = library.vectors
        return LibrarySnapshot(generatedAt: now, items: items, profile: library.profile, lenses: library.lenses, tasks: tasks,
                               embeddingModel: vectors.model, embeddingDimensions: vectors.dimensions, listNames: listNames,
                               brain: brain?.snapshot(itemIDs: Set(items.map(\.id))))
    }

    /// Writes snapshot.json, and vectors.bin when its content changed.
    public func writeSnapshot(_ snapshot: LibrarySnapshot, vectors: VectorIndex?) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: libraryURL, withIntermediateDirectories: true)
        try MemoryCoding.compactEncoder.encode(snapshot).write(to: snapshotURL, options: .atomic)
        guard let vectors else { return }
        let data = vectors.encoded()
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        let previous = try? String(contentsOf: vectorsDigestURL, encoding: .utf8)
        guard previous != digest || !fm.fileExists(atPath: vectorsURL.path) else { return }
        try data.write(to: vectorsURL, options: .atomic)
        try digest.write(to: vectorsDigestURL, atomically: true, encoding: .utf8)
    }

    /// Makes missing or outdated thumbnails and removes ones for items that are gone.
    public func syncThumbnails(_ images: [(itemID: UUID, source: URL)]) {
        let fm = FileManager.default
        try? fm.createDirectory(at: thumbsURL, withIntermediateDirectories: true)
        var wanted = Set<String>()
        for (id, source) in images {
            let target = thumbnailURL(for: id)
            wanted.insert(target.lastPathComponent)
            let sourceDate = (try? source.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            let targetDate = (try? target.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            guard targetDate < sourceDate || !fm.fileExists(atPath: target.path) else { continue }
            if let data = Self.thumbnail(from: source) { try? data.write(to: target, options: .atomic) }
        }
        for url in (try? fm.contentsOfDirectory(at: thumbsURL, includingPropertiesForKeys: nil)) ?? []
        where url.pathExtension == "jpg" && !wanted.contains(url.lastPathComponent) {
            try? fm.removeItem(at: url)
        }
    }

    // MARK: Phone: reading the library

    /// The Mac's latest snapshot, or nil when there isn't one yet. Throws when it can't be read.
    public func readSnapshot() throws -> LibrarySnapshot? {
        guard FileManager.default.fileExists(atPath: snapshotURL.path) else { return nil }
        return try MemoryCoding.decoder.decode(LibrarySnapshot.self, from: Data(contentsOf: snapshotURL))
    }

    /// The published vectors, or nil.
    public func readVectors() -> VectorIndex? {
        guard let data = try? Data(contentsOf: vectorsURL) else { return nil }
        return try? VectorIndex(data: data)
    }

    // MARK: Helpers

    /// A JPEG at most `maxPixels` on its longest side (orientation applied), or nil when it isn't an image.
    public static func thumbnail(from url: URL, maxPixels: Int = thumbnailPixels, quality: Double = 0.75) -> Data? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixels,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data as CFMutableData, "public.jpeg" as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }

    /// A name safe to use as a file name: no slashes, colons or control characters, at most 120
    /// characters (extension kept), never empty.
    public static func safeFileName(_ name: String) -> String {
        let bad = CharacterSet(charactersIn: "/\\:").union(.controlCharacters).union(.newlines)
        var s = name.components(separatedBy: bad).joined(separator: "-").trimmingCharacters(in: .whitespaces)
        while s.hasPrefix(".") { s.removeFirst() }
        if s.count > 120 {
            let ext = (s as NSString).pathExtension
            let base = String((s as NSString).deletingPathExtension.prefix(ext.isEmpty ? 120 : 110))
            s = ext.isEmpty ? base : base + "." + ext
        }
        return s.isEmpty ? "file" : s
    }
}
