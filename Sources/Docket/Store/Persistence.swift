import Foundation

/// Reads and writes the single JSON database file, with daily rolling backups.
struct Persistence: Sendable {
    let directory: URL

    var fileURL: URL { directory.appendingPathComponent("docket.json") }
    var backupsURL: URL { directory.appendingPathComponent("Backups", isDirectory: true) }
    /// How a data file that couldn't be read is renamed when it's set aside.
    private static let unreadablePrefix = "docket.unreadable-"

    static var defaultDirectory: URL {
        if let override = ProcessInfo.processInfo.environment["DOCKET_DATA_DIR"], !override.isEmpty {
            return URL(fileURLWithPath: (override as NSString).expandingTildeInPath, isDirectory: true)
        }
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return base.appendingPathComponent("Docket", isDirectory: true)
    }

    static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        e.dateEncodingStrategy = .iso8601
        return e
    }()

    static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    enum LoadResult {
        case fresh
        case loaded(Database)
        /// The main file was unreadable; it was moved aside and the newest backup was used instead (if any).
        case recovered(Database?, message: String)
    }

    func load() -> LoadResult {
        let fm = FileManager.default
        try? fm.createDirectory(at: directory, withIntermediateDirectories: true)
        guard fm.fileExists(atPath: fileURL.path) else {
            // No data file but there are backups (it was moved or deleted): start from the newest backup,
            // not sample data, so today's backup isn't overwritten with the samples either.
            for backup in backups() {
                if let data = try? Data(contentsOf: backup), let db = try? Self.decoder.decode(Database.self, from: data) {
                    return .recovered(db, message: "Docket couldn't find its data file, so it restored the backup from \(backup.deletingPathExtension().lastPathComponent.replacingOccurrences(of: "docket-", with: "")).")
                }
            }
            return .fresh
        }
        do {
            let data = try Data(contentsOf: fileURL)
            return .loaded(try Self.decoder.decode(Database.self, from: data))
        } catch {
            let stamp = Int(Date().timeIntervalSince1970)
            let aside = directory.appendingPathComponent("\(Self.unreadablePrefix)\(stamp).json")
            try? fm.moveItem(at: fileURL, to: aside)
            for backup in backups() {
                if let data = try? Data(contentsOf: backup), let db = try? Self.decoder.decode(Database.self, from: data) {
                    return .recovered(db, message: "Your data file couldn't be read, so Docket restored the backup from \(backup.deletingPathExtension().lastPathComponent.replacingOccurrences(of: "docket-", with: "")). The unreadable file was kept as \(aside.lastPathComponent).")
                }
            }
            return .recovered(nil, message: "Your data file couldn't be read and no backup was found. It was kept as \(aside.lastPathComponent) in the data folder.")
        }
    }

    func save(_ db: Database) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = try Self.encoder.encode(db)
        try data.write(to: fileURL, options: .atomic)
        backupIfNeeded(data)
    }

    /// Newest first.
    func backups() -> [URL] {
        let items = (try? FileManager.default.contentsOfDirectory(at: backupsURL, includingPropertiesForKeys: nil)) ?? []
        return items.filter { $0.pathExtension == "json" }.sorted { $0.lastPathComponent > $1.lastPathComponent }
    }

    /// Older copies of the data that could still be restored: the backups and any unreadable files set aside.
    func savedCopies() -> [URL] {
        let items = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        return backups() + items.filter { $0.lastPathComponent.hasPrefix(Self.unreadablePrefix) }
    }

    /// Keeps one snapshot per day for the last 30 days.
    private func backupIfNeeded(_ data: Data) {
        let fm = FileManager.default
        try? fm.createDirectory(at: backupsURL, withIntermediateDirectories: true)
        let today = backupsURL.appendingPathComponent("docket-\(Fmt.dayKey(Date())).json")
        try? data.write(to: today, options: .atomic)
        for old in backups().dropFirst(30) { try? fm.removeItem(at: old) }
    }
}
