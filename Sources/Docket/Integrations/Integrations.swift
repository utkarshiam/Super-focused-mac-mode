import AppKit
import Combine
import Foundation

// MARK: - Suggestions

/// A Slack message or email that may deserve a task, shown in "From Slack & Gmail".
struct Suggestion: Identifiable, Codable, Hashable {
    var id: String { source.externalID }
    var source: TaskSource
    var from: String
    var subject: String?
    var snippet: String
    var receivedAt: Date
    var draft: TaskDraft?
    /// What picked it up: a 📌 reaction, a mention, a star, an email waiting for a reply.
    var trigger: SuggestionTrigger?

    enum CodingKeys: String, CodingKey { case source, from, subject, snippet, receivedAt, draft, trigger }
}

extension Suggestion {
    // In an extension so the memberwise initializer stays available. Missing keys fall back to defaults.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        source = try c.decode(TaskSource.self, forKey: .source)
        from = c.value(.from, default: "")
        subject = c.value(.subject, default: nil)
        snippet = c.value(.snippet, default: "")
        receivedAt = c.value(.receivedAt, default: Date())
        draft = c.value(.draft, default: nil)
        trigger = c.value(.trigger, default: nil)
    }
}

/// Why a message became a suggestion.
enum SuggestionTrigger: String, Codable, Hashable {
    case reaction, mention, starred, needsReply

    /// The user flagged it on purpose (a reaction, a star): it's suggested even when AI sees nothing to do.
    var isExplicit: Bool { self == .reaction || self == .starred }
}

// MARK: - Settings

extension Prefs.Key {
    static let slackSaveEmoji = "slackSaveEmoji"
    static let slackMentions = "slackMentions"
    static let slackFocusStatus = "slackFocusStatus"
    static let gmailNeedsReply = "gmailNeedsReply"
    static let slackShareChannel = "slackShareChannel"
}

/// The switches on Settings → Connections, read at the start of each refresh.
struct IntegrationSettings: Equatable {
    var saveEmoji = SlackSaveEmoji.standard
    var mentions = true
    var focusStatus = true
    var needsReply = true

    static var current: IntegrationSettings {
        let d = UserDefaults.standard
        return IntegrationSettings(
            saveEmoji: SlackSaveEmoji.normalized(d.string(forKey: Prefs.Key.slackSaveEmoji)),
            mentions: d.object(forKey: Prefs.Key.slackMentions) as? Bool ?? true,
            focusStatus: d.object(forKey: Prefs.Key.slackFocusStatus) as? Bool ?? true,
            needsReply: d.object(forKey: Prefs.Key.gmailNeedsReply) as? Bool ?? true)
    }
}

/// The reaction that saves a Slack message to Docket.
enum SlackSaveEmoji {
    static let standard = "pushpin"
    /// Offered in Settings, by Slack's names for them.
    static let choices: [(name: String, glyph: String)] = [
        ("pushpin", "📌"), ("bookmark", "🔖"), ("memo", "📝"), ("inbox_tray", "📥"), ("star", "⭐️"), ("eyes", "👀"),
    ]

    static func glyph(_ name: String) -> String {
        choices.first { $0.name == name }?.glyph ?? ":\(name):"
    }

    /// "  :Pushpin: " → "pushpin"; empty means the default.
    static func normalized(_ raw: String?) -> String {
        let name = (raw ?? "").trimmingCharacters(in: CharacterSet(charactersIn: ":").union(.whitespacesAndNewlines)).lowercased()
        return name.isEmpty ? standard : name
    }
}

// MARK: - Errors

/// What went wrong talking to Slack or Google, in words the user can act on.
enum IntegrationError: LocalizedError, Equatable {
    enum Service: String { case slack = "Slack", gmail = "Gmail", google = "Google" }

    case notConnected(Service)
    /// The token was revoked or expired: connect again.
    case signedOut(Service)
    case missingPermission(Service, String)
    case rateLimited(Service, retryAfter: TimeInterval)
    case offline(Service, String)
    case unexpected(Service, String)
    /// Already in plain words.
    case api(Service, String)
    case signInCancelled, signInTimedOut, signInDenied
    case cancelled

    var errorDescription: String? {
        switch self {
        case .notConnected(let s):
            "\(s.rawValue) isn't connected."
        case .signedOut(.slack):
            "Slack no longer accepts Docket's token. Paste a new one in Settings → Connections."
        case .signedOut:
            "Google signed Docket out of Gmail. Connect it again in Settings → Connections. (Google signs out apps in testing after 7 days.)"
        case .missingPermission(.slack, let scope):
            "The Docket app in Slack is missing the \(scope) permission. Create the app again from step 1 in Settings → Connections."
        case .missingPermission(_, let what):
            "Docket needs permission to \(what). Connect Gmail again and allow it."
        case .rateLimited(let s, let after):
            "\(s.rawValue) asked Docket to slow down. It will try again in \(Fmt.duration(minutes: max(1, Int((after / 60).rounded(.up)))))."
        case .offline(let s, let detail):
            "Couldn't reach \(s.rawValue). \(detail)"
        case .unexpected(let s, let detail):
            "\(s.rawValue) sent back something unexpected (\(detail))."
        case .api(_, let message):
            message
        case .signInCancelled:
            "Sign-in was cancelled."
        case .signInTimedOut:
            "Sign-in timed out. Try again."
        case .signInDenied:
            "Gmail wasn't connected: access was declined in the browser."
        case .cancelled:
            "Cancelled."
        }
    }

    /// Any error as an IntegrationError for `service` (network errors become `.offline`).
    static func wrap(_ error: Error, _ service: Service) -> IntegrationError {
        if let e = error as? IntegrationError { return e }
        if error is CancellationError { return .cancelled }
        if let url = error as? URLError {
            switch url.code {
            case .cancelled: return .cancelled
            case .notConnectedToInternet, .networkConnectionLost, .dataNotAllowed, .internationalRoamingOff:
                return .offline(service, "You seem to be offline.")
            case .timedOut: return .offline(service, "It took too long to answer.")
            case .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed:
                return .offline(service, "Check your internet connection.")
            case .secureConnectionFailed, .serverCertificateUntrusted, .serverCertificateHasBadDate, .serverCertificateNotYetValid:
                return .offline(service, "The secure connection failed.")
            default: return .offline(service, "Check your internet connection.")
            }
        }
        return .unexpected(service, (error as NSError).domain)
    }
}

// MARK: - HTTP

/// Plain HTTPS for Slack and Google. The transport is swapped in tests, so they never touch the network.
enum IntegrationHTTP {
    typealias Transport = @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse)

    /// Ephemeral: no cookies, cache or credentials on disk.
    private static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 90
        config.httpCookieStorage = nil
        config.urlCache = nil
        config.httpAdditionalHeaders = ["User-Agent": "Docket (macOS)"]
        return URLSession(configuration: config)
    }()

    /// HTTPS only.
    static let live: Transport = { request in
        guard request.url?.scheme == "https" else { throw URLError(.appTransportSecurityRequiresSecureConnection) }
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        return (data, http)
    }

    static let sleep: @Sendable (TimeInterval) async throws -> Void = { seconds in
        try await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000))
    }

    /// Characters that never need escaping (RFC 3986 "unreserved").
    private static let unreserved = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")

    static func escape(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: unreserved) ?? ""
    }

    /// "a=1&b=two%20words": a query string or an application/x-www-form-urlencoded body.
    /// Everything except unreserved characters is escaped, so "+", "&", "=" and "#" in values stay intact.
    static func encode(_ items: [(String, String)]) -> String {
        items.map { "\(escape($0.0))=\(escape($0.1))" }.joined(separator: "&")
    }

    static func formPost(_ url: URL, _ items: [(String, String)], bearer: String? = nil) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue("application/x-www-form-urlencoded; charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let bearer { request.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization") }
        request.httpBody = Data(encode(items).utf8)
        return request
    }

    /// Sends through `transport`, turning network failures into `IntegrationError`s for `service`.
    static func send(_ request: URLRequest, via transport: Transport, service: IntegrationError.Service) async throws -> (Data, HTTPURLResponse) {
        do {
            return try await transport(request)
        } catch {
            throw IntegrationError.wrap(error, service)
        }
    }

    /// Seconds from a Retry-After header, when there is one.
    static func retryAfter(_ response: HTTPURLResponse) -> TimeInterval? {
        guard let raw = response.value(forHTTPHeaderField: "Retry-After")?.trimmingCharacters(in: .whitespaces),
              let seconds = Double(raw), seconds >= 0 else { return nil }
        return seconds
    }

    /// Runs `work` for every item, at most `limit` at a time; results keep the input order.
    static func concurrentMap<T: Sendable, R: Sendable>(_ items: [T], limit: Int, _ work: @escaping @Sendable (T) async -> R) async -> [R] {
        guard !items.isEmpty else { return [] }
        return await withTaskGroup(of: (Int, R).self) { group in
            var results = [(Int, R)]()
            var next = 0
            while next < min(max(1, limit), items.count) {
                let index = next, item = items[index]
                group.addTask { (index, await work(item)) }
                next += 1
            }
            while let finished = await group.next() {
                results.append(finished)
                if next < items.count {
                    let index = next, item = items[index]
                    group.addTask { (index, await work(item)) }
                    next += 1
                }
            }
            return results.sorted { $0.0 < $1.0 }.map { $0.1 }
        }
    }
}

// MARK: - Saved state

/// What Integrations remembers between launches, in integrations.json in the data folder.
/// No tokens: those stay in the keychain.
struct IntegrationsFile: Codable {
    var version = 1
    var suggestions: [Suggestion] = []
    /// Message ids (`TaskSource.externalID`) that were added or dismissed, and when. Never suggested again.
    var handled: [String: Date] = [:]
    /// Message ids AI looked at and found nothing to do for. Not suggested.
    var skipped: [String: Date] = [:]
    var lastRefresh: Date?
    var slack: SlackAccount?
    var gmailAddress: String?
    /// Set while Docket's "Heads down" status is on Slack, so it can be undone even after a crash.
    var focusStatus: SlackFocusRecord?

    init() {}

    enum CodingKeys: String, CodingKey { case version, suggestions, handled, skipped, lastRefresh, slack, gmailAddress, focusStatus }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = c.value(.version, default: 1)
        // One unreadable suggestion (say, from a newer version) doesn't cost the rest.
        suggestions = c.value(.suggestions, default: [LenientSuggestion]()).compactMap(\.value)
        handled = c.value(.handled, default: [:])
        skipped = c.value(.skipped, default: [:])
        lastRefresh = c.value(.lastRefresh, default: nil)
        slack = c.value(.slack, default: nil)
        gmailAddress = c.value(.gmailAddress, default: nil)
        focusStatus = c.value(.focusStatus, default: nil)
    }

    static func load(from url: URL) -> IntegrationsFile {
        guard let data = try? Data(contentsOf: url), let file = try? Persistence.decoder.decode(IntegrationsFile.self, from: data) else {
            return IntegrationsFile()
        }
        return file
    }

    func encoded() throws -> Data { try Persistence.encoder.encode(self) }
}

private struct LenientSuggestion: Decodable {
    let value: Suggestion?
    init(from decoder: Decoder) throws { value = try? Suggestion(from: decoder) }
}

/// De-duplication rules for suggestions. Pure, so they're easy to test.
enum SuggestionInbox {
    /// At most this many wait in "From Slack & Gmail" (the oldest go first).
    static let limit = 100
    /// Handled and skipped ids are kept this long: longer than any source looks back (30 days).
    static let memory: TimeInterval = 120 * 86_400

    /// Ids that must not be suggested (again): handled, skipped, already waiting, or already on a task.
    static func knownIDs(pending: [Suggestion], handled: [String: Date], skipped: [String: Date], taskSourceIDs: Set<String>) -> Set<String> {
        Set(handled.keys).union(skipped.keys).union(pending.map(\.id)).union(taskSourceIDs)
    }

    /// Adds what's new to what's waiting, newest first, without duplicates or known ids.
    static func merge(_ incoming: [Suggestion], into pending: [Suggestion], known: Set<String>) -> [Suggestion] {
        var seen = Set(pending.map(\.id))
        var result = pending
        for s in incoming where !known.contains(s.id) && seen.insert(s.id).inserted {
            result.append(s)
        }
        return Array(result.sorted { $0.receivedAt > $1.receivedAt }.prefix(limit))
    }

    /// Drops ids older than `memory`.
    static func pruned(_ ids: [String: Date], now: Date) -> [String: Date] {
        ids.filter { now.timeIntervalSince($0.value) < memory }
    }
}

/// Task drafts for suggestions when AI isn't there to write them.
enum SuggestionDrafts {
    static func fallback(for s: Suggestion) -> TaskDraft {
        var draft = TaskDraft(title: title(for: s))
        draft.notes = context(for: s)
        draft.source = s.source
        return draft
    }

    /// "Reply to Sam: Q3 numbers" for an email, "Slack: <first line>" for a Slack message.
    static func title(for s: Suggestion) -> String {
        switch s.source.kind {
        case .gmail:
            return emailTitle(from: s.from, subject: s.subject, snippet: s.snippet)
        case .slack, .ai:
            let line = SlackText.firstLine(s.snippet)
            return line.isEmpty ? "Slack: message from \(s.from)" : "Slack: \(line)"
        }
    }

    static func emailTitle(from: String, subject: String?, snippet: String) -> String {
        let name = MailSender(header: from).firstName
        var topic = MailText.cleanSubject(subject ?? "")
        if topic.isEmpty { topic = SlackText.firstLine(snippet, limit: 50) }
        topic = SlackText.firstLine(topic, limit: 60)
        return topic.isEmpty ? "Reply to \(name)" : "Reply to \(name): \(topic)"
    }

    /// The message, for the task's notes: who, where, and what they wrote.
    static func context(for s: Suggestion) -> String {
        let header: String
        switch s.source.kind {
        case .gmail:
            header = [s.from, s.subject].compactMap { $0?.isEmpty == false ? $0 : nil }.joined(separator: " · ")
        case .slack, .ai:
            header = s.source.label.isEmpty ? s.from : s.source.label
        }
        let body = s.snippet.trimmingCharacters(in: .whitespacesAndNewlines)
        return body.isEmpty ? header : "\(header):\n\(body)"
    }

    /// An AI draft made ready to add: linked to the message, with the message as notes when it has none.
    static func prepared(_ draft: TaskDraft, for s: Suggestion) -> TaskDraft {
        var d = draft
        d.source = s.source
        if d.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { d.title = title(for: s) }
        if d.notes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { d.notes = context(for: s) }
        return d
    }
}

/// The AI step that decides which mentions and emails need a task. Tests swap in a fake.
struct SuggestionTriage {
    var isAvailable: @MainActor () -> Bool
    var run: @MainActor ([IncomingMessage], Store, Date) async throws -> [String: TaskDraft]

    static var gemini: SuggestionTriage {
        SuggestionTriage(isAvailable: { AIService.shared.isConfigured },
                         run: { messages, store, now in try await AIService.shared.triage(messages, store: store, now: now) })
    }

    /// No AI: every mention and email waiting for a reply gets a plain draft.
    static var none: SuggestionTriage {
        SuggestionTriage(isAvailable: { false }, run: { _, _, _ in [:] })
    }
}

/// A message found during a refresh, before AI has looked at it.
struct SuggestionCandidate {
    var suggestion: Suggestion
    var message: IncomingMessage
}

// MARK: - Integrations

/// Slack and Gmail: suggestions to turn into tasks, sharing a plan, and the Slack focus status.
///
/// Network calls run in the background and never block the UI; problems become a status line
/// (`slackProblem`, `gmailProblem`). Tokens live in the keychain only and are never logged.
@MainActor
final class Integrations: ObservableObject {
    static let shared = Integrations()

    @Published var suggestions: [Suggestion] = []
    var pendingCount: Int { suggestions.count }
    @Published var isSlackConnected = false
    @Published var isGmailConnected = false
    var isAnyConnected: Bool { isSlackConnected || isGmailConnected }

    /// Who Slack says we are ("@maya in Acme").
    @Published private(set) var slackAccount: SlackAccount?
    /// The connected Gmail address.
    @Published private(set) var gmailAddress: String?
    @Published private(set) var isRefreshing = false
    @Published private(set) var lastRefresh: Date?
    /// The last problem with each service, in plain words (nil when all is well).
    @Published private(set) var slackProblem: String?
    @Published private(set) var gmailProblem: String?
    /// Waiting for the user to finish signing in to Google in the browser.
    @Published private(set) var isSigningInToGmail = false
    /// Bumped when the Google OAuth client changes, so Settings re-reads it.
    @Published private(set) var googleClientRevision = 0

    // Dependencies. Tests swap them, so nothing reaches the network, Gemini or a browser.
    var transport: IntegrationHTTP.Transport
    var triage: SuggestionTriage
    var sleep: @Sendable (TimeInterval) async throws -> Void
    var settings: () -> IntegrationSettings = { .current }
    var openURL: (URL) -> Void = { url in _ = NSWorkspace.shared.open(url) }

    static let refreshInterval: TimeInterval = 15 * 60
    /// Coming back to Docket refreshes when the last check is older than this.
    static let staleAfter: TimeInterval = 5 * 60
    /// Messages saved with a reaction count when they're at most this old (like Gmail's 30 days of stars).
    static let savedWindow: TimeInterval = 30 * 86_400
    static let mentionsWindow: TimeInterval = 3 * 86_400
    /// Without AI to pick out the ones that matter, at most this many mentions or emails per source per refresh.
    static let unsortedLimit = 15

    private weak var store: Store?
    private weak var app: AppState?
    private var fileURL: URL?
    private var handled: [String: Date] = [:]
    private var skipped: [String: Date] = [:]
    private var focusRecord: SlackFocusRecord?
    private var started = false
    private var refreshTask: Task<Void, Never>?
    private var signInTask: Task<Void, Never>?
    private var focusChain: Task<Void, Never>?
    private var timer: Timer?
    private var observers: [NSObjectProtocol] = []
    private var cancellables: Set<AnyCancellable> = []
    private var slackPausedUntil: Date?
    private var gmailPausedUntil: Date?
    private var userNames: [String: String] = [:]
    private var conversations: [String: SlackChannel] = [:]
    private var channelList: (channels: [SlackChannel], fetched: Date)?
    private var google: GoogleSession?
    private let saveQueue = DispatchQueue(label: "docket.integrations.save", qos: .utility)

    init(transport: @escaping IntegrationHTTP.Transport = IntegrationHTTP.live,
         triage: SuggestionTriage = .gemini,
         sleep: @escaping @Sendable (TimeInterval) async throws -> Void = IntegrationHTTP.sleep) {
        self.transport = transport
        self.triage = triage
        self.sleep = sleep
    }

    // MARK: Lifecycle

    /// Called once at launch (never in screenshot mode): loads what was saved, then refreshes at start,
    /// every 15 minutes, and when Docket becomes active after more than 5 minutes.
    func start(store: Store, app: AppState) {
        guard !started, !DebugSnapshot.isActive else { return }
        started = true
        attach(store: store, app: app)

        let timer = Timer(timeInterval: Self.refreshInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        timer.tolerance = 60
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer

        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.refreshIfStale() }
        })
        // Saves are written in the background; let the last one land before the app exits.
        observers.append(center.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { [saveQueue] _ in
            saveQueue.sync {}
        })

        // After launch, so a keychain prompt never holds up the first window.
        Task { @MainActor [weak self] in await self?.resumeAfterLaunch() }
    }

    /// Remembers the store and loads integrations.json from `directory` (default: the store's data folder).
    /// No network, no timers. `start` calls it; tests call it directly.
    func attach(store: Store, app: AppState?, directory: URL? = nil) {
        self.store = store
        self.app = app
        let url = (directory ?? store.persistence.directory).appendingPathComponent("integrations.json")
        fileURL = url
        let file = IntegrationsFile.load(from: url)
        suggestions = file.suggestions
        handled = file.handled
        skipped = file.skipped
        lastRefresh = file.lastRefresh
        slackAccount = file.slack
        gmailAddress = file.gmailAddress
        focusRecord = file.focusStatus
        isSlackConnected = file.slack != nil
        isGmailConnected = file.gmailAddress != nil

        cancellables = []
        // A suggestion that became a task some other way (Edit… in the planner, undo/redo) is done.
        store.objectWillChange
            .debounce(for: .milliseconds(600), scheduler: RunLoop.main)
            .sink { [weak self] _ in Task { @MainActor in self?.retireSuggestionsOnTasks() } }
            .store(in: &cancellables)
    }

    private func resumeAfterLaunch() async {
        // Accounts whose state file went missing come back from the keychain by themselves.
        if slackAccount == nil, let token = Keychain.string(Keychain.Account.slackUserToken) {
            try? await connectSlack(token: token, refreshAfter: false)
        }
        if gmailAddress == nil, Keychain.string(Keychain.Account.googleRefreshToken) != nil, let session = googleSession() {
            if let email = try? await GmailClient(session: session, transport: transport).profileEmail() {
                gmailAddress = email
                isGmailConnected = true
                save()
            }
        }
        // A "Heads down" status left over from a session that ended while Docket wasn't running.
        if focusRecord != nil { enqueueFocus { [weak self] in await self?.clearFocusStatus() } }
        refresh()
    }

    // MARK: Refresh

    /// Checks Slack and Gmail for new messages now, without blocking the UI. Does nothing while a check runs.
    func refresh() {
        guard store != nil, refreshTask == nil, isAnyConnected, !DebugSnapshot.isActive else { return }
        refreshTask = Task { @MainActor [weak self] in
            await self?.refreshNow()
            self?.refreshTask = nil
        }
    }

    func refreshIfStale() {
        if let last = lastRefresh, Date().timeIntervalSince(last) < Self.staleAfter { return }
        refresh()
    }

    /// One full check: collect new messages, let AI pick out the ones that need a task, merge, save.
    func refreshNow(now: Date = Date()) async {
        guard let store else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        let settings = settings()
        let known = SuggestionInbox.knownIDs(pending: suggestions, handled: handled, skipped: skipped,
                                             taskSourceIDs: Set(store.tasks.compactMap { $0.source?.externalID }))

        async let fromSlack = collectSlack(settings: settings, known: known, now: now)
        async let fromGmail = collectGmail(settings: settings, known: known, now: now)
        let found = await fromSlack + fromGmail

        let sorted = await sort(found, store: store, now: now)
        for id in sorted.skipped { skipped[id] = now }
        // Recomputed: tasks may have been added while this check was waiting on the network.
        let knownNow = SuggestionInbox.knownIDs(pending: suggestions, handled: handled, skipped: skipped,
                                                taskSourceIDs: Set(store.tasks.compactMap { $0.source?.externalID }))
        suggestions = SuggestionInbox.merge(sorted.accepted, into: suggestions, known: knownNow)
        handled = SuggestionInbox.pruned(handled, now: now)
        skipped = SuggestionInbox.pruned(skipped, now: now)
        lastRefresh = now
        save()
    }

    /// Splits new messages into suggestions (with drafts) and ones AI found nothing to do for.
    private func sort(_ found: [SuggestionCandidate], store: Store, now: Date) async -> (accepted: [Suggestion], skipped: [String]) {
        guard !found.isEmpty else { return ([], []) }
        let newestFirst = found.sorted { $0.suggestion.receivedAt > $1.suggestion.receivedAt }
        let aiAvailable = triage.isAvailable()
        var drafts: [String: TaskDraft] = [:]
        var looked = Set<String>()
        var aiProblem: String?
        if aiAvailable {
            // Batches of 25: one failed batch doesn't lose what the others found.
            for start in stride(from: 0, to: newestFirst.count, by: 25) {
                let batch = Array(newestFirst[start..<min(start + 25, newestFirst.count)])
                do {
                    let result = try await triage.run(batch.map(\.message), store, now)
                    drafts.merge(result) { first, _ in first }
                    looked.formUnion(batch.map(\.suggestion.id))
                } catch {
                    aiProblem = "AI couldn't sort the newest messages, so they'll be checked again later. \(error.localizedDescription)"
                    break
                }
            }
        }

        var accepted: [Suggestion] = []
        var skipped: [String] = []
        var unsorted: [IntegrationError.Service: Int] = [:]
        for candidate in newestFirst {
            var s = candidate.suggestion
            let explicit = s.trigger?.isExplicit ?? true
            if let draft = drafts[s.id] {
                s.draft = SuggestionDrafts.prepared(draft, for: s)
                accepted.append(s)
            } else if explicit {
                s.draft = SuggestionDrafts.fallback(for: s)
                accepted.append(s)
            } else if looked.contains(s.id) {
                skipped.append(s.id) // AI read it and saw nothing to do.
            } else if !aiAvailable {
                let service: IntegrationError.Service = s.source.kind == .gmail ? .gmail : .slack
                guard unsorted[service, default: 0] < Self.unsortedLimit else { continue }
                unsorted[service, default: 0] += 1
                s.draft = SuggestionDrafts.fallback(for: s)
                accepted.append(s)
            }
            // Otherwise AI is set up but failed this time: the message is looked at again next refresh.
        }
        if let aiProblem {
            if found.contains(where: { $0.suggestion.source.kind == .slack }) { slackProblem = slackProblem ?? aiProblem }
            if found.contains(where: { $0.suggestion.source.kind == .gmail }) { gmailProblem = gmailProblem ?? aiProblem }
        }
        return (accepted, skipped)
    }

    // MARK: Slack

    private func slackToken() -> String? {
        Keychain.string(Keychain.Account.slackUserToken)
    }

    private func slackClient(_ token: String) -> SlackClient {
        SlackClient(token: token, transport: transport, sleep: sleep)
    }

    private func collectSlack(settings: IntegrationSettings, known: Set<String>, now: Date) async -> [SuggestionCandidate] {
        guard isSlackConnected, let account = slackAccount else { return [] }
        if let until = slackPausedUntil, until > now { return [] }
        guard let token = slackToken() else {
            disconnectSlack(problem: "Slack was disconnected: its token is no longer in the keychain. Paste it again in Settings → Connections.")
            return []
        }
        let client = slackClient(token)
        do {
            var found = try await client.savedMessages(by: account.userID, emoji: settings.saveEmoji,
                                                       since: now.addingTimeInterval(-Self.savedWindow))
                .map { ($0, SuggestionTrigger.reaction) }
            if settings.mentions {
                found += try await client.mentions(of: account.userID, since: now.addingTimeInterval(-Self.mentionsWindow))
                    .map { ($0, SuggestionTrigger.mention) }
            }
            // A saved message that also mentions you counts as saved (it's listed first).
            var seen = Set<String>()
            let fresh = found.filter { !known.contains($0.0.externalID) && seen.insert($0.0.externalID).inserted }
            await learnNames(for: fresh.map { $0.0 }, client: client)
            slackProblem = nil
            slackPausedUntil = nil
            return fresh.map { slackCandidate($0.0, trigger: $0.1, account: account) }
        } catch {
            handleSlack(error, now: now)
            return []
        }
    }

    /// Looks up the people and channels new messages mention, a few at a time, remembering them for the session.
    private func learnNames(for messages: [SlackMessage], client: SlackClient) async {
        var users = Set<String>()
        var channels = Set<String>()
        for m in messages {
            if let id = m.userID { users.insert(id) }
            users.formUnion(SlackText.mentionedUserIDs(in: m.text))
            if m.channelName == nil || m.isDirect { channels.insert(m.channelID) }
        }
        let missingUsers = Array(users.filter { userNames[$0] == nil }.prefix(40))
        let missingChannels = Array(channels.filter { conversations[$0] == nil }.prefix(20))
        let foundUsers = await IntegrationHTTP.concurrentMap(missingUsers, limit: 6) { id in try? await client.user(id) }
        for user in foundUsers.compactMap({ $0 }) { userNames[user.id] = user.name }
        let foundChannels = await IntegrationHTTP.concurrentMap(missingChannels, limit: 4) { id in try? await client.conversation(id) }
        for channel in foundChannels.compactMap({ $0 }) { conversations[channel.id] = channel }
    }

    private func slackCandidate(_ m: SlackMessage, trigger: SuggestionTrigger, account: SlackAccount) -> SuggestionCandidate {
        let sender = m.userID.flatMap { userNames[$0] } ?? m.userName ?? "Someone"
        let conversation = conversations[m.channelID]
        let place: String
        if m.isDirect || conversation?.isDirect == true {
            place = "Direct message"
        } else if m.isGroupDM || conversation?.isGroupDM == true {
            place = "Group message"
        } else if let name = m.channelName ?? conversation?.name {
            place = "#\(name)"
        } else {
            place = "Slack"
        }
        let channelNames = conversations.compactMapValues { $0.isDirect || $0.isGroupDM ? nil : $0.name }
        let text = SlackText.plain(m.text, users: userNames, channels: channelNames)
        let link = m.permalink ?? account.permalink(channel: m.channelID, ts: m.ts)
        let source = TaskSource(kind: .slack, externalID: m.externalID, url: link, label: "\(place) · \(sender)")
        let suggestion = Suggestion(source: source, from: sender, subject: nil, snippet: String(SlackText.collapsed(text).prefix(500)),
                                    receivedAt: m.date, draft: nil, trigger: trigger)
        let message = IncomingMessage(source: source, from: sender, subject: nil, text: String(text.prefix(4000)), date: m.date)
        return SuggestionCandidate(suggestion: suggestion, message: message)
    }

    private func handleSlack(_ error: Error, now: Date) {
        let e = IntegrationError.wrap(error, .slack)
        switch e {
        case .cancelled:
            return
        case .signedOut:
            disconnectSlack(problem: e.errorDescription)
        case .rateLimited(_, let after):
            slackPausedUntil = now.addingTimeInterval(max(60, after))
            slackProblem = e.errorDescription
        default:
            slackProblem = e.errorDescription
        }
    }

    /// Checks the token with Slack (auth.test), then keeps it in the keychain. Throws a readable error.
    func connectSlack(token raw: String) async throws {
        try await connectSlack(token: raw, refreshAfter: true)
    }

    private func connectSlack(token raw: String, refreshAfter: Bool) async throws {
        let token = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard token.hasPrefix("xoxp-") else {
            throw IntegrationError.api(.slack, token.hasPrefix("xoxb-")
                ? "That's a bot token. Paste the User OAuth Token, which starts with xoxp-."
                : "That doesn't look like a Slack user token. It starts with xoxp-.")
        }
        guard !DebugSnapshot.isActive else { throw IntegrationError.notConnected(.slack) }
        let (account, scopes) = try await slackClient(token).identity()
        Keychain.set(token, for: Keychain.Account.slackUserToken)
        slackAccount = account
        isSlackConnected = true
        slackPausedUntil = nil
        let missing = SlackManifest.userScopes.filter { scope in scopes.map { !$0.contains(scope) } ?? false }
        slackProblem = missing.isEmpty ? nil
            : "Connected, but the Slack app is missing \(missing.joined(separator: ", ")). Create it again from step 1 and paste the new token."
        save()
        if refreshAfter { refresh() }
    }

    /// Forgets the Slack token. `problem` explains why when Docket did it by itself; a manual disconnect
    /// also clears the Slack suggestions still waiting.
    func disconnectSlack(problem: String? = nil) {
        Keychain.set(nil, for: Keychain.Account.slackUserToken)
        slackAccount = nil
        isSlackConnected = false
        slackProblem = problem
        slackPausedUntil = nil
        channelList = nil
        userNames = [:]
        conversations = [:]
        focusRecord = nil
        if problem == nil { suggestions.removeAll { $0.source.kind == .slack } }
        save()
    }

    /// Channels you're in, for "Share to Slack" (cached for 10 minutes).
    func slackChannels(reload: Bool = false) async throws -> [SlackChannel] {
        if !reload, let cached = channelList, Date().timeIntervalSince(cached.fetched) < 600 { return cached.channels }
        guard isSlackConnected, let token = slackToken() else { throw IntegrationError.notConnected(.slack) }
        do {
            let channels = try await slackClient(token).channels()
            channelList = (channels, Date())
            return channels
        } catch {
            let e = IntegrationError.wrap(error, .slack)
            if case .signedOut = e { disconnectSlack(problem: e.errorDescription) }
            throw e
        }
    }

    /// Posts the tasks as a short plan, as you, to `channel`.
    func share(taskIDs: [UUID], to channel: SlackChannel, now: Date = Date()) async throws {
        guard let store else { throw IntegrationError.notConnected(.slack) }
        guard isSlackConnected, let token = slackToken() else { throw IntegrationError.notConnected(.slack) }
        let tasks = taskIDs.compactMap { store.task($0) }
        guard !tasks.isEmpty else { return }
        do {
            try await slackClient(token).post(SlackShare.message(for: tasks, now: now), to: channel.id)
        } catch {
            let e = IntegrationError.wrap(error, .slack)
            if case .signedOut = e { disconnectSlack(problem: e.errorDescription) }
            throw e
        }
    }

    // MARK: Gmail

    /// The Google OAuth client from Settings, the app bundle or the environment.
    var googleClient: GoogleOAuth.Client? {
        guard let id = Secrets.googleClientID, let secret = Secrets.googleClientSecret else { return nil }
        return GoogleOAuth.Client(id: id, secret: secret)
    }

    func saveGoogleClient(id: String, secret: String) {
        Keychain.set(id.trimmingCharacters(in: .whitespacesAndNewlines), for: Keychain.Account.googleClientID)
        Keychain.set(secret.trimmingCharacters(in: .whitespacesAndNewlines), for: Keychain.Account.googleClientSecret)
        google = nil
        googleClientRevision += 1
    }

    private func googleSession() -> GoogleSession? {
        if let google { return google }
        guard let client = googleClient, let refreshToken = Keychain.string(Keychain.Account.googleRefreshToken) else { return nil }
        let session = GoogleSession(client: client, refreshToken: refreshToken, transport: transport)
        google = session
        return session
    }

    private func collectGmail(settings: IntegrationSettings, known: Set<String>, now: Date) async -> [SuggestionCandidate] {
        guard isGmailConnected, let address = gmailAddress else { return [] }
        if let until = gmailPausedUntil, until > now { return [] }
        guard let session = googleSession() else {
            disconnectGmail(problem: googleClient == nil
                ? "Gmail was disconnected: the Google OAuth client is missing. Add it again in Settings → Connections."
                : "Gmail was disconnected: its sign-in is no longer in the keychain. Connect it again in Settings → Connections.")
            return []
        }
        let client = GmailClient(session: session, transport: transport)
        do {
            var refs = try await client.messageRefs(matching: GmailClient.starredQuery, max: 25).map { ($0, SuggestionTrigger.starred) }
            if settings.needsReply {
                refs += try await client.messageRefs(matching: GmailClient.needsReplyQuery, max: 25).map { ($0, SuggestionTrigger.needsReply) }
            }
            // One suggestion per conversation: the newest message (lists come newest first); a star wins.
            var threads = Set<String>()
            let fresh = refs.filter { !known.contains(GmailMessage.externalID(thread: $0.0.threadID)) && threads.insert($0.0.threadID).inserted }
            let messages = try await client.messages(fresh.map { $0.0 })
            let triggers = Dictionary(fresh.map { ($0.0.id, $0.1) }, uniquingKeysWith: { first, _ in first })
            gmailProblem = nil
            gmailPausedUntil = nil
            return messages.compactMap { m in triggers[m.id].map { gmailCandidate(m, trigger: $0, address: address) } }
        } catch {
            handleGmail(error, now: now)
            return []
        }
    }

    private func gmailCandidate(_ m: GmailMessage, trigger: SuggestionTrigger, address: String) -> SuggestionCandidate {
        let sender = m.sender.displayName
        let subject = m.subject.flatMap { $0.isEmpty ? nil : $0 }
        let source = TaskSource(kind: .gmail, externalID: m.externalID, url: GmailClient.threadLink(account: address, threadID: m.threadID),
                                label: [sender, subject].compactMap { $0 }.joined(separator: " · "))
        let suggestion = Suggestion(source: source, from: sender, subject: subject, snippet: m.snippet,
                                    receivedAt: m.date, draft: nil, trigger: trigger)
        let message = IncomingMessage(source: source, from: m.sender.full, subject: subject, text: m.snippet, date: m.date)
        return SuggestionCandidate(suggestion: suggestion, message: message)
    }

    private func handleGmail(_ error: Error, now: Date) {
        let e = IntegrationError.wrap(error, .gmail)
        switch e {
        case .cancelled:
            return
        case .signedOut:
            disconnectGmail(problem: e.errorDescription)
        case .rateLimited(_, let after):
            gmailPausedUntil = now.addingTimeInterval(max(60, after))
            gmailProblem = e.errorDescription
        default:
            gmailProblem = e.errorDescription
        }
    }

    /// Signs in with Google in the default browser (loopback redirect + PKCE), then remembers the account.
    func connectGmail() {
        guard signInTask == nil, !DebugSnapshot.isActive else { return }
        guard let client = googleClient else {
            gmailProblem = "Add your Google OAuth client ID and secret first."
            return
        }
        isSigningInToGmail = true
        gmailProblem = nil
        signInTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let tokens = try await GoogleOAuth.signIn(client: client, transport: transport, open: openURL)
                guard tokens.scopes.isEmpty || tokens.scopes.contains(GoogleOAuth.gmailScope) else {
                    throw IntegrationError.missingPermission(.gmail, "read your email")
                }
                guard let refreshToken = tokens.refreshToken else {
                    throw IntegrationError.api(.google, "Google didn't send a lasting sign-in. Try connecting again.")
                }
                let session = GoogleSession(client: client, refreshToken: refreshToken, transport: transport, tokens: tokens)
                let email = try await GmailClient(session: session, transport: transport).profileEmail()
                Keychain.set(refreshToken, for: Keychain.Account.googleRefreshToken)
                google = session
                gmailAddress = email
                isGmailConnected = true
                gmailPausedUntil = nil
                save()
                NSApplication.shared.activate(ignoringOtherApps: true) // back from the browser
                refresh()
            } catch {
                let e = IntegrationError.wrap(error, .gmail)
                if e != .cancelled && e != .signInCancelled { gmailProblem = e.errorDescription }
            }
            isSigningInToGmail = false
            signInTask = nil
        }
    }

    func cancelGmailSignIn() {
        signInTask?.cancel()
    }

    /// Forgets Gmail. A manual disconnect (no `problem`) also revokes the sign-in at Google and clears
    /// the Gmail suggestions still waiting.
    func disconnectGmail(problem: String? = nil) {
        let refreshToken = Keychain.string(Keychain.Account.googleRefreshToken)
        Keychain.set(nil, for: Keychain.Account.googleRefreshToken)
        if problem == nil, let refreshToken {
            let transport = transport
            Task.detached { await GoogleOAuth.revoke(refreshToken, transport: transport) }
        }
        google = nil
        gmailAddress = nil
        isGmailConnected = false
        gmailProblem = problem
        gmailPausedUntil = nil
        if problem == nil { suggestions.removeAll { $0.source.kind == .gmail } }
        save()
    }

    // MARK: Acting on suggestions

    /// Adds the suggestion as a task (its draft, linked back to the message) and stops suggesting it.
    @discardableResult
    func add(_ suggestion: Suggestion, toast: Bool = true) -> TaskItem? {
        guard let store else { return nil }
        let draft = SuggestionDrafts.prepared(suggestion.draft ?? SuggestionDrafts.fallback(for: suggestion), for: suggestion)
        let task = store.addTask(draft.makeTask(lists: store.lists, source: suggestion.source))
        markHandled([suggestion.id])
        if toast { app?.showToast("Added “\(task.title)”") }
        return task
    }

    func addAll() {
        let all = suggestions
        guard !all.isEmpty else { return }
        for s in all { add(s, toast: false) }
        app?.showToast("Added \(Fmt.plural(all.count, "task"))")
    }

    /// Opens the draft in "Plan with AI" to adjust before adding. The draft carries its source, so the task
    /// it becomes links back, and the suggestion is retired once that task exists.
    func edit(_ suggestion: Suggestion) {
        guard let app else { return }
        let draft = SuggestionDrafts.prepared(suggestion.draft ?? SuggestionDrafts.fallback(for: suggestion), for: suggestion)
        app.aiPlanner = AIPlannerRequest(drafts: [draft])
    }

    func dismiss(_ suggestion: Suggestion) {
        markHandled([suggestion.id])
    }

    /// Opens the message in Slack or Gmail (https links only).
    func open(_ suggestion: Suggestion) {
        guard let url = suggestion.source.url, url.scheme == "https" else { return }
        openURL(url)
    }

    private func markHandled(_ ids: Set<String>, at now: Date = Date()) {
        guard !ids.isEmpty else { return }
        for id in ids { handled[id] = now }
        suggestions.removeAll { ids.contains($0.id) }
        save()
    }

    /// Suggestions whose message is already on a task are done (say, after Edit… in the planner).
    func retireSuggestionsOnTasks() {
        guard let store, !suggestions.isEmpty else { return }
        let onTasks = Set(store.tasks.compactMap { $0.source?.externalID })
        let done = Set(suggestions.map(\.id)).intersection(onTasks)
        markHandled(done)
    }

    // MARK: Focus status (Slack)

    /// A focus session started; `until` is when it ends (nil for a stopwatch). The task title never goes to Slack.
    func focusStarted(until: Date?, taskTitle: String) {
        guard store != nil, isSlackConnected, settings().focusStatus else { return }
        enqueueFocus { [weak self] in await self?.applyFocusStatus(until: until) }
    }

    /// The focus session stopped.
    func focusEnded() {
        guard store != nil else { return }
        enqueueFocus { [weak self] in await self?.clearFocusStatus() }
    }

    /// Waits until queued status changes are done (tests).
    func waitForFocusUpdates() async {
        await focusChain?.value
    }

    /// Status changes run one after another, so "stop, then start again" can't interleave.
    private func enqueueFocus(_ work: @escaping @MainActor () async -> Void) {
        let previous = focusChain
        focusChain = Task { @MainActor in
            await previous?.value
            await work()
        }
    }

    private func applyFocusStatus(until: Date?) async {
        guard isSlackConnected, let account = slackAccount, let token = slackToken() else { return }
        let client = slackClient(token)
        let now = Date()
        // A stopwatch has no end; an hour keeps a forgotten status from lingering.
        let end = until ?? now.addingTimeInterval(3600)
        do {
            let current = try await client.status(of: account.userID)
            // Remember what was there, to put it back afterwards (never our own "Heads down").
            let previous = current.isFocus ? focusRecord?.previous : (current.isEmpty || current.hasExpired(at: now) ? nil : current)
            try await client.setStatus(.focus(until: end))
            var record = SlackFocusRecord(previous: previous, until: end, snoozeUntil: nil)
            focusRecord = record
            save()
            let minutes = max(1, Int((end.timeIntervalSince(now) / 60).rounded(.up)))
            if let snoozeEnd = try? await client.snooze(minutes: minutes) {
                record.snoozeUntil = snoozeEnd
                focusRecord = record
                save()
            }
        } catch {
            let e = IntegrationError.wrap(error, .slack)
            if case .signedOut = e { disconnectSlack(problem: e.errorDescription) } else if e != .cancelled {
                slackProblem = "Couldn't set your Slack status. \(e.errorDescription ?? "")"
            }
        }
    }

    private func clearFocusStatus() async {
        guard let record = focusRecord else { return }
        guard isSlackConnected, let account = slackAccount, let token = slackToken() else {
            focusRecord = nil
            save()
            return
        }
        let client = slackClient(token)
        let now = Date()
        do {
            // Only undo what's still ours: the user may have set something else meanwhile.
            if try await client.status(of: account.userID).isFocus {
                if let previous = record.previous, !previous.hasExpired(at: now) {
                    try await client.setStatus(previous)
                } else {
                    try await client.setStatus(SlackStatus())
                }
            }
            if let snooze = record.snoozeUntil, snooze > now { try? await client.endSnooze() }
            focusRecord = nil
            save()
        } catch {
            let e = IntegrationError.wrap(error, .slack)
            if case .signedOut = e { disconnectSlack(problem: e.errorDescription) }
            // Offline: the record stays, so the next launch tries again (the status expires by itself anyway).
        }
    }

    // MARK: Saving

    private func save() {
        guard let fileURL else { return }
        var file = IntegrationsFile()
        file.suggestions = suggestions
        file.handled = handled
        file.skipped = skipped
        file.lastRefresh = lastRefresh
        file.slack = slackAccount
        file.gmailAddress = gmailAddress
        file.focusStatus = focusRecord
        guard let data = try? file.encoded() else { return }
        // Serial queue: writes land in order.
        saveQueue.async {
            do {
                try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                try data.write(to: fileURL, options: .atomic)
            } catch {
                NSLog("Docket: couldn't save integrations.json (%@)", (error as NSError).localizedDescription)
            }
        }
    }

    /// Waits for pending writes (tests).
    func flushSaves() {
        saveQueue.sync {}
    }
}
