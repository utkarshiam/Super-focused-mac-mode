import AppKit
import SwiftUI

// MARK: - Messages

/// What the header's status line says: Slack, Gmail and AI each with ✓ or what's wrong (and the way to fix
/// it), then when Docket last checked. Pure, so it's easy to test.
enum InboxStatus {
    /// Where clicking a problem goes.
    enum Fix: Equatable {
        /// The Connections sheet.
        case connections
        /// Create the Docket app in Slack again with the new permissions.
        case updateSlack
        /// Sign in to Google again (for starring, sending and drafts).
        case reconnectGmail
        /// Settings → AI.
        case aiSettings
    }

    struct Part: Equatable, Identifiable {
        var name: String
        /// What's wrong, in a few words ("Slack not connected"); nil when all is well.
        var problem: String?
        /// The tooltip: the whole story.
        var help: String
        var fix: Fix?

        var id: String { name }
        var isOK: Bool { problem == nil }
        /// "Slack ✓", or the problem.
        var text: String { problem ?? "\(name) ✓" }
    }

    struct Facts {
        var slackConnected = false
        var slackAccount: String?
        var slackProblem: String?
        /// Why the Docket app in Slack needs to be made again (missing permissions), if it does.
        var slackPermissions: String?
        var gmailConnected = false
        var gmailAddress: String?
        var gmailProblem: String?
        /// Signed in before Docket asked to star and reply.
        var gmailNeedsReconnect = false
        var aiOn = true
        var aiHasKey = true
        var aiProblem: String?
    }

    static func parts(_ f: Facts) -> [Part] {
        let slack: Part
        if !f.slackConnected {
            slack = Part(name: "Slack", problem: "Slack not connected", help: "Click to connect Slack", fix: .connections)
        } else if let problem = f.slackProblem {
            slack = Part(name: "Slack", problem: "Slack error", help: problem + " Click to open Connections.", fix: .connections)
        } else if let permissions = f.slackPermissions {
            slack = Part(name: "Slack", problem: "Slack needs permissions", help: permissions + " Click to update the Docket app in Slack.", fix: .updateSlack)
        } else {
            slack = Part(name: "Slack", help: f.slackAccount.map { "Slack is connected as \($0)" } ?? "Slack is connected")
        }

        let gmail: Part
        if !f.gmailConnected {
            gmail = Part(name: "Gmail", problem: "Gmail not connected", help: "Click to connect Gmail", fix: .connections)
        } else if let problem = f.gmailProblem {
            gmail = Part(name: "Gmail", problem: "Gmail error", help: problem + " Click to open Connections.", fix: .connections)
        } else if f.gmailNeedsReconnect {
            gmail = Part(name: "Gmail", problem: "Reconnect Gmail",
                         help: "Click to sign in to Google again, so Docket can star emails, send your replies and save drafts", fix: .reconnectGmail)
        } else {
            gmail = Part(name: "Gmail", help: f.gmailAddress.map { "Gmail is connected as \($0)" } ?? "Gmail is connected")
        }

        let ai: Part
        if !f.aiOn {
            ai = Part(name: "AI", problem: "AI off", help: "AI is off: no suggested tasks or drafted replies. Click to open Settings → AI.", fix: .aiSettings)
        } else if !f.aiHasKey {
            ai = Part(name: "AI", problem: "AI needs a key", help: "Add a Gemini API key in Settings → AI. Click to open it.", fix: .aiSettings)
        } else if let problem = f.aiProblem {
            ai = Part(name: "AI", problem: "AI error", help: problem + " Click to open Settings → AI.", fix: .aiSettings)
        } else {
            ai = Part(name: "AI", help: "AI suggests tasks and drafts replies")
        }
        return [slack, gmail, ai]
    }

    /// "Updated 11:36 PM" (today), "Updated Mon 5 Oct · 11:36 PM" (before), "Checking…" while it checks.
    static func updated(_ last: Date?, refreshing: Bool, now: Date, calendar: Calendar = .current) -> String? {
        if refreshing { return "Checking…" }
        guard let last else { return nil }
        return calendar.isDate(last, inSameDayAs: now) ? "Updated \(Fmt.time(last))" : "Updated \(Fmt.dateTime(last))"
    }
}

/// Sidebar "Messages": the Slack messages and emails that need you, together (All) or in a tab each. A message opens complete
/// (its files and earlier messages), with one row of actions: add the suggested task, reply, note, dismiss.
struct SuggestionsView: View {
    @EnvironmentObject var store: Store
    @EnvironmentObject var app: AppState
    @ObservedObject private var integrations = Integrations.shared
    @ObservedObject private var ai = AIService.shared
    @AppStorage(Prefs.Key.aiEnabled) private var aiEnabled = true
    /// The tab, remembered across launches: "all", "slack" or "gmail" (an `InboxTab`; empty until one is picked).
    @AppStorage(SuggestionsView.tabKey) private var tabName = ""
    @StateObject private var inbox = InboxModel()
    @State private var sheet: ConnectionsSheet.Opening?

    static let tabKey = "inboxTab"

    var body: some View {
        let tab = currentTab
        VStack(alignment: .leading, spacing: 0) {
            header(tab)
            InboxBanners()
            Rectangle().fill(Color.hair).frame(height: 1)
            InboxPanes(model: inbox, tab: tab, connect: { sheet = .plain }, updateSlack: updateSlack)
                .id(tab)
                .transition(.opacity)
        }
        .background(Color.paper)
        .sheet(item: $sheet) { opening in
            ConnectionsSheet(opening: opening)
                .environmentObject(store)
                .environmentObject(app)
        }
        .onAppear {
            inbox.startWatchingKeys(app: app)
            revealRequested()
        }
        .onDisappear { inbox.stopWatchingKeys() }
        .onChange(of: app.messageToReveal) { _ in revealRequested() }
    }

    /// Opens the message a notification or the menu bar asked for: in this tab when it shows there, else in
    /// All; with Starred on and the message not starred, the filter goes off.
    private func revealRequested() {
        guard let id = app.messageToReveal else { return }
        app.messageToReveal = nil
        guard let item = integrations.suggestion(id) else { return }
        let tab = InboxReveal.tab(for: item.source.kind, current: currentTab)
        if tab != currentTab { tabName = tab.rawValue }
        if inbox.isStarredOnly(tab), !item.isStarred { inbox.setStarredOnly(false, for: tab) }
        inbox.select(item.id, in: tab)
        // After the tab's panes appear (they start on the list in a narrow window).
        DispatchQueue.main.async {
            inbox.select(item.id, in: tab)
            if inbox.isNarrow { withAnimation(Motion.snappy) { inbox.showsDetail = true } }
        }
    }

    /// The tab picked last; before any was picked, All when Slack and Gmail are both in use, else the one that is.
    private var currentTab: InboxTab {
        let slack = integrations.isSlackConnected || integrations.suggestions.contains { $0.source.kind == .slack }
        let gmail = integrations.isGmailConnected || integrations.suggestions.contains { $0.source.kind == .gmail }
        return InboxTab.current(stored: tabName, slack: slack, gmail: gmail)
    }

    private func count(_ tab: InboxTab) -> Int {
        integrations.suggestions.lazy.filter { tab.includes($0.source.kind) }.count
    }

    /// Opens Slack's "Create an app" with the new permissions, and the two steps that finish the update.
    private func updateSlack() {
        NSWorkspace.shared.open(SlackManifest.createAppURL)
        sheet = .updateSlack
    }

    /// Every message in the tab as a task, as one undo step.
    private func addAll(_ items: [Suggestion]) {
        guard items.count >= 2 else { return }
        // Notes still being typed go into their task: the items as they are once those are saved.
        NotificationCenter.default.post(name: InboxModel.saveEditsNow, object: nil)
        let current = items.map { integrations.suggestion($0.id) ?? $0 }
        let undo = store.undoManager
        undo?.beginUndoGrouping()
        let added = withAnimation(Motion.gentle) { current.compactMap { integrations.add($0, toast: false) } }
        undo?.setActionName("Add Tasks")
        undo?.endUndoGrouping()
        if !added.isEmpty { app.showToast("Added \(Fmt.plural(added.count, "task"))") }
    }

    // MARK: Header

    /// "Messages" over the status line, the tabs, refresh and ⋯ on the right (under, when it's narrow).
    private func header(_ tab: InboxTab) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .center, spacing: Space.md) {
                titleBlock
                Spacer(minLength: Space.md)
                headerControls(tab)
            }
            VStack(alignment: .leading, spacing: Space.md) {
                titleBlock
                headerControls(tab)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, Space.gutter)
        .padding(.top, Space.lg)
        .padding(.bottom, Space.lg)
    }

    private var titleBlock: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Messages")
                .textStyle(.largeTitle)
                .foregroundStyle(Color.ink)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            statusLine
        }
    }

    private var statusFacts: InboxStatus.Facts {
        let permissions = InboxItemText.slackPermissionBanner(missing: integrations.missingSlackScopes) ?? integrations.slackScopeWarning
        return InboxStatus.Facts(
            slackConnected: integrations.isSlackConnected,
            slackAccount: integrations.slackAccount.map { "@\($0.userName) in \($0.teamName)" },
            slackProblem: integrations.slackProblem,
            slackPermissions: permissions,
            gmailConnected: integrations.isGmailConnected,
            gmailAddress: integrations.gmailAddress,
            gmailProblem: integrations.gmailProblem,
            gmailNeedsReconnect: !integrations.gmailCanModify,
            aiOn: aiEnabled,
            // Screenshot mode never calls out, so it has no key to use: it shows AI as set up.
            aiHasKey: ai.isConfigured || DebugSnapshot.isActive,
            aiProblem: integrations.aiProblem)
    }

    /// "Slack ✓ · Gmail ✓ · AI ✓ · Updated 11:36 PM": a problem shows in place of its ✓, and a click fixes it.
    /// When it doesn't fit, the ✓s go first.
    private var statusLine: some View {
        let parts = InboxStatus.parts(statusFacts)
        let updated = InboxStatus.updated(integrations.lastRefresh, refreshing: integrations.isRefreshing, now: app.clock)
        let problems = parts.filter { !$0.isOK }
        return ViewThatFits(in: .horizontal) {
            statusRow(parts, updated: updated)
            statusRow(problems, updated: updated)
            statusRow(problems, updated: nil)
            statusRow(Array(problems.prefix(1)), updated: nil)
        }
        .animation(Motion.base, value: parts)
    }

    private func statusRow(_ parts: [InboxStatus.Part], updated: String?) -> some View {
        HStack(spacing: 6) {
            ForEach(Array(parts.enumerated()), id: \.element.id) { i, part in
                if i > 0 { Text("·").foregroundStyle(Color.ink3) }
                statusPart(part)
            }
            if let updated {
                if !parts.isEmpty { Text("·").foregroundStyle(Color.ink3) }
                Text(updated)
                    .monospacedDigit()
                    .foregroundStyle(Color.ink2)
                    .help(integrations.isRefreshing ? "Checking Slack and Gmail now" : "When Docket last checked Slack and Gmail")
            }
        }
        .textStyle(.callout)
        .lineLimit(1)
        .fixedSize()
    }

    @ViewBuilder
    private func statusPart(_ part: InboxStatus.Part) -> some View {
        if let fix = part.fix, !part.isOK {
            Button { perform(fix) } label: {
                HStack(spacing: 4) {
                    Image(systemName: "exclamationmark.circle.fill")
                        .font(.system(size: 11, weight: .semibold))
                    Text(part.text)
                        .underline()
                }
                .foregroundStyle(Color.dangerText)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(fix == .reconnectGmail && integrations.isSigningInToGmail)
            .help(part.help)
        } else {
            Text(part.text)
                .foregroundStyle(Color.ink2)
                .help(part.help)
        }
    }

    private func perform(_ fix: InboxStatus.Fix) {
        switch fix {
        case .connections: sheet = .plain
        case .updateSlack: updateSlack()
        case .reconnectGmail: integrations.connectGmail()
        case .aiSettings: SettingsView.show(.ai, app: app)
        }
    }

    private func headerControls(_ tab: InboxTab) -> some View {
        HStack(spacing: Space.sm) {
            SegmentedControl(selection: Binding(get: { tab }, set: { tabName = $0.rawValue }),
                             options: InboxTab.allCases.map { ($0, "\($0.title) (\(count($0)))") })
                .help("Slack messages and emails together, or one at a time")
            if integrations.isAnyConnected {
                Button { integrations.refresh() } label: {
                    if integrations.isRefreshing {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: "arrow.clockwise")
                    }
                }
                .buttonStyle(IconButtonStyle(filled: true))
                .disabled(integrations.isRefreshing)
                .help("Check Slack and Gmail now")
            }
            Menu {
                // What the list shows: with Starred on, the starred ones.
                let items = inbox.items(tab, in: integrations)
                Button(items.count >= 2 ? "Add All \(items.count) as Tasks" : "Add All as Tasks") { addAll(items) }
                    .disabled(items.count < 2)
                Divider()
                Button("Check Setup…") { sheet = .checkSetup }
                Button("Connections…") { sheet = .plain }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Color.ink)
                    .frame(width: 32, height: 32)
            }
            .menuChrome(Circle())
            .help("Add all as tasks, check that everything works, or set up Slack and Gmail")
        }
    }
}

/// Under the header, only while Gmail is being reconnected from the status line: waiting for the browser, the
/// way to stop, and what to do when Google says "Access blocked". Every other problem is in the status line.
private struct InboxBanners: View {
    @ObservedObject private var integrations = Integrations.shared

    var body: some View {
        let shown = integrations.isGmailConnected && integrations.isSigningInToGmail
        VStack(alignment: .leading, spacing: Space.sm) {
            if shown {
                BannerLine(icon: "globe", text: "Finish signing in to Google in your browser.") {
                    ProgressView().controlSize(.small)
                    Button("Cancel") { integrations.cancelGmailSignIn() }
                        .buttonStyle(SecondaryPill(height: 28))
                        .help("Stop waiting for the browser")
                }
                GmailSignInHint()
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, Space.gutter)
        .padding(.bottom, shown ? Space.md : 0)
        .animation(Motion.base, value: shown)
    }
}

/// While Docket waits for the Google sign-in in the browser. When the address isn't a test user of the OAuth
/// app (External, in testing), Google says "Access blocked" on its own page and never comes back to Docket:
/// what to do about it, and the way to Google Cloud's Audience page.
struct GmailSignInHint: View {
    static let question = "Seeing “Access blocked”?"
    static let answer = "Add your Google address under Test users in Google Cloud (Google Auth Platform → Audience), then try again."
    static var text: String { question + " " + answer }
    static let audienceURL = URL(string: "https://console.cloud.google.com/auth/audience")!

    /// A line under a banner; centred under a pitch; a row of a settings card.
    enum Style { case line, centered, settingsRow }
    var style: Style = .line

    var body: some View {
        switch style {
        case .line:
            HStack(alignment: .center, spacing: Space.sm) {
                Image(systemName: "questionmark.circle")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Color.ink2)
                Text(Self.text)
                    .textStyle(.footnote)
                    .foregroundStyle(Color.ink2)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: Space.sm)
                link(height: 28)
            }
            .transition(.opacity)
        case .centered:
            VStack(spacing: Space.sm) {
                Text(Self.text)
                    .textStyle(.footnote)
                    .foregroundStyle(Color.ink3)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                link(height: 28)
            }
        case .settingsRow:
            SettingsRow(title: Self.question, subtitle: Self.answer) { link(height: 30) }
        }
    }

    private func link(height: CGFloat) -> some View {
        Button { NSWorkspace.shared.open(Self.audienceURL) } label: { Label("Open Audience", systemImage: "arrow.up.right") }
            .buttonStyle(SecondaryPill(height: height))
            .help("Opens Google Auth Platform → Audience in Google Cloud, where you add test users")
    }
}

/// A one-line banner: a small icon, what's up, and what to do about it. No box.
private struct BannerLine<Trailing: View>: View {
    let icon: String
    let text: String
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(alignment: .center, spacing: Space.sm) {
            Image(systemName: icon)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Color.ink2)
            Text(text)
                .textStyle(.footnote)
                .foregroundStyle(Color.ink)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: Space.sm)
            trailing
        }
        .transition(.opacity)
    }
}

/// A status line under a header: plain text with a small warning mark, no box.
private struct ProblemLine: View {
    let text: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Color.warning)
            Text(text)
                .textStyle(.footnote)
                .foregroundStyle(Color.ink2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .transition(.opacity)
    }
}

/// The Connections page in a sheet over the main window, so connecting doesn't mean hunting through Settings.
private struct ConnectionsSheet: View {
    /// What it opens for: the page as it is, with the steps for updating the Docket app in Slack, or running
    /// "Check setup" at once.
    enum Opening: String, Identifiable {
        case plain, updateSlack, checkSetup
        var id: String { rawValue }
    }

    let opening: Opening
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Connections")
                    .textStyle(.title2)
                    .foregroundStyle(Color.ink)
                Spacer()
                Button("Done") { dismiss() }
                    .buttonStyle(SecondaryPill(height: 32))
                    .keyboardShortcut(.cancelAction)
                    .help("Close (Esc)")
            }
            .padding(.horizontal, Space.xxl)
            .padding(.top, Space.xl)
            .padding(.bottom, Space.md)
            Rectangle().fill(Color.hair).frame(height: 1)
            ConnectionsSettingsPage(updatingSlack: opening == .updateSlack, checksOnAppear: opening == .checkSetup)
        }
        // The Settings window's size; short enough for the smallest main window (600 pt).
        .frame(width: 620, height: 540)
        .background(Color.paper)
        .tint(Color.ink)
    }
}

// MARK: - Settings → Connections

/// Settings → Connections: "Check setup", then Slack and Gmail as guided checklists (once set up: who it's
/// connected as and its switches), then how suggestions are found.
struct ConnectionsSettingsPage: View {
    @EnvironmentObject var app: AppState
    @ObservedObject private var integrations = Integrations.shared
    @ObservedObject private var ai = AIService.shared
    /// The Docket app in Slack is being made again (new permissions).
    @State private var updatingSlack: Bool
    let checksOnAppear: Bool

    private static let slackID = "connections-slack"
    private static let gmailID = "connections-gmail"

    init(updatingSlack: Bool = false, checksOnAppear: Bool = false) {
        _updatingSlack = State(initialValue: updatingSlack)
        self.checksOnAppear = checksOnAppear
    }

    var body: some View {
        // Slack's next step is the page's primary button until Slack is done; then Gmail's.
        let slackDone = integrations.isSlackConnected && SlackConnection.permissionsComplete(integrations)
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: Space.xxl) {
                    SetupCheckSection(runOnAppear: checksOnAppear) { fix in perform(fix, proxy: proxy) }
                    SlackConnection(integrations: integrations, aiOn: ai.isConfigured, leads: !slackDone, updating: $updatingSlack)
                        .id(Self.slackID)
                    GmailConnection(integrations: integrations, aiOn: ai.isConfigured, leads: slackDone)
                        .id(Self.gmailID)
                    if integrations.isAnyConnected {
                        SuggestionSettings(integrations: integrations, aiOn: ai.isConfigured)
                    }
                }
                .padding(.horizontal, Space.xxl)
                .padding(.vertical, Space.xl)
            }
        }
    }

    private func perform(_ fix: SetupCheckItem.Fix, proxy: ScrollViewProxy) {
        switch fix {
        case .setUpSlack:
            withAnimation(Motion.gentle) { proxy.scrollTo(Self.slackID, anchor: .top) }
        case .updateSlack:
            NSWorkspace.shared.open(SlackManifest.createAppURL)
            updatingSlack = true
            withAnimation(Motion.gentle) { proxy.scrollTo(Self.slackID, anchor: .top) }
        case .setUpGmail:
            withAnimation(Motion.gentle) { proxy.scrollTo(Self.gmailID, anchor: .top) }
        case .signInGmail:
            withAnimation(Motion.gentle) { proxy.scrollTo(Self.gmailID, anchor: .top) }
            if integrations.googleClient != nil { integrations.connectGmail() }
        case .aiSettings:
            SettingsView.show(.ai, app: app)
        }
    }
}

private struct SlackConnection: View {
    @ObservedObject var integrations: Integrations
    let aiOn: Bool
    /// Its next step is the page's primary button.
    let leads: Bool
    @Binding var updating: Bool
    @AppStorage(Prefs.Key.slackSaveEmoji) private var saveEmoji = SlackSaveEmoji.standard
    @AppStorage(Prefs.Key.slackMentions) private var mentions = true
    @AppStorage(Prefs.Key.slackDirectMessages) private var directMessages = true
    @AppStorage(Prefs.Key.slackFocusStatus) private var focusStatus = true
    @AppStorage(Prefs.Key.setupTickedSlack) private var tickedRaw = ""
    @State private var token = ""
    @State private var connecting = false
    @State private var problem: String?
    /// The updated app's token was just connected: time to delete the old app.
    @State private var updated = false
    @State private var showsSteps = false

    /// The token has every permission Docket asks for (as far as Docket knows).
    static func permissionsComplete(_ integrations: Integrations) -> Bool {
        integrations.missingSlackScopes.isEmpty && integrations.slackScopeWarning == nil
    }

    private var steps: [SetupStep] {
        SetupSteps.slack(SetupSteps.SlackFacts(connected: integrations.isSlackConnected,
                                               permissionsComplete: Self.permissionsComplete(integrations)),
                         ticked: SetupSteps.ticked(tickedRaw))
    }

    var body: some View {
        let steps = self.steps
        let complete = steps.allSatisfy(\.done)
        SettingsSection(title: "Slack", footer: "Your own Slack app, so messages go straight from Slack to this Mac. The token stays on this Mac, in a file only you can read.") {
            if let issue = integrations.slackProblem { IssueRow(text: issue) }
            if let account = integrations.slackAccount, integrations.isSlackConnected {
                SettingsRow(title: "Connected as @\(account.userName) in \(account.teamName)", subtitle: account.teamURL?.host) {
                    Button("Disconnect") { withAnimation(Motion.base) { integrations.disconnectSlack() } }
                        .buttonStyle(SecondaryPill(height: 30))
                        .help("Forget the Slack token and the Slack messages waiting")
                }
            }
            if complete && !showsSteps && !updating {
                SetupDoneRow(count: steps.count) { withAnimation(Motion.snappy) { showsSteps = true } }
            } else {
                SetupChecklist(steps: steps, leads: leads, ticked: tickedBinding, email: .constant(""),
                               forceOpen: updating ? "slack.permissions" : nil) { step, leads in
                    switch step.id {
                    case "slack.token": tokenEntry(leads: leads, cancel: nil)
                    case "slack.permissions" where integrations.isSlackConnected: permissionsExtra(leads: leads)
                    default: EmptyView()
                    }
                }
                .overlay(alignment: .bottom) {
                    if integrations.isSlackConnected || updated { Rectangle().fill(Color.hair).frame(height: 1).padding(.leading, Space.lg) }
                }
            }
            if updated {
                SettingsRow(title: "Updated. Now delete the old Docket app",
                            subtitle: "On your Slack apps page, open the old Docket app, then Basic Information → Delete App at the bottom.") {
                    Button { NSWorkspace.shared.open(SetupSteps.slackAppsPage) } label: { Label("Your apps", systemImage: "arrow.up.right") }
                        .buttonStyle(SecondaryPill(height: 30))
                        .help("Opens your apps on api.slack.com in your browser")
                }
            }
            if integrations.isSlackConnected {
                SettingsRow(title: "Save with a reaction",
                            subtitle: "React to a message (from the last 30 days) with this and it shows up in Messages.") {
                    ChoiceMenu(selection: $saveEmoji, options: emojiOptions)
                        .help("The reaction that saves a message to Docket")
                }
                ToggleRow(title: "Mentions",
                          subtitle: aiOn ? "Messages that @mention you (last 3 days). AI keeps only the ones that need you."
                              : "Every message that @mentions you (last 3 days). Turn on AI to keep only the ones that need you.",
                          isOn: $mentions)
                    .help("Suggest tasks from messages that mention you")
                ToggleRow(title: "Direct messages",
                          subtitle: aiOn ? "What people send you in DMs and group DMs (last 3 days), the newest of each conversation. AI keeps only the ones that need you."
                              : "What people send you in DMs and group DMs (last 3 days), the newest of each conversation. Turn on AI to keep only the ones that need you.",
                          isOn: $directMessages)
                    .help("Suggest tasks from direct and group messages people send you")
                ToggleRow(title: "Focus status", subtitle: "During a focus session your status says “Heads down” 🎯 and notifications are paused.",
                          isOn: $focusStatus, divider: false)
                    .help("Set your Slack status and pause notifications while you focus")
            }
        }
        .onChange(of: saveEmoji) { _ in integrations.refresh() }
        .onChange(of: mentions) { _ in integrations.refresh() }
        .onChange(of: directMessages) { _ in integrations.refresh() }
    }

    private var tickedBinding: Binding<Set<String>> {
        Binding(get: { SetupSteps.ticked(tickedRaw) }, set: { tickedRaw = SetupSteps.raw($0) })
    }

    /// Making the app again: what's missing, the new token, and the way to the old app afterwards.
    @ViewBuilder
    private func permissionsExtra(leads: Bool) -> some View {
        if let missing = InboxItemText.slackPermissionBanner(missing: integrations.missingSlackScopes) ?? integrations.slackScopeWarning {
            Text(missing + " " + InboxItemText.slackPermissionEffect(missing: integrations.missingSlackScopes))
                .textStyle(.footnote)
                .foregroundStyle(Color.ink)
                .fixedSize(horizontal: false, vertical: true)
        }
        tokenEntry(leads: leads, cancel: updating ? { withAnimation(Motion.base) { updating = false } } : nil)
    }

    /// The token field and Connect, with what went wrong under it.
    @ViewBuilder
    private func tokenEntry(leads: Bool, cancel: (() -> Void)?) -> some View {
        VStack(alignment: .leading, spacing: Space.xs) {
            HStack(spacing: Space.sm) {
                SecureField("xoxp-…", text: $token)
                    .connectionField()
                    .onSubmit(connect)
                    .help("Paste the User OAuth Token from your Slack app (it starts with xoxp-)")
                if let cancel {
                    Button("Cancel") {
                        token = ""
                        problem = nil
                        cancel()
                    }
                    .buttonStyle(SecondaryPill(height: 32))
                    .help("Keep the app you have")
                }
                Button(connecting ? "Connecting…" : "Connect", action: connect)
                    .buttonStyle(LeadPill(primary: leads, height: 32))
                    .disabled(token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || connecting)
                    .help("Check the token with Slack and connect")
            }
            if let problem {
                Text(problem)
                    .textStyle(.footnote)
                    .foregroundStyle(Color.dangerText)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// The standard choices, plus one set some other way (say, with `defaults write`) so the menu never reads blank.
    private var emojiOptions: [(String, String)] {
        var options = SlackSaveEmoji.choices.map { ($0.name, "\($0.glyph)  \(SlackSaveEmoji.title($0.name))") }
        let current = SlackSaveEmoji.normalized(saveEmoji)
        if !options.contains(where: { $0.0 == saveEmoji }) {
            options.append((saveEmoji, ":\(current):"))
        }
        return options
    }

    private func connect() {
        let value = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, !connecting else { return }
        // A token for an app made again: afterwards, the old one is to be deleted.
        let replacing = integrations.isSlackConnected
        connecting = true
        problem = nil
        Task {
            do {
                try await integrations.connectSlack(token: value)
                token = ""
                withAnimation(Motion.base) {
                    updating = false
                    if replacing { updated = true }
                }
            } catch {
                problem = error.localizedDescription
            }
            connecting = false
        }
    }
}

private struct GmailConnection: View {
    @ObservedObject var integrations: Integrations
    let aiOn: Bool
    /// Its next step is the page's primary button (Slack is done).
    let leads: Bool
    @AppStorage(Prefs.Key.gmailNeedsReply) private var needsReply = true
    @AppStorage(Prefs.Key.setupTickedGmail) private var tickedRaw = ""
    @AppStorage(Prefs.Key.setupGoogleAddress) private var typedAddress = ""
    @State private var clientID = ""
    @State private var clientSecret = ""
    @State private var changingClient = false
    @State private var showsSteps = false

    /// What Docket does with Gmail, in so many words.
    static let promise = "Docket reads your mail, stars what you star, and sends or saves a draft only when you click Send or Save draft. It never deletes or archives anything."

    /// What the sign-in allows: everything (the promise), or what reconnecting adds. Sign-ins from before
    /// Docket starred emails can't star; ones from before it replied can't send either.
    private var connectedSubtitle: String {
        if integrations.gmailCanModify { return Self.promise }
        if integrations.gmailCanCompose { return "Docket can read your mail and send your replies. Sign in again to star emails from Docket too." }
        return "Docket can read your mail. Sign in again to star and reply from Docket too."
    }

    private var steps: [SetupStep] {
        SetupSteps.gmail(SetupSteps.GmailFacts(hasClient: integrations.googleClient != nil && !changingClient,
                                               connected: integrations.isGmailConnected, canModify: integrations.gmailCanModify),
                         ticked: SetupSteps.ticked(tickedRaw))
    }

    var body: some View {
        let steps = self.steps
        let complete = steps.allSatisfy(\.done)
        SettingsSection(title: "Gmail", footer: "Your own Google sign-in, so mail goes straight from Google to this Mac. Docket never sees your password. While the Google app is in testing, Google signs Docket out every 7 days: just sign in again.") {
            if let issue = integrations.gmailProblem { IssueRow(text: issue) }
            if let email = integrations.gmailAddress, integrations.isGmailConnected {
                SettingsRow(title: "Connected as \(email)", subtitle: connectedSubtitle) {
                    Button("Disconnect") { withAnimation(Motion.base) { integrations.disconnectGmail() } }
                        .buttonStyle(SecondaryPill(height: 30))
                        .help("Sign Docket out of Gmail")
                }
            }
            if complete && !showsSteps && !changingClient {
                SetupDoneRow(count: steps.count) { withAnimation(Motion.snappy) { showsSteps = true } }
            } else {
                SetupChecklist(steps: steps, leads: leads, ticked: tickedBinding, email: addressBinding,
                               forceOpen: changingClient ? "gmail.paste" : nil) { step, leads in
                    switch step.id {
                    case "gmail.paste": clientEntry(leads: leads)
                    case "gmail.signIn": signIn(leads: leads)
                    default: EmptyView()
                    }
                }
                .overlay(alignment: .bottom) {
                    if integrations.isGmailConnected || (integrations.googleClient != nil && !changingClient) {
                        Rectangle().fill(Color.hair).frame(height: 1).padding(.leading, Space.lg)
                    }
                }
            }
            if integrations.isGmailConnected {
                SettingsRow(title: "Starred emails",
                            subtitle: "Emails you star (last 30 days) show up in Messages. Starring one in Docket stars it in Gmail too.") {
                    Badge(text: "On", tone: .neutral, icon: "star")
                }
                ToggleRow(title: "Needs a reply",
                          subtitle: aiOn ? "Unread, important emails from the last 2 days. AI keeps only the ones that need you."
                              : "Unread, important emails from the last 2 days. Turn on AI to keep only the ones that need you.",
                          isOn: $needsReply)
                    .help("Suggest tasks from unread, important email")
            }
            if let client = integrations.googleClient, !changingClient {
                SettingsRow(title: "OAuth client", subtitle: client.id, divider: false) {
                    Button("Change…") {
                        clientID = client.id
                        clientSecret = ""
                        withAnimation(Motion.base) { changingClient = true }
                    }
                    .buttonStyle(SecondaryPill(height: 30))
                    .disabled(integrations.isSigningInToGmail)
                    .help("Use a different Google OAuth client")
                }
            }
        }
        .onChange(of: needsReply) { _ in integrations.refresh() }
    }

    private var tickedBinding: Binding<Set<String>> {
        Binding(get: { SetupSteps.ticked(tickedRaw) }, set: { tickedRaw = SetupSteps.raw($0) })
    }

    /// The address the copy buttons copy: the one typed, else the one Gmail is connected as.
    private var addressBinding: Binding<String> {
        Binding(get: { typedAddress.isEmpty ? (integrations.gmailAddress ?? "") : typedAddress },
                set: { typedAddress = $0.trimmingCharacters(in: .whitespacesAndNewlines) })
    }

    /// The client ID and secret, and Save.
    private func clientEntry(leads: Bool) -> some View {
        VStack(alignment: .leading, spacing: Space.sm) {
            TextField("Client ID (ends in .apps.googleusercontent.com)", text: $clientID)
                .connectionField()
                .help("The Client ID of your Desktop app client")
            SecureField("Client secret", text: $clientSecret)
                .connectionField()
                .onSubmit(saveClient)
                .help("The Client secret of the same client")
            HStack(spacing: Space.sm) {
                Spacer()
                if changingClient {
                    Button("Cancel") { withAnimation(Motion.base) { changingClient = false } }
                        .buttonStyle(SecondaryPill(height: 30))
                        .help("Keep the current OAuth client")
                }
                Button("Save", action: saveClient)
                    .buttonStyle(LeadPill(primary: leads, height: 30))
                    .disabled(!canSave)
                    .help("Save the Client ID and secret on this Mac")
            }
        }
    }

    /// Sign in (or again), what Google will say on the way, and what to do when it says "Access blocked".
    @ViewBuilder
    private func signIn(leads: Bool) -> some View {
        if integrations.isSigningInToGmail {
            HStack(spacing: Space.sm) {
                ProgressView().controlSize(.small)
                Text("Finish signing in in your browser…")
                    .textStyle(.footnote)
                    .foregroundStyle(Color.ink)
                Spacer(minLength: Space.sm)
                Button("Cancel") { integrations.cancelGmailSignIn() }
                    .buttonStyle(SecondaryPill(height: 30))
                    .help("Stop waiting for the browser")
            }
        } else {
            Button(integrations.isGmailConnected ? "Sign in again" : "Sign in with Google") { integrations.connectGmail() }
                .buttonStyle(LeadPill(primary: leads, height: 30))
                .disabled(integrations.googleClient == nil)
                .help("Opens Google sign-in in your browser")
        }
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: "questionmark.circle")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Color.ink2)
            Text(GmailSignInHint.text)
                .textStyle(.footnote)
                .foregroundStyle(Color.ink2)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var canSave: Bool {
        !clientID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !clientSecret.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func saveClient() {
        guard canSave else { return }
        integrations.saveGoogleClient(id: clientID, secret: clientSecret)
        clientID = ""
        clientSecret = ""
        withAnimation(Motion.base) { changingClient = false }
    }
}

private struct SuggestionSettings: View {
    @ObservedObject var integrations: Integrations
    let aiOn: Bool
    @AppStorage(Prefs.Key.checkMessagesOften) private var checksOften = true
    @AppStorage(Prefs.Key.notifyNewMessages) private var notifies = true

    var body: some View {
        SettingsSection(title: "Suggestions",
                        footer: aiOn ? "With AI on, new messages Docket finds (a Slack message with its channel and sender; an email's sender, subject and preview) go to Google Gemini to pick out what needs a task and write it. When you click Draft with AI, the message, its thread and your notes go to Gemini to write the reply. Turn AI off in Settings → AI to keep them on this Mac."
                            : "Everything stays on this Mac.") {
            if let issue = integrations.aiProblem { IssueRow(text: issue) }
            SettingsRow(title: "Check for new messages", subtitle: checkedSubtitle) {
                Button(integrations.isRefreshing ? "Checking…" : "Check now") { integrations.refresh() }
                    .buttonStyle(SecondaryPill(height: 30))
                    .disabled(integrations.isRefreshing)
                    .help("Check Slack and Gmail now")
            }
            ToggleRow(title: "Check Slack and email every 2 minutes",
                      subtitle: "A quick look for new messages while your Mac is awake and unlocked. Off: every 15 minutes.",
                      isOn: $checksOften)
                .help("Look for new Slack messages and emails every 2 minutes")
            ToggleRow(title: "Notify me about new messages",
                      subtitle: "A notification for each new message someone sends you (one summary for more than 3). Held during a focus session.",
                      isOn: $notifies)
                .help("Show a notification when a new Slack message or email comes in")
            SettingsRow(title: "Sort with AI",
                        subtitle: aiOn ? "Gemini picks out what needs you and writes the task."
                            : "Turn on AI in Settings → AI (it needs a Gemini API key) to use this.",
                        divider: false) {
                Badge(text: aiOn ? "On" : "Off", tone: aiOn ? .success : .neutral, icon: aiOn ? "sparkles" : nil)
            }
        }
    }

    private var checkedSubtitle: String {
        var text = checksOften ? "Every 2 minutes, and when you come back to Docket." : "Every 15 minutes, and when you come back to Docket."
        if let last = integrations.lastRefresh {
            text += Calendar.current.isDateInToday(last) ? " Last checked \(Fmt.time(last))." : " Last checked \(Fmt.dateTime(last))."
        }
        return text
    }
}

/// A problem inside a settings card, at the top.
private struct IssueRow: View {
    let text: String

    var body: some View {
        ProblemLine(text: text)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, Space.lg)
            .padding(.vertical, 10)
            .overlay(alignment: .bottom) { Rectangle().fill(Color.hair).frame(height: 1).padding(.leading, Space.lg) }
    }
}

private extension View {
    /// A text field on a soft fill, like the list editor's.
    func connectionField() -> some View {
        textFieldStyle(.plain)
            .font(.system(size: 13.5, weight: .medium))
            .foregroundStyle(Color.ink)
            .padding(.horizontal, 12)
            .frame(height: 32)
            .background(RoundedRectangle(cornerRadius: Radius.sm, style: .continuous).fill(Color.fill))
    }
}

// MARK: - Sources on tasks

/// Icons and names per source. SF Symbols only, no brand logos.
enum SourceStyle {
    static func icon(_ kind: TaskSource.Kind) -> String {
        switch kind {
        case .slack: "number"
        case .gmail: "envelope"
        case .ai: "sparkles"
        }
    }

    static func name(_ kind: TaskSource.Kind) -> String {
        switch kind {
        case .slack: "Slack"
        case .gmail: "Gmail"
        case .ai: "AI"
        }
    }

    static func openTitle(_ kind: TaskSource.Kind) -> String {
        kind == .ai ? "Open link" : "Open in \(name(kind))"
    }
}

/// Tiny "Slack" / "Gmail" mark in a task row's meta line.
struct SourceBadge: View {
    let source: TaskSource

    init(source: TaskSource) {
        self.source = source
    }

    var body: some View {
        let name = SourceStyle.name(source.kind)
        HStack(spacing: 4) {
            Image(systemName: SourceStyle.icon(source.kind)).font(.system(size: 10, weight: .semibold))
            Text(name)
        }
        .foregroundStyle(Color.ink3)
        .lineLimit(1)
        .fixedSize()
        .help(source.label.isEmpty ? "From \(name)" : "From \(name): \(source.label)")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("From \(name)")
    }
}

/// "Open in Slack" / "Open in Gmail" in the task detail, when the task has a link back.
struct SourceLinkButton: View {
    @EnvironmentObject var store: Store
    let taskID: UUID

    init(taskID: UUID) {
        self.taskID = taskID
    }

    var body: some View {
        if let source = store.task(taskID)?.source, let url = source.url, url.scheme == "https" {
            Button { NSWorkspace.shared.open(url) } label: {
                Label(SourceStyle.openTitle(source.kind), systemImage: SourceStyle.icon(source.kind))
            }
            .buttonStyle(SecondaryPill())
            .help(source.label.isEmpty ? "See the original message" : source.label)
        }
    }
}

// MARK: - Share to Slack

/// Posts the given tasks to a Slack channel. Hidden when Slack isn't connected.
struct ShareToSlackButton: View {
    @EnvironmentObject var store: Store
    @EnvironmentObject var app: AppState
    @ObservedObject private var integrations = Integrations.shared
    let taskIDs: [UUID]
    /// Matches the pill next to it: the bulk edit panel's "Copy as checklist" is a standard 36 pt SecondaryPill.
    var height: CGFloat = 36
    @State private var showing = false

    init(taskIDs: [UUID], height: CGFloat = 36) {
        self.taskIDs = taskIDs
        self.height = height
    }

    var body: some View {
        if integrations.isSlackConnected {
            // The full label where there's room; next to "Copy as checklist" in the 370 pt panel, the short one.
            ViewThatFits(in: .horizontal) {
                button("Share to Slack…")
                button("Slack…")
            }
            .popover(isPresented: $showing, arrowEdge: .bottom) {
                // Popovers don't always carry the window's environment objects.
                ShareToSlackPopover(taskIDs: taskIDs) { showing = false }
                    .environmentObject(store)
                    .environmentObject(app)
            }
        }
    }

    private func button(_ title: String) -> some View {
        Button { showing = true } label: { Label(title, systemImage: "paperplane") }
            .buttonStyle(SecondaryPill(height: height))
            .disabled(taskIDs.isEmpty)
            .help("Post these tasks to a Slack channel, as you")
    }
}

private struct ShareToSlackPopover: View {
    @EnvironmentObject var store: Store
    @EnvironmentObject var app: AppState
    @ObservedObject private var integrations = Integrations.shared
    let taskIDs: [UUID]
    let close: () -> Void
    @AppStorage(Prefs.Key.slackShareChannel) private var lastChannel = ""
    @State private var channels: [SlackChannel] = []
    @State private var loading = true
    @State private var filter = ""
    @State private var selected: String?
    @State private var posting = false
    @State private var problem: String?

    var body: some View {
        let tasks = taskIDs.compactMap { store.task($0) }
        VStack(alignment: .leading, spacing: Space.md) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Share to Slack")
                    .font(.system(size: 17, weight: .bold))
                    .tracking(-0.2)
                    .foregroundStyle(Color.ink)
                Text("Posts \(Fmt.plural(tasks.count, "task")) as you, in \(selectedChannel.map { "#\($0.name)" } ?? "the channel you pick").")
                    .textStyle(.footnote)
                    .foregroundStyle(Color.ink2)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: Space.sm) {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Color.ink3)
                    TextField("Find a channel", text: $filter)
                        .textFieldStyle(.plain)
                        .font(.system(size: 13.5, weight: .medium))
                        .onSubmit { if let first = visible.first, visible.count == 1 { selected = first.id } }
                        .help("Type part of a channel's name")
                }
                .padding(.horizontal, 10)
                .frame(height: 30)
                .background(RoundedRectangle(cornerRadius: Radius.sm, style: .continuous).fill(Color.fill))
                Button { Task { await load(reload: true) } } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(IconButtonStyle(size: 30, filled: true))
                    .disabled(loading)
                    .help("Reload channels")
            }

            channelList
                .frame(height: 168)
                .overlay(RoundedRectangle(cornerRadius: Radius.sm, style: .continuous).strokeBorder(Color.hair))

            VStack(alignment: .leading, spacing: 6) {
                Eyebrow(text: "Message")
                ScrollView {
                    SlackPreview(message: SlackShare.message(for: tasks, now: app.clock))
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 112)
                .padding(10)
                .background(RoundedRectangle(cornerRadius: Radius.sm, style: .continuous).fill(Color.fill))
            }

            if let problem {
                Text(problem)
                    .textStyle(.footnote)
                    .foregroundStyle(Color.dangerText)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: Space.sm) {
                Spacer()
                Button("Cancel", action: close)
                    .buttonStyle(SecondaryPill(height: 32))
                    .keyboardShortcut(.cancelAction)
                    .help("Close (Esc)")
                // The channel is named in the line at the top, so the button stays short for any channel name.
                Button(posting ? "Posting…" : "Post") { post(count: tasks.count) }
                    .buttonStyle(PrimaryPill(height: 32))
                    .keyboardShortcut(.defaultAction)
                    .disabled(selectedChannel == nil || posting || tasks.isEmpty)
                    .help(selectedChannel.map { "Post the message in #\($0.name) (↩)" } ?? "Pick a channel first")
            }
        }
        .padding(Space.lg)
        .frame(width: 360)
        .background(Color.raised)
        .tint(Color.ink)
        .task { await load(reload: false) }
        // Return in the filter field presses Post: a channel filtered out of sight (say the one used last
        // time) mustn't be where it posts. With nothing selected, Return picks the single match instead.
        .onChange(of: filter) { _ in
            if let current = selected, !visible.contains(where: { $0.id == current }) { selected = nil }
        }
    }

    private var visible: [SlackChannel] {
        let query = filter.trimmingCharacters(in: CharacterSet(charactersIn: "# ").union(.whitespaces))
        return query.isEmpty ? channels : channels.filter { $0.name.localizedCaseInsensitiveContains(query) }
    }

    private var selectedChannel: SlackChannel? {
        channels.first { $0.id == selected }
    }

    @ViewBuilder
    private var channelList: some View {
        if loading && channels.isEmpty {
            HStack(spacing: Space.sm) {
                ProgressView().controlSize(.small)
                Text("Loading channels…").textStyle(.footnote).foregroundStyle(Color.ink2)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if visible.isEmpty {
            Text(channels.isEmpty ? "No channels yet." : "No channel matches “\(filter)”.")
                .textStyle(.footnote)
                .foregroundStyle(Color.ink2)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 1) {
                        ForEach(visible) { channel in
                            channelRow(channel).id(channel.id)
                        }
                    }
                    .padding(4)
                }
                .onAppear { if let selected { proxy.scrollTo(selected, anchor: .center) } }
            }
        }
    }

    private func channelRow(_ channel: SlackChannel) -> some View {
        let isSelected = selected == channel.id
        return Button { selected = channel.id } label: {
            HStack(spacing: Space.sm) {
                Image(systemName: channel.isPrivate ? "lock" : "number")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Color.ink2)
                    .frame(width: 16)
                Text(channel.name)
                    .font(.system(size: 13.5, weight: isSelected ? .semibold : .medium))
                    .foregroundStyle(Color.ink)
                    .lineLimit(1)
                Spacer(minLength: Space.sm)
                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 11, weight: .heavy))
                        .foregroundStyle(Color.ink)
                }
            }
            .padding(.horizontal, 8)
            .frame(height: 28)
            .background(RoundedRectangle(cornerRadius: Radius.xs, style: .continuous).fill(isSelected ? Color.fillStrong : Color.clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .hoverHighlight(cornerRadius: Radius.xs)
        .help(channel.isPrivate ? "Private channel" : "#\(channel.name)")
    }

    private func load(reload: Bool) async {
        loading = true
        problem = nil
        do {
            channels = try await integrations.slackChannels(reload: reload)
            if selected == nil || !channels.contains(where: { $0.id == selected }) {
                selected = channels.first { $0.id == lastChannel }?.id
            }
        } catch {
            problem = error.localizedDescription
        }
        loading = false
    }

    private func post(count: Int) {
        guard let channel = selectedChannel, !posting else { return }
        posting = true
        problem = nil
        Task {
            do {
                try await integrations.share(taskIDs: taskIDs, to: channel, now: app.clock)
                lastChannel = channel.id
                Haptics.success()
                app.showToast("Posted \(Fmt.plural(count, "task")) to #\(channel.name)")
                close()
            } catch {
                problem = error.localizedDescription
            }
            posting = false
        }
    }
}

/// Roughly how the message looks in Slack: the bold header, the lines, done ones struck through.
private struct SlackPreview: View {
    let message: String

    var body: some View {
        let lines = message.components(separatedBy: "\n")
        VStack(alignment: .leading, spacing: 3) {
            ForEach(Array(lines.enumerated()), id: \.offset) { i, line in
                render(line, isHeader: i == 0)
                    .font(.system(size: 12.5, weight: i == 0 ? .bold : .regular))
                    .foregroundStyle(i == 0 ? Color.ink : Color.bodyText)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func render(_ line: String, isHeader: Bool) -> Text {
        let plain = SlackText.unescape(line)
        if isHeader { return Text(plain.trimmingCharacters(in: CharacterSet(charactersIn: "*"))) }
        // "~struck~" segments alternate with plain ones.
        let parts = plain.components(separatedBy: "~")
        guard parts.count >= 3 else { return Text(plain) }
        return parts.enumerated().reduce(Text("")) { text, part in
            text + (part.offset % 2 == 1 ? Text(part.element).strikethrough() : Text(part.element))
        }
    }
}

extension SlackSaveEmoji {
    /// "Pushpin", "Inbox tray".
    static func title(_ name: String) -> String {
        let words = name.replacingOccurrences(of: "_", with: " ")
        return words.prefix(1).uppercased() + words.dropFirst()
    }
}
