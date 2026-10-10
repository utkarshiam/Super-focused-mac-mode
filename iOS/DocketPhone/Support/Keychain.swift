import Foundation
import Security

/// The Gemini key in this iPhone's Keychain (never in files, defaults or logs). Only this device:
/// `ThisDeviceOnly`, so it doesn't travel in backups or iCloud Keychain.
enum Keychain {
    private static let service = "com.docketapp.DocketPhone"
    private static let account = "gemini-api-key"

    private static var baseQuery: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    static func readKey() -> String? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data, let key = String(data: data, encoding: .utf8) else { return nil }
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Saves (or replaces) the key. Returns false when the Keychain refused.
    @discardableResult
    static func saveKey(_ key: String) -> Bool {
        let data = Data(key.trimmingCharacters(in: .whitespacesAndNewlines).utf8)
        SecItemDelete(baseQuery as CFDictionary)
        var item = baseQuery
        item[kSecValueData as String] = data
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        return SecItemAdd(item as CFDictionary, nil) == errSecSuccess
    }

    static func deleteKey() {
        SecItemDelete(baseQuery as CFDictionary)
    }
}
