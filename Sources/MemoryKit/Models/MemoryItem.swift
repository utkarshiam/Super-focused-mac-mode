import Foundation

// MARK: - Kind

/// What a memory is. Unknown raw values (from a newer app) decode as `.note`. `.task` is only read back from
/// libraries of earlier versions: tasks aren't captured as memories any more.
public enum MemoryKind: String, Codable, CaseIterable, Identifiable, Sendable {
    case note, text, link, image, video, audio, pdf, file, task, message, engram

    public var id: String { rawValue }

    /// Singular, for labels and filters ("Voice note", not "audio").
    public var label: String {
        switch self {
        case .note: "Note"
        case .text: "Text"
        case .link: "Link"
        case .image: "Image"
        case .video: "Video"
        case .audio: "Voice note"
        case .pdf: "PDF"
        case .file: "File"
        case .task: "Task"
        case .message: "Message"
        case .engram: "From ENGRAM"
        }
    }

    /// An SF Symbol name; both apps draw it with SwiftUI.
    public var symbolName: String {
        switch self {
        case .note: "note.text"
        case .text: "text.alignleft"
        case .link: "link"
        case .image: "photo"
        case .video: "film"
        case .audio: "waveform"
        case .pdf: "doc.richtext"
        case .file: "doc"
        case .task: "checkmark.circle"
        case .message: "bubble.left.and.bubble.right"
        case .engram: "brain"
        }
    }

    /// Kinds whose content lives in an attachment Gemini has to look at or listen to.
    public var isMedia: Bool { [.image, .video, .audio, .pdf].contains(self) }

    /// The kind for a file, by extension ("jpg" → image, "m4a" → audio, "pdf" → pdf, else file).
    public static func forFile(extension ext: String) -> MemoryKind {
        switch ext.lowercased() {
        case "jpg", "jpeg", "png", "heic", "heif", "gif", "webp", "tif", "tiff", "bmp": .image
        case "mov", "mp4", "m4v", "avi", "webm": .video
        case "m4a", "mp3", "wav", "aac", "caf", "aiff", "aif", "ogg", "flac", "opus": .audio
        case "pdf": .pdf
        default: .file
        }
    }

    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = MemoryKind(rawValue: raw) ?? .note
    }
}

// MARK: - Origin

/// How a memory got in. Unknown raw values decode as `.manual`.
public enum MemoryOrigin: String, Codable, CaseIterable, Sendable {
    /// The user saved it (capture panel, drag and drop, "Remember").
    case manual
    /// Docket captured it on its own (a note, a thread summary, a sent reply).
    case auto
    /// Came in through the phone bridge's Inbox folder.
    case phone
    /// Imported from an ENGRAM export.
    case engram

    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = MemoryOrigin(rawValue: raw) ?? .manual
    }
}

// MARK: - Processing state

/// Where an item is in AI processing. Persisted, so pending items resume after a relaunch.
/// While an item is actually being worked on, `MemoryProcessor.runningIDs` contains it.
///
/// JSON: `{"state": "pending" | "processed" | "skipped" | "failed", "message": "…"}` (message only for failed).
public enum ProcessingState: Hashable, Codable, Sendable {
    /// Waiting for AI (or for the network to come back).
    case pending
    /// Summary, moments and vector are in.
    case processed
    /// AI couldn't handle it; the message is a full sentence for the user. "Retry" sets it back to pending.
    case failed(String)
    /// No Gemini key: saved and searchable by text. Processed automatically once a key is added.
    case skipped

    public var isPending: Bool { self == .pending }
    public var isFailed: Bool { if case .failed = self { return true }; return false }
    public var failureMessage: String? { if case .failed(let m) = self { return m }; return nil }

    private enum CodingKeys: String, CodingKey { case state, message }

    public init(from decoder: Decoder) throws {
        // Also accept a bare string ("processed"), the simplest thing a hand edit would write.
        if let raw = try? decoder.singleValueContainer().decode(String.self) {
            self = Self.make(raw, message: nil)
            return
        }
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self = Self.make(c.value(.state, default: "pending"), message: c.value(.message, default: nil))
    }

    private static func make(_ raw: String, message: String?) -> ProcessingState {
        switch raw {
        case "processed": .processed
        case "skipped": .skipped
        case "failed": .failed(message ?? "Processing failed.")
        default: .pending
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .pending: try c.encode("pending", forKey: .state)
        case .processed: try c.encode("processed", forKey: .state)
        case .skipped: try c.encode("skipped", forKey: .state)
        case .failed(let message):
            try c.encode("failed", forKey: .state)
            try c.encode(message, forKey: .message)
        }
    }
}

// MARK: - Attachment

/// A file kept with a memory. The bytes live at `<library>/Files/<itemID>/<fileName>`
/// (`MemoryLibrary.fileURL(for:of:)`); `name` is what the user called it.
public struct MemoryAttachment: Identifiable, Hashable, Codable, Sendable {
    public var id: UUID
    /// The original name, shown to the user ("Pitch v3.pdf").
    public var name: String
    /// The name on disk inside the item's folder (unique within the item).
    public var fileName: String
    /// A MIME type ("image/jpeg", "application/pdf"); "application/octet-stream" when unknown.
    public var mimeType: String
    public var byteCount: Int
    public var addedAt: Date

    public init(id: UUID = UUID(), name: String, fileName: String, mimeType: String, byteCount: Int, addedAt: Date = Date()) {
        self.id = id
        self.name = name
        self.fileName = fileName
        self.mimeType = mimeType
        self.byteCount = byteCount
        self.addedAt = addedAt
    }

    private enum CodingKeys: String, CodingKey { case id, name, fileName, mimeType, byteCount, addedAt }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = c.value(.id, default: UUID())
        name = c.value(.name, default: "File")
        fileName = c.value(.fileName, default: name)
        mimeType = c.value(.mimeType, default: MimeType.fallback)
        byteCount = c.value(.byteCount, default: 0)
        addedAt = c.value(.addedAt, default: Date())
    }

    public var isImage: Bool { mimeType.hasPrefix("image/") }
}

/// MIME types by file extension, enough for what people capture.
public enum MimeType {
    public static let fallback = "application/octet-stream"

    public static func forExtension(_ ext: String) -> String {
        switch ext.lowercased() {
        case "jpg", "jpeg": "image/jpeg"
        case "png": "image/png"
        case "heic": "image/heic"
        case "heif": "image/heif"
        case "gif": "image/gif"
        case "webp": "image/webp"
        case "tif", "tiff": "image/tiff"
        case "bmp": "image/bmp"
        case "pdf": "application/pdf"
        case "m4a": "audio/mp4"
        case "mp3": "audio/mpeg"
        case "wav": "audio/wav"
        case "aac", "adts": "audio/aac"
        case "caf": "audio/x-caf"
        case "aif", "aiff": "audio/aiff"
        case "ogg", "opus": "audio/ogg"
        case "flac": "audio/flac"
        case "mov": "video/quicktime"
        case "mp4", "m4v": "video/mp4"
        case "webm": "video/webm"
        case "avi": "video/x-msvideo"
        case "txt", "text": "text/plain"
        case "md", "markdown": "text/markdown"
        case "csv": "text/csv"
        case "json": "application/json"
        case "html", "htm": "text/html"
        case "rtf": "text/rtf"
        default: fallback
        }
    }

    /// Types whose content is plain text Docket can read itself.
    public static func isPlainText(_ mime: String) -> Bool {
        mime.hasPrefix("text/") && mime != "text/html" && mime != "text/rtf" || mime == "application/json"
    }

    /// Types Gemini accepts as inline data: images, PDF, audio, video.
    public static func isInlineable(_ mime: String) -> Bool {
        mime.hasPrefix("image/") || mime.hasPrefix("audio/") || mime.hasPrefix("video/") || mime == "application/pdf"
    }

    /// Audio types as Gemini names them. Gemini lists audio/wav, mp3, aiff, aac, ogg, flac, mpeg, m4a, l16,
    /// opus, alaw, mulaw and webm (ai.google.dev/gemini-api/docs/audio), so the standard name for an .m4a
    /// (AAC in an MPEG-4 container), "audio/mp4", and its aliases are sent as "audio/m4a". Other types pass
    /// through unchanged.
    public static func forGemini(_ mime: String) -> String {
        switch mime.lowercased() {
        case "audio/mp4", "audio/x-m4a", "audio/m4a", "audio/mp4a-latm", "audio/aacp": "audio/m4a"
        case "audio/x-wav", "audio/wave", "audio/vnd.wave": "audio/wav"
        case "audio/x-aiff", "audio/aif": "audio/aiff"
        case "audio/x-aac": "audio/aac"
        case "audio/x-flac": "audio/flac"
        case "audio/mp3", "audio/x-mp3", "audio/mpeg3": "audio/mp3"
        default: mime
        }
    }
}

// MARK: - Moment

/// One of the four things worth remembering inside an item. Promises carry who, when and which way.
public enum MomentKind: String, Codable, CaseIterable, Identifiable, Sendable {
    case decision, promise, idea, insight
    public var id: String { rawValue }

    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = MomentKind(rawValue: raw) ?? .insight
    }
}

/// Which way a promise points.
public enum PromiseDirection: String, Codable, CaseIterable, Sendable {
    /// The user promised it ("I'll send the deck by Friday").
    case mine
    /// Someone promised it to the user ("Priya will share the numbers").
    case theirs

    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = PromiseDirection(rawValue: raw) ?? .mine
    }
}

public struct Moment: Identifiable, Hashable, Codable, Sendable {
    public var id: UUID
    public var kind: MomentKind
    /// One self-contained sentence ("Ship the pricing page before the 14 Nov launch").
    public var text: String
    /// Who decided / promised / had the idea, when it isn't the user.
    public var who: String?
    /// For promises: when it's due (a day; local midnight).
    public var due: Date?
    /// For promises.
    public var direction: PromiseDirection?
    /// The user ticked it off (promises), kept across re-processing.
    public var done: Bool

    public init(id: UUID = UUID(), kind: MomentKind, text: String, who: String? = nil, due: Date? = nil,
                direction: PromiseDirection? = nil, done: Bool = false) {
        self.id = id
        self.kind = kind
        self.text = text
        self.who = who
        self.due = due
        self.direction = direction
        self.done = done
    }

    private enum CodingKeys: String, CodingKey { case id, kind, text, who, due, direction, done }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = c.value(.id, default: UUID())
        kind = c.value(.kind, default: .insight)
        text = c.value(.text, default: "")
        who = c.value(.who, default: nil)
        due = c.value(.due, default: nil)
        direction = c.value(.direction, default: nil)
        done = c.value(.done, default: false)
    }
}

// MARK: - Item

/// Anything remembered. Value type; `MemoryLibrary` owns the list.
///
/// JSON (inside memory.json and the phone snapshot): every property below by name, dates ISO 8601,
/// `processing` as described on `ProcessingState`. Every key is optional when reading.
public struct MemoryItem: Identifiable, Hashable, Codable, Sendable {
    public var id: UUID
    public var kind: MemoryKind
    public var origin: MemoryOrigin
    /// Where it came from, for dedupe and linking back; see `SourceRef`. Unique within a library.
    public var sourceRef: String?

    /// Shown as the headline. AI fills it when the user left it empty.
    public var title: String
    /// One or two sentences by AI (or ENGRAM).
    public var summary: String
    /// What the user wrote or captured: note text, a message thread, a caption.
    public var body: String
    /// What Docket pulled out of it: a link's readable page text, a voice note's transcript, a
    /// description of an image or PDF. Replaced on every processing run; never the user's words.
    public var extractedText: String
    public var keyTakeaways: [String]
    /// The web address for links (and anything else that has one).
    public var url: String?
    /// The page's preview image (og:image) for links.
    public var imageURL: String?
    /// Free text about where it was captured ("Slack · #design", "Gmail", "iPhone").
    public var capturedFrom: String?

    public var people: [String]
    public var projects: [String]
    /// Companies, funds, institutions and teams named in it ("Harbor Capital", "Mehta Traders").
    public var organisations: [String]
    public var topics: [String]
    /// The user's own tags plus AI's (lowercase, no "#").
    public var tags: [String]
    public var moments: [Moment]
    public var attachments: [MemoryAttachment]

    public var pinned: Bool
    /// When it happened / was saved. Drives "on this day" and sorting.
    public var createdAt: Date
    public var updatedAt: Date
    /// Last opened in a detail view (for "worth revisiting").
    public var lastViewedAt: Date?

    public var processing: ProcessingState
    public var processedAt: Date?
    /// Failed AI attempts so far (reset on success).
    public var attempts: Int
    /// Embed only, no extraction call: ENGRAM imports (which already have a summary).
    public var lightweight: Bool

    public init(id: UUID = UUID(), kind: MemoryKind = .note, origin: MemoryOrigin = .manual, sourceRef: String? = nil,
                title: String = "", summary: String = "", body: String = "", extractedText: String = "", keyTakeaways: [String] = [],
                url: String? = nil, imageURL: String? = nil, capturedFrom: String? = nil,
                people: [String] = [], projects: [String] = [], organisations: [String] = [], topics: [String] = [], tags: [String] = [],
                moments: [Moment] = [], attachments: [MemoryAttachment] = [], pinned: Bool = false,
                createdAt: Date = Date(), updatedAt: Date? = nil, lastViewedAt: Date? = nil,
                processing: ProcessingState = .pending, processedAt: Date? = nil, attempts: Int = 0,
                lightweight: Bool = false) {
        self.id = id
        self.kind = kind
        self.origin = origin
        self.sourceRef = sourceRef
        self.title = title
        self.summary = summary
        self.body = body
        self.extractedText = extractedText
        self.keyTakeaways = keyTakeaways
        self.url = url
        self.imageURL = imageURL
        self.capturedFrom = capturedFrom
        self.people = people
        self.projects = projects
        self.organisations = organisations
        self.topics = topics
        self.tags = tags
        self.moments = moments
        self.attachments = attachments
        self.pinned = pinned
        self.createdAt = createdAt
        self.updatedAt = updatedAt ?? createdAt
        self.lastViewedAt = lastViewedAt
        self.processing = processing
        self.processedAt = processedAt
        self.attempts = attempts
        self.lightweight = lightweight
    }

    private enum CodingKeys: String, CodingKey {
        case id, kind, origin, sourceRef, title, summary, body, extractedText, keyTakeaways, url, imageURL, capturedFrom
        case people, projects, organisations, topics, tags, moments, attachments, pinned, createdAt, updatedAt, lastViewedAt
        case processing, processedAt, attempts, lightweight
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = c.value(.id, default: UUID())
        kind = c.value(.kind, default: .note)
        origin = c.value(.origin, default: .manual)
        sourceRef = c.value(.sourceRef, default: nil)
        title = c.value(.title, default: "")
        summary = c.value(.summary, default: "")
        body = c.value(.body, default: "")
        extractedText = c.value(.extractedText, default: "")
        keyTakeaways = c.value(.keyTakeaways, default: [])
        url = c.value(.url, default: nil)
        imageURL = c.value(.imageURL, default: nil)
        capturedFrom = c.value(.capturedFrom, default: nil)
        people = c.value(.people, default: [])
        projects = c.value(.projects, default: [])
        organisations = c.value(.organisations, default: [])
        topics = c.value(.topics, default: [])
        tags = c.value(.tags, default: [])
        moments = c.value(.moments, default: [])
        attachments = c.value(.attachments, default: [])
        pinned = c.value(.pinned, default: false)
        createdAt = c.value(.createdAt, default: Date())
        updatedAt = c.value(.updatedAt, default: createdAt)
        lastViewedAt = c.value(.lastViewedAt, default: nil)
        processing = c.value(.processing, default: .pending)
        processedAt = c.value(.processedAt, default: nil)
        attempts = c.value(.attempts, default: 0)
        lightweight = c.value(.lightweight, default: false)
    }
}

extension MemoryItem {
    /// The title, or the first line of the body, or the URL's host, or the kind.
    public var displayTitle: String {
        let t = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !t.isEmpty { return t }
        if let line = body.split(whereSeparator: \.isNewline).first(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }) {
            return TextFold.cap(line.trimmingCharacters(in: .whitespaces), 80)
        }
        if let url, let host = URL(string: url)?.host { return host }
        if let file = attachments.first { return file.name }
        return kind.label
    }

    /// The user's text followed by the extracted text, for reading and quoting.
    public var fullText: String {
        let a = body.trimmingCharacters(in: .whitespacesAndNewlines)
        let b = extractedText.trimmingCharacters(in: .whitespacesAndNewlines)
        return a.isEmpty ? b : b.isEmpty ? a : a + "\n\n" + b
    }

    /// Promises that aren't done, soonest due first (undated last).
    public var openPromises: [Moment] {
        moments.filter { $0.kind == .promise && !$0.done }
            .sorted { ($0.due ?? .distantFuture) < ($1.due ?? .distantFuture) }
    }

    /// What gets embedded: the headline facts, not the whole body (which only adds noise past a point).
    public var embeddingText: String {
        var lines = [displayTitle]
        if !summary.isEmpty { lines.append(summary) }
        if !keyTakeaways.isEmpty { lines.append(keyTakeaways.map { "- \($0)" }.joined(separator: "\n")) }
        if !people.isEmpty { lines.append("People: " + people.joined(separator: ", ")) }
        if !projects.isEmpty { lines.append("Projects: " + projects.joined(separator: ", ")) }
        if !organisations.isEmpty { lines.append("Organisations: " + organisations.joined(separator: ", ")) }
        if !topics.isEmpty { lines.append("Topics: " + topics.joined(separator: ", ")) }
        if summary.isEmpty && keyTakeaways.isEmpty {
            // Not extracted (lightweight, or extraction failed): the start of the text carries the meaning.
            let text = fullText
            if !text.isEmpty { lines.append(TextFold.cap(text, 2000)) }
        }
        return lines.joined(separator: "\n")
    }
}
