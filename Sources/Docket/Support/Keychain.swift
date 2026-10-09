import Foundation

/// API keys and tokens, kept in a private file in Docket's data folder (`secrets.json`, readable only by
/// you: permissions 600, folder 700), never in UserDefaults or the data file, and never logged.
///
/// Why not the macOS keychain: Docket is ad-hoc signed, so every update looks like a different app to the
/// keychain and macOS asks for your password again for each item. A user-only file is how most developer
/// tools keep tokens (the GitHub CLI, for one), and it never interrupts you.
/// (The type keeps its name so the rest of the app doesn't care where secrets live.)
enum Keychain {
    static let service = "com.docketapp.Docket"

    /// The accounts Docket stores.
    enum Account {
        static let geminiAPIKey = "gemini-api-key"
        static let geminiModel = "gemini-model"
        static let slackUserToken = "slack-user-token"
        static let googleRefreshToken = "google-refresh-token"
        static let googleClientID = "google-client-id"
        static let googleClientSecret = "google-client-secret"
    }

    private static let lock = NSRecursiveLock()

    /// Non-nil when secrets live in memory only. Unit tests and screenshot mode start that way, so they
    /// can never read or overwrite the user's real keys.
    private static var memory: [String: String]? = startsInMemory ? [:] : nil

    /// The file's contents, read once per launch.
    private static var loaded: [String: String]?

    /// Where the file lives.
    static var fileURL: URL { fileOverride ?? Persistence.defaultDirectory.appendingPathComponent("secrets.json") }
    private static var fileOverride: URL?

    /// Tests: use a real file at `url` instead of memory.
    static func useFile(_ url: URL) {
        lock.lock()
        defer { lock.unlock() }
        memory = nil
        loaded = nil
        fileOverride = url
    }

    private static var startsInMemory: Bool {
        let snapshotDir = ProcessInfo.processInfo.environment["DOCKET_SNAPSHOT_DIR"] ?? ""
        return NSClassFromString("XCTestCase") != nil || !snapshotDir.isEmpty
    }

    static func string(_ account: String) -> String? {
        lock.lock()
        defer { lock.unlock() }
        if let memory { return memory[account] }
        return stored()[account]
    }

    /// Saves a value; nil (or an empty string) deletes it.
    static func set(_ value: String?, for account: String) {
        let value = value?.isEmpty == false ? value : nil
        lock.lock()
        defer { lock.unlock() }
        if memory != nil {
            memory?[account] = value
            return
        }
        var all = stored()
        all[account] = value
        loaded = all
        save(all)
    }

    /// Tests and screenshot mode keep secrets in memory. Each call starts from an empty store.
    static func useInMemoryStore() {
        lock.lock()
        defer { lock.unlock() }
        memory = [:]
        loaded = nil
        fileOverride = nil
    }

    // MARK: The file

    private static func stored() -> [String: String] {
        if let loaded { return loaded }
        let values = (try? Data(contentsOf: fileURL)).flatMap { try? JSONDecoder().decode([String: String].self, from: $0) } ?? [:]
        loaded = values
        return values
    }

    private static func save(_ values: [String: String]) {
        let fm = FileManager.default
        let folder = fileURL.deletingLastPathComponent()
        do {
            try fm.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            if values.isEmpty {
                try? fm.removeItem(at: fileURL)
                return
            }
            let data = try JSONEncoder().encode(values)
            try data.write(to: fileURL, options: [.atomic])
            try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
        } catch {
            NSLog("Docket: couldn't save secrets (%@)", error.localizedDescription)
        }
    }
}
