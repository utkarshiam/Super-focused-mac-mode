import Foundation
import MemoryKit

/// The Docket folder the user picked (usually iCloud Drive → Docket), kept as a security-scoped
/// bookmark so the app can reach it on every launch.
enum FolderBookmark {
    private static let defaultsKey = "docketFolderBookmark"

    /// Saves a bookmark for a folder the document picker just returned.
    static func save(_ url: URL) throws {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let data = try url.bookmarkData(options: .minimalBookmark, includingResourceValuesForKeys: nil, relativeTo: nil)
        UserDefaults.standard.set(data, forKey: defaultsKey)
    }

    /// The saved folder, with security-scoped access started (kept for the app's lifetime). Refreshes
    /// a stale bookmark.
    static func resolve() -> URL? {
        guard let data = UserDefaults.standard.data(forKey: defaultsKey) else { return nil }
        var stale = false
        guard let url = try? URL(resolvingBookmarkData: data, options: [], relativeTo: nil, bookmarkDataIsStale: &stale) else { return nil }
        _ = url.startAccessingSecurityScopedResource()
        if stale, let fresh = try? url.bookmarkData(options: .minimalBookmark, includingResourceValuesForKeys: nil, relativeTo: nil) {
            UserDefaults.standard.set(fresh, forKey: defaultsKey)
        }
        return url
    }

    static func clear() {
        UserDefaults.standard.removeObject(forKey: defaultsKey)
    }

    /// The bridge root inside a picked folder: the folder itself when it already looks like one (has
    /// Library/ or Inbox/), or its "Docket" subfolder when the user picked iCloud Drive itself.
    static func bridgeRoot(in picked: URL) -> URL {
        let fm = FileManager.default
        func looksLikeBridge(_ url: URL) -> Bool {
            fm.fileExists(atPath: url.appendingPathComponent("Library").path)
                || fm.fileExists(atPath: url.appendingPathComponent("Inbox").path)
        }
        if looksLikeBridge(picked) { return picked }
        let child = picked.appendingPathComponent("Docket", isDirectory: true)
        if looksLikeBridge(child) { return child }
        return picked
    }
}

/// File access that plays well with iCloud Drive: coordinated reads and writes, and downloads of
/// files that are only in the cloud. All of it blocks, so call it off the main thread.
enum CloudFiles {
    enum Availability: Equatable {
        /// On this iPhone and readable.
        case ready
        /// In iCloud; a download has been asked for.
        case downloading
        /// Not there at all.
        case missing
    }

    /// Whether `url` can be read now; asks iCloud for it when it can't.
    static func prepare(_ url: URL) -> Availability {
        let fm = FileManager.default
        let placeholder = url.deletingLastPathComponent().appendingPathComponent(".\(url.lastPathComponent).icloud")
        if fm.fileExists(atPath: url.path) {
            let keys: Set<URLResourceKey> = [.isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey]
            if let values = try? url.resourceValues(forKeys: keys), values.isUbiquitousItem == true,
               let status = values.ubiquitousItemDownloadingStatus, status != .current {
                try? fm.startDownloadingUbiquitousItem(at: url)
                // An older copy is on the phone: usable while the new one arrives.
                return status == .downloaded ? .ready : .downloading
            }
            return .ready
        }
        if fm.fileExists(atPath: placeholder.path) {
            try? fm.startDownloadingUbiquitousItem(at: url)
            return .downloading
        }
        return .missing
    }

    /// Reads `url` under a file coordinator (so iCloud isn't halfway through replacing it).
    static func read<T>(_ url: URL, _ body: (URL) throws -> T) throws -> T {
        var outcome: Result<T, Error>?
        var coordinationError: NSError?
        NSFileCoordinator(filePresenter: nil).coordinate(readingItemAt: url, options: [], error: &coordinationError) { actual in
            outcome = Result { try body(actual) }
        }
        if let coordinationError { throw coordinationError }
        guard let outcome else { throw CocoaError(.fileReadUnknown) }
        return try outcome.get()
    }

    /// Writes one or two files under a file coordinator.
    static func write(_ first: URL, _ second: URL?, _ body: () throws -> Void) throws {
        var outcome: Result<Void, Error>?
        var coordinationError: NSError?
        let coordinator = NSFileCoordinator(filePresenter: nil)
        if let second {
            coordinator.coordinate(writingItemAt: first, options: .forReplacing, writingItemAt: second, options: .forReplacing,
                                   error: &coordinationError) { _, _ in outcome = Result { try body() } }
        } else {
            coordinator.coordinate(writingItemAt: first, options: .forReplacing, error: &coordinationError) { _ in
                outcome = Result { try body() }
            }
        }
        if let coordinationError { throw coordinationError }
        guard let outcome else { throw CocoaError(.fileWriteUnknown) }
        try outcome.get()
    }

    /// Modification date, or nil when the file isn't there.
    static func modified(_ url: URL) -> Date? {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
    }
}
