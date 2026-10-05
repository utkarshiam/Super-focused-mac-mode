import Foundation
import Security

/// API keys and tokens, kept in the login keychain as generic passwords under one service,
/// never in UserDefaults or the data file. Values are never logged.
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

    // Recursive: a keychain call can wait on an access prompt, and nothing on that thread may deadlock on it.
    private static let lock = NSRecursiveLock()

    /// Non-nil when secrets live in memory instead of the login keychain. Unit tests and screenshot
    /// mode start that way, so they can never read, overwrite or prompt for the user's real keys.
    private static var memory: [String: String]? = startsInMemory ? [:] : nil

    /// What this launch already read from or wrote to the login keychain (an inner nil = nothing stored).
    /// Views look secrets up often: this keeps those lookups off the keychain, and macOS asks for access
    /// (e.g. after an update of an ad-hoc signed build) at most once per launch instead of on every lookup.
    private static var cache: [String: String?] = [:]

    private static var startsInMemory: Bool {
        let snapshotDir = ProcessInfo.processInfo.environment["DOCKET_SNAPSHOT_DIR"] ?? ""
        return NSClassFromString("XCTestCase") != nil || !snapshotDir.isEmpty
    }

    static func string(_ account: String) -> String? {
        lock.lock()
        defer { lock.unlock() }
        if let memory { return memory[account] }
        if let cached = cache[account] { return cached }
        let (value, settled) = read(account)
        if settled { cache.updateValue(value, forKey: account) }
        return value
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
        if write(value, for: account) {
            cache.updateValue(value, forKey: account)
        } else {
            cache.removeValue(forKey: account) // not sure what's stored now: look again next time
        }
    }

    /// Tests and screenshot mode keep secrets in memory instead of the login keychain.
    /// Each call starts from an empty store.
    static func useInMemoryStore() {
        lock.lock()
        defer { lock.unlock() }
        memory = [:]
        cache = [:]
    }

    // MARK: Login keychain

    /// The stored value. `settled` is false when the keychain couldn't answer right now (say it's
    /// locked), so the next lookup asks again rather than remembering "nothing stored".
    private static func read(_ account: String) -> (value: String?, settled: Bool) {
        var query = baseQuery(account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        switch SecItemCopyMatching(query as CFDictionary, &result) {
        case errSecSuccess:
            guard let data = result as? Data, let value = String(data: data, encoding: .utf8), !value.isEmpty else { return (nil, true) }
            return (value, true)
        case errSecItemNotFound:
            return (nil, true)
        case errSecUserCanceled, errSecAuthFailed:
            // Access was refused at the keychain prompt: don't ask again until the next launch.
            return (nil, true)
        default:
            return (nil, false)
        }
    }

    /// Saves or deletes the item. True when the keychain now holds exactly `value`.
    private static func write(_ value: String?, for account: String) -> Bool {
        let query = baseQuery(account)
        guard let value else {
            let status = SecItemDelete(query as CFDictionary)
            return status == errSecSuccess || status == errSecItemNotFound
        }
        let data = Data(value.utf8)
        var status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var item = query
            item[kSecValueData as String] = data
            item[kSecAttrLabel as String] = "Docket (\(account))"
            status = SecItemAdd(item as CFDictionary, nil)
        }
        if status != errSecSuccess { NSLog("Docket: couldn't save %@ to the keychain (OSStatus %d)", account, status) }
        return status == errSecSuccess
    }

    private static func baseQuery(_ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }
}
