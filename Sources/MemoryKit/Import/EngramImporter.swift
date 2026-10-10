import Foundation

/// Imports an ENGRAM export (Settings → Export in the ENGRAM app):
/// `{app: "ENGRAM", exportedAt, counts, entries: [KnowledgeEntry], entities: [Entity], relationships}`.
///
/// Each entry becomes a `MemoryItem` (origin `.engram`, sourceRef `engram:<id>`) keeping its date,
/// title, summary, key takeaways (as `keyTakeaways`), original content (as `body`) and source URL.
/// Entities aren't linked to entries in the export, so a person entity is added to an entry's people
/// when its name appears in the entry's text; organisations become projects; topics, concepts,
/// technologies and places become topics. Imported items are embedded only (they already have a
/// summary). Re-importing skips entries already in the library.
public enum EngramImporter {
    public struct Report: Equatable, Sendable {
        public var total = 0
        public var imported = 0
        /// Already in the library from an earlier import.
        public var skippedDuplicates = 0
        /// Entries without an id or any content.
        public var skippedEmpty = 0
        public var itemIDs: [UUID] = []
    }

    public enum ImportError: LocalizedError, Equatable {
        case notAnExport
        public var errorDescription: String? {
            "That file isn't an ENGRAM export. In ENGRAM, use Settings → Export and choose the .json file it makes."
        }
    }

    // MARK: Export format (ENGRAM types/index.ts)

    public struct Export: Decodable, Sendable {
        public var app: String?
        public var exportedAt: Date?
        public var entries: [Entry]
        public var entities: [Entity]

        private enum CodingKeys: String, CodingKey { case app, exportedAt, entries, entities }
        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            app = c.value(.app, default: nil)
            exportedAt = c.value(.exportedAt, default: nil)
            entries = (c.value(.entries, default: [Lenient<Entry>]())).compactMap(\.value)
            entities = (c.value(.entities, default: [Lenient<Entity>]())).compactMap(\.value)
        }
    }

    public struct Entry: Decodable, Sendable {
        public var id: String
        public var title: String
        public var summary: String
        public var originalContent: String
        public var sourceUrl: String?
        public var sourceApp: String?
        public var contentType: String
        public var keyTakeaways: [String]
        public var createdAt: Date?

        private enum CodingKeys: String, CodingKey {
            case id, title, summary, originalContent, sourceUrl, sourceApp, contentType, keyTakeaways, createdAt
        }
        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            // ids are strings in ENGRAM, but accept numbers too.
            if let s = try? c.decode(String.self, forKey: .id) { id = s }
            else if let n = try? c.decode(Int.self, forKey: .id) { id = String(n) }
            else { id = "" }
            title = c.value(.title, default: "")
            summary = c.value(.summary, default: "")
            originalContent = c.value(.originalContent, default: "")
            sourceUrl = c.value(.sourceUrl, default: nil)
            sourceApp = c.value(.sourceApp, default: nil)
            contentType = c.value(.contentType, default: "text")
            keyTakeaways = c.value(.keyTakeaways, default: [])
            createdAt = c.value(.createdAt, default: nil)
        }
    }

    public struct Entity: Decodable, Sendable {
        public var name: String
        public var type: String

        private enum CodingKeys: String, CodingKey { case name, type }
        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            name = c.value(.name, default: "")
            type = c.value(.type, default: "topic")
        }
    }

    /// Decodes an element or yields nil, so one bad entry doesn't sink the import.
    struct Lenient<T: Decodable>: Decodable {
        var value: T?
        init(from decoder: Decoder) throws { value = try? T(from: decoder) }
    }

    // MARK: Import

    public static func parse(_ data: Data) throws -> Export {
        guard let export = try? MemoryCoding.decoder.decode(Export.self, from: data),
              export.app?.uppercased() == "ENGRAM" || !export.entries.isEmpty else {
            throw ImportError.notAnExport
        }
        return export
    }

    /// Parses and imports. Throws `ImportError.notAnExport` for other files.
    @MainActor @discardableResult
    public static func importExport(_ data: Data, into library: MemoryLibrary, now: Date = Date()) throws -> Report {
        try importExport(parse(data), into: library, now: now)
    }

    @MainActor @discardableResult
    public static func importExport(_ export: Export, into library: MemoryLibrary, now: Date = Date()) -> Report {
        var report = Report(total: export.entries.count)
        let entities = export.entities.compactMap { e -> (name: String, bytes: [UInt8], type: String)? in
            let name = e.name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard name.count >= 3 else { return nil }
            return (name, Array(TextFold.fold(name).utf8), e.type.lowercased())
        }
        library.batch {
            for entry in export.entries {
                guard !entry.id.isEmpty else { report.skippedEmpty += 1; continue }
                let ref = SourceRef.engram(entry.id)
                if library.item(sourceRef: ref) != nil { report.skippedDuplicates += 1; continue }
                guard var item = makeItem(entry, now: now) else { report.skippedEmpty += 1; continue }

                let text = Array(TextFold.fold([item.title, item.summary, item.body, item.keyTakeaways.joined(separator: " ")]
                    .joined(separator: " | ")).utf8)
                var people: [String] = [], projects: [String] = [], topics: [String] = []
                for e in entities where MemorySearch.strength(e.bytes, in: text) == 3 {
                    switch e.type {
                    case "person": people.append(e.name)
                    case "organization", "organisation": projects.append(e.name)
                    default: topics.append(e.name)
                    }
                }
                item.people = TextFold.uniqueNames(people, limit: 20)
                item.projects = TextFold.uniqueNames(projects, limit: 10)
                item.topics = TextFold.uniqueNames(topics, limit: 8)
                let stored = library.add(item)
                report.imported += 1
                report.itemIDs.append(stored.id)
            }
        }
        return report
    }

    /// One entry as an item (people, projects and topics are filled by the caller). Nil when it has no content.
    static func makeItem(_ entry: Entry, now: Date) -> MemoryItem? {
        let content = entry.originalContent.trimmingCharacters(in: .whitespacesAndNewlines)
        // Media entries kept a local file:// path that means nothing on this device.
        let isLocalFile = content.hasPrefix("file://") || content.hasPrefix("/")
        let body = isLocalFile ? "" : content
        var url = entry.sourceUrl?.trimmingCharacters(in: .whitespacesAndNewlines)
        if url?.isEmpty ?? true, entry.contentType == "url", content.hasPrefix("http") { url = content }
        let title = entry.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let summary = entry.summary.trimmingCharacters(in: .whitespacesAndNewlines)
        let takeaways = entry.keyTakeaways.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        guard !(title.isEmpty && summary.isEmpty && body.isEmpty && takeaways.isEmpty && url == nil) else { return nil }

        let kind: MemoryKind = switch entry.contentType {
        case "url": .link
        case "text": .text
        case "image": .image
        case "video": .video
        case "audio": .audio
        case "document": .pdf
        case "file": .file
        default: .engram
        }
        let created = entry.createdAt ?? now
        return MemoryItem(kind: kind, origin: .engram, sourceRef: SourceRef.engram(entry.id), title: title, summary: summary,
                          body: body == url ? "" : body, keyTakeaways: takeaways, url: url,
                          capturedFrom: entry.sourceApp.flatMap { $0.isEmpty ? nil : "ENGRAM · \($0)" } ?? "ENGRAM",
                          createdAt: created, processing: .pending, lightweight: true)
    }
}
