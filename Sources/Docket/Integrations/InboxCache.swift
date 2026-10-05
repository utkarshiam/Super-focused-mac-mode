import CoreServices
import CryptoKit
import Foundation
import UniformTypeIdentifiers

/// Attachments of Slack messages and emails, downloaded for Quick Look and kept in the data folder's
/// IntegrationCache/ (apart from the notes' attachments/).
///
/// Each file sits in a folder named by a hash of its message id and attachment id, under its own cleaned-up
/// name, so Quick Look, Finder and Save show the real name. Files are only previewed or opened, never run:
/// they're written without execute permission, readable by the user alone, and marked as downloaded, so
/// macOS checks one like any other download before opening it.
enum InboxCache {
    static let folderName = "IntegrationCache"
    /// The folder stays under this size: the files used longest ago go first.
    static let maxBytes = 300 * 1024 * 1024
    /// A file whose message has left the inbox is kept this long after it was last used.
    static let keepGone: TimeInterval = 7 * 86_400
    /// Bigger files aren't downloaded; they're opened in Slack or Gmail instead.
    static let largestFile = 100 * 1024 * 1024

    /// 32 hex characters naming the attachment's folder: a hash of the message id and the attachment id.
    static func key(messageID: String, attachmentID: String) -> String {
        // The newline keeps ("ab", "c") and ("a", "bc") apart; neither kind of id contains one.
        let digest = SHA256.hash(data: Data("\(messageID)\n\(attachmentID)".utf8))
        return digest.prefix(16).map { String(format: "%02x", $0) }.joined()
    }

    /// Where the attachment is kept: IntegrationCache/<key>/<name>.
    static func location(for attachment: MessageAttachment, key: String, in root: URL) -> URL {
        root.appendingPathComponent(key, isDirectory: true).appendingPathComponent(fileName(for: attachment), isDirectory: false)
    }

    /// The attachment's name, safe as a file name: no folders, control characters or leading dots, a
    /// sensible length, and an extension that tells Quick Look the type.
    static func fileName(for attachment: MessageAttachment) -> String {
        var name = attachment.name.components(separatedBy: .controlCharacters).joined()
        // ":" shows as "/" in Finder; "\" is a separator elsewhere.
        for separator in ["/", ":", "\\"] { name = name.replacingOccurrences(of: separator, with: "-") }
        name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        while name.hasPrefix(".") { name = String(name.dropFirst()).trimmingCharacters(in: .whitespaces) }
        if name.isEmpty { name = attachment.isImage ? "Image" : "Attachment" }

        var ext = (name as NSString).pathExtension
        var base = (name as NSString).deletingPathExtension
        // "Q3 plan.final draft" or a 300-character tail isn't an extension: one from the type instead.
        if ext.isEmpty || ext.utf8.count > 16 || ext.contains(" ") {
            base = name
            ext = UTType(mimeType: attachment.mimeType)?.preferredFilenameExtension ?? ""
        }
        // File names can be 255 bytes; well under that leaves room for anything that copies the file.
        let room = 200 - (ext.isEmpty ? 0 : ext.utf8.count + 1)
        while base.utf8.count > room, !base.isEmpty { base.removeLast() }
        base = base.trimmingCharacters(in: .whitespaces)
        if base.isEmpty { base = attachment.isImage ? "Image" : "Attachment" }
        return ext.isEmpty ? base : "\(base).\(ext)"
    }

    /// Whether the file is there. Marks it as just used, so a full cache lets it go last.
    static func isCached(_ url: URL, now: Date = Date()) -> Bool {
        guard FileManager.default.fileExists(atPath: url.path) else { return false }
        try? FileManager.default.setAttributes([.modificationDate: now], ofItemAtPath: url.path)
        return true
    }

    /// Writes a downloaded file into the cache, off the main thread.
    static func write(_ data: Data, to url: URL) async throws {
        try await Task.detached(priority: .userInitiated) {
            let fm = FileManager.default
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
                                   attributes: [.posixPermissions: 0o700])
            try data.write(to: url, options: .atomic)
            try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            markDownloaded(url)
        }.value
    }

    /// Quarantined, as a browser marks its downloads: Gatekeeper checks the file before anything opens it.
    private static func markDownloaded(_ url: URL) {
        var url = url
        var values = URLResourceValues()
        values.quarantineProperties = [kLSQuarantineTypeKey as String: kLSQuarantineTypeOtherDownload as String,
                                       kLSQuarantineAgentNameKey as String: "Docket"]
        try? url.setResourceValues(values)
    }

    /// Slack's own file addresses (HTTPS, a Slack host, nothing else in the authority): the token only ever
    /// goes to Slack.
    static func isSlackFile(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == "https", url.user == nil, url.password == nil,
              url.port == nil || url.port == 443, let host = url.host?.lowercased() else { return false }
        return ["slack.com", "slack-gov.com"].contains { host == $0 || host.hasSuffix("." + $0) }
    }

    /// "This file is 240 MB, too big to open in Docket. Open it in Slack."
    static func tooBig(_ bytes: Int, _ service: IntegrationError.Service) -> IntegrationError {
        let size = ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
        let place = service == .slack ? "Slack" : "Gmail"
        return .api(service, "This file is \(size), too big to open in Docket. Open it in \(place).")
    }

    // MARK: Cleaning up

    /// One cached attachment: its folder (or a stray file), how big it is and when it was last used.
    struct Entry: Equatable {
        var key: String
        var url: URL
        var bytes: Int
        var used: Date
    }

    static func entries(in root: URL) -> [Entry] {
        let fm = FileManager.default
        let keys: [URLResourceKey] = [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey]
        guard let items = try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]) else { return [] }
        return items.map { item in
            let values = try? item.resourceValues(forKeys: Set(keys))
            var bytes = values?.fileSize ?? 0
            var used = values?.contentModificationDate ?? .distantPast
            if values?.isDirectory == true {
                let files = (try? fm.contentsOfDirectory(at: item, includingPropertiesForKeys: keys, options: [])) ?? []
                let found = files.compactMap { try? $0.resourceValues(forKeys: Set(keys)) }
                bytes = found.reduce(0) { $0 + ($1.fileSize ?? 0) }
                used = found.compactMap(\.contentModificationDate).max() ?? used
            }
            return Entry(key: item.deletingPathExtension().lastPathComponent, url: item, bytes: bytes, used: used)
        }
    }

    /// Removes the files of messages that are gone (`live` lists the keys still in the inbox) once they've
    /// gone unused for a week, then the least recently used until the folder fits in `maxBytes`. `keep`
    /// is never removed (a file being handed out right now). Returns the keys removed.
    @discardableResult
    static func prune(_ root: URL, live: Set<String>, keep: Set<String> = [], now: Date = Date(), maxBytes: Int = maxBytes) -> [String] {
        let fm = FileManager.default
        var remaining: [Entry] = []
        var removed: [String] = []
        for entry in entries(in: root) {
            if !live.contains(entry.key), !keep.contains(entry.key), now.timeIntervalSince(entry.used) > keepGone {
                try? fm.removeItem(at: entry.url)
                removed.append(entry.key)
            } else {
                remaining.append(entry)
            }
        }
        var total = remaining.reduce(0) { $0 + $1.bytes }
        for entry in remaining.sorted(by: { $0.used < $1.used }) where total > maxBytes && !keep.contains(entry.key) {
            try? fm.removeItem(at: entry.url)
            removed.append(entry.key)
            total -= entry.bytes
        }
        return removed
    }

    /// Forgets these attachments now (their messages were cleared).
    static func remove(_ keys: Set<String>, in root: URL) {
        for entry in entries(in: root) where keys.contains(entry.key) {
            try? FileManager.default.removeItem(at: entry.url)
        }
    }
}
