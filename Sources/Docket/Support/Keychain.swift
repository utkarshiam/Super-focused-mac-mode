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

    private static let lock = NSLock()

    /// Non-nil when secrets live in memory instead of the login keychain. Unit tests and screenshot
    /// mode start that way, so they can never read, overwrite or prompt for the user's real keys.
    private static var memory: [String: String]? = startsInMemory ? [:] : nil

    private static var startsInMemory: Bool {
        let snapshotDir = ProcessInfo.processInfo.environment["DOCKET_SNAPSHOT_DIR"] ?? ""
        return NSClassFromString("XCTestCase") != nil || !snapshotDir.isEmpty
    }

    static func string(_ account: String) -> String? {
        if let memory = memoryStore() { return memory[account] }
        var query = baseQuery(account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data,
              let value = String(data: data, encoding: .utf8), !value.isEmpty else { return nil }
        return value
    }

    /// Saves a value; nil (or an empty string) deletes it.
    static func set(_ value: String?, for account: String) {
        let value = value?.isEmpty == false ? value : nil
        lock.lock()
        if memory != nil {
            memory?[account] = value
            lock.unlock()
            return
        }
        lock.unlock()

        let query = baseQuery(account)
        guard let value else {
            SecItemDelete(query as CFDictionary)
            return
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
    }

    /// Tests and screenshot mode keep secrets in memory instead of the login keychain.
    /// Each call starts from an empty store.
    static func useInMemoryStore() {
        lock.lock()
        defer { lock.unlock() }
        memory = [:]
    }

    private static func memoryStore() -> [String: String]? {
        lock.lock()
        defer { lock.unlock() }
        return memory
    }

    private static func baseQuery(_ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }
}
