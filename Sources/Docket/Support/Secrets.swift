import Foundation

/// API keys and settings for AI and the integrations. Each value is looked up in order:
/// what the user entered in Settings (Keychain) → the app's Info.plist (private builds made with
/// `EMBED_SECRETS=1 scripts/build.sh`) → the process environment (`swift run`, debugging).
/// Empty values count as missing.
enum Secrets {
    static let defaultGeminiModel = "gemini-3.5-flash"

    /// Keychain → Info.plist DocketGeminiAPIKey → env GEMINI_API_KEY.
    static var geminiAPIKey: String? {
        lookup(Keychain.Account.geminiAPIKey, plist: "DocketGeminiAPIKey", env: "GEMINI_API_KEY")
    }

    /// Keychain → Info.plist DocketGeminiModel → env GEMINI_MODEL → "gemini-3.5-flash", without a "models/" prefix.
    static var geminiModel: String {
        var model = lookup(Keychain.Account.geminiModel, plist: "DocketGeminiModel", env: "GEMINI_MODEL") ?? defaultGeminiModel
        if model.hasPrefix("models/") { model.removeFirst("models/".count) }
        return model.isEmpty ? defaultGeminiModel : model
    }

    /// Keychain → Info.plist DocketGoogleClientID → env GOOGLE_CLIENT_ID.
    static var googleClientID: String? {
        lookup(Keychain.Account.googleClientID, plist: "DocketGoogleClientID", env: "GOOGLE_CLIENT_ID")
    }

    /// Keychain → Info.plist DocketGoogleClientSecret → env GOOGLE_CLIENT_SECRET.
    static var googleClientSecret: String? {
        lookup(Keychain.Account.googleClientSecret, plist: "DocketGoogleClientSecret", env: "GOOGLE_CLIENT_SECRET")
    }

    /// True when the Gemini key comes from the app bundle rather than the user's own entry.
    static var geminiKeyIsBundled: Bool {
        clean(Keychain.string(Keychain.Account.geminiAPIKey)) == nil && clean(bundleValue("DocketGeminiAPIKey")) != nil
    }

    // The bundle and environment sources. Tests swap these to check the order without real values.
    static var bundleValue: (String) -> String? = { Bundle.main.object(forInfoDictionaryKey: $0) as? String }
    static var environmentValue: (String) -> String? = { ProcessInfo.processInfo.environment[$0] }

    private static func lookup(_ account: String, plist: String, env: String) -> String? {
        clean(Keychain.string(account)) ?? clean(bundleValue(plist)) ?? clean(environmentValue(env))
    }

    private static func clean(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else { return nil }
        return trimmed
    }
}
