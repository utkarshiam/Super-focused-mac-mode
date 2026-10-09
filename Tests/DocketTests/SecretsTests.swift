import XCTest
@testable import Docket

/// Keychain (in memory only: tests never touch the login keychain) and where Secrets looks for each value.
final class SecretsTests: XCTestCase {
    private var savedBundleValue: ((String) -> String?)?
    private var savedEnvironmentValue: ((String) -> String?)?

    override func setUp() {
        super.setUp()
        Keychain.useInMemoryStore()
        savedBundleValue = Secrets.bundleValue
        savedEnvironmentValue = Secrets.environmentValue
        Secrets.bundleValue = { _ in nil }
        Secrets.environmentValue = { _ in nil }
    }

    override func tearDown() {
        if let savedBundleValue { Secrets.bundleValue = savedBundleValue }
        if let savedEnvironmentValue { Secrets.environmentValue = savedEnvironmentValue }
        Keychain.useInMemoryStore()
        super.tearDown()
    }

    func testKeychainStoresUpdatesAndDeletes() {
        XCTAssertNil(Keychain.string(Keychain.Account.slackUserToken))
        Keychain.set("xoxp-test-1", for: Keychain.Account.slackUserToken)
        XCTAssertEqual(Keychain.string("slack-user-token"), "xoxp-test-1")
        Keychain.set("xoxp-test-2", for: "slack-user-token")
        XCTAssertEqual(Keychain.string("slack-user-token"), "xoxp-test-2")
        Keychain.set(nil, for: "slack-user-token")
        XCTAssertNil(Keychain.string("slack-user-token"))
        Keychain.set("xoxp-test-3", for: "slack-user-token")
        Keychain.set("", for: "slack-user-token")
        XCTAssertNil(Keychain.string("slack-user-token"), "an empty string deletes too")
    }

    func testSecretsFileIsPrivateAndRoundTrips() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("docket-secrets-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir); Keychain.useInMemoryStore() }
        let file = dir.appendingPathComponent("secrets.json")
        Keychain.useFile(file)
        Keychain.set("xoxp-test", for: Keychain.Account.slackUserToken)
        let mode = try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? Int
        XCTAssertEqual(mode, 0o600, "only the user can read it")
        Keychain.useFile(file) // a fresh launch reads it back
        XCTAssertEqual(Keychain.string(Keychain.Account.slackUserToken), "xoxp-test")
        Keychain.set(nil, for: Keychain.Account.slackUserToken)
        XCTAssertNil(Keychain.string(Keychain.Account.slackUserToken))
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path), "nothing stored, no file")
    }

    func testInMemoryStoreStartsEmptyEachTime() {
        Keychain.set("refresh-token", for: Keychain.Account.googleRefreshToken)
        Keychain.useInMemoryStore()
        XCTAssertNil(Keychain.string(Keychain.Account.googleRefreshToken))
    }

    func testGeminiKeyComesFromSettingsThenBundleThenEnvironment() {
        XCTAssertNil(Secrets.geminiAPIKey)
        Secrets.environmentValue = { $0 == "GEMINI_API_KEY" ? "key-from-env" : nil }
        XCTAssertEqual(Secrets.geminiAPIKey, "key-from-env")
        XCTAssertFalse(Secrets.geminiKeyIsBundled)

        Secrets.bundleValue = { $0 == "DocketGeminiAPIKey" ? "key-from-bundle" : nil }
        XCTAssertEqual(Secrets.geminiAPIKey, "key-from-bundle")
        XCTAssertTrue(Secrets.geminiKeyIsBundled)

        Keychain.set("key-from-settings", for: Keychain.Account.geminiAPIKey)
        XCTAssertEqual(Secrets.geminiAPIKey, "key-from-settings")
        XCTAssertFalse(Secrets.geminiKeyIsBundled, "the user's own key isn't the bundled one")
    }

    func testEmptyValuesCountAsMissing() {
        Keychain.set("   ", for: Keychain.Account.geminiAPIKey)
        Secrets.bundleValue = { _ in "" }
        Secrets.environmentValue = { $0 == "GEMINI_API_KEY" ? "  key-from-env\n" : nil }
        XCTAssertEqual(Secrets.geminiAPIKey, "key-from-env")
        XCTAssertFalse(Secrets.geminiKeyIsBundled)

        Secrets.environmentValue = { _ in " " }
        XCTAssertNil(Secrets.geminiAPIKey)
        XCTAssertNil(Secrets.googleClientID)
        XCTAssertNil(Secrets.googleClientSecret)
    }

    func testGeminiModelDefaultsAndDropsModelsPrefix() {
        XCTAssertEqual(Secrets.geminiModel, "gemini-3.5-flash")
        Secrets.environmentValue = { $0 == "GEMINI_MODEL" ? "models/gemini-3.5-flash" : nil }
        XCTAssertEqual(Secrets.geminiModel, "gemini-3.5-flash")
        Secrets.bundleValue = { $0 == "DocketGeminiModel" ? "gemini-bundled-model" : nil }
        XCTAssertEqual(Secrets.geminiModel, "gemini-bundled-model")
        Keychain.set("models/gemini-chosen-model", for: Keychain.Account.geminiModel)
        XCTAssertEqual(Secrets.geminiModel, "gemini-chosen-model")
        Keychain.set("models/", for: Keychain.Account.geminiModel)
        XCTAssertEqual(Secrets.geminiModel, "gemini-3.5-flash")
    }

    func testGoogleClientValues() {
        Secrets.environmentValue = { ["GOOGLE_CLIENT_ID": "id-from-env", "GOOGLE_CLIENT_SECRET": "secret-from-env"][$0] }
        XCTAssertEqual(Secrets.googleClientID, "id-from-env")
        XCTAssertEqual(Secrets.googleClientSecret, "secret-from-env")
        Secrets.bundleValue = { ["DocketGoogleClientID": "id-from-bundle", "DocketGoogleClientSecret": "secret-from-bundle"][$0] }
        XCTAssertEqual(Secrets.googleClientID, "id-from-bundle")
        XCTAssertEqual(Secrets.googleClientSecret, "secret-from-bundle")
        Keychain.set("id-from-settings", for: Keychain.Account.googleClientID)
        Keychain.set("secret-from-settings", for: Keychain.Account.googleClientSecret)
        XCTAssertEqual(Secrets.googleClientID, "id-from-settings")
        XCTAssertEqual(Secrets.googleClientSecret, "secret-from-settings")
    }
}
