import AppKit
import SwiftUI

// MARK: - From Slack & Gmail

/// Sidebar "From Slack & Gmail": the Slack messages and emails that need you, in two tabs. A message opens
/// complete (its files and earlier messages), with your notes, the task it could become and your reply.
struct SuggestionsView: View {
    @EnvironmentObject var store: Store
    @EnvironmentObject var app: AppState
    @ObservedObject private var integrations = Integrations.shared
    /// The tab, remembered across launches: "slack" or "gmail" (empty until one is picked).
    @AppStorage(SuggestionsView.tabKey) private var tabName = ""
    @StateObject private var inbox = InboxModel()
    @State private var sheet: ConnectionsSheet.Opening?

    static let tabKey = "inboxTab"

    var body: some View {
        let tab = currentTab
        VStack(alignment: .leading, spacing: 0) {
            PageHeader(title: "From Slack & Gmail", subtitle: subtitle) { headerControls(tab) }
            InboxBanners(kind: tab, updateSlack: updateSlack)
            Rectangle().fill(Color.hair).frame(height: 1)
            InboxPanes(model: inbox, kind: tab, connect: { sheet = .plain }, updateSlack: updateSlack)
                .id(tab)
                .transition(.opacity)
        }
        .background(Color.paper)
        .sheet(item: $sheet) { opening in ConnectionsSheet(opening: opening) }
        .onAppear { inbox.startWatchingKeys(app: app) }
        .onDisappear { inbox.stopWatchingKeys() }
    }

    /// The tab picked last; before any was picked, Slack unless only Gmail has something.
    private var currentTab: TaskSource.Kind {
        if let kind = TaskSource.Kind(rawValue: tabName), kind != .ai { return kind }
        let slack = integrations.isSlackConnected || integrations.suggestions.contains { $0.source.kind == .slack }
        let gmail = integrations.isGmailConnected || integrations.suggestions.contains { $0.source.kind == .gmail }
        return gmail && !slack ? .gmail : .slack
    }

    private func count(_ kind: TaskSource.Kind) -> Int {
        integrations.suggestions.lazy.filter { $0.source.kind == kind }.count
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

    private var sources: String? {
        switch (integrations.isSlackConnected, integrations.isGmailConnected) {
        case (true, true): "Slack and Gmail"
        case (true, false): "Slack"
        case (false, true): "Gmail"
        case (false, false): nil
        }
    }

    private var subtitle: String {
        guard integrations.isAnyConnected || !integrations.suggestions.isEmpty else { return "Slack messages and emails that need you" }
        if integrations.isRefreshing, let sources { return "Checking \(sources)…" }
        var parts: [String] = []
        if let last = integrations.lastRefresh {
            parts.append(Calendar.current.isDate(last, inSameDayAs: app.clock) ? "Updated \(Fmt.time(last))" : "Updated \(Fmt.dateTime(last))")
        }
        if let sources { parts.append(sources) }
        return parts.isEmpty ? "Slack messages and emails that need you" : parts.joined(separator: " · ")
    }

    private func headerControls(_ tab: TaskSource.Kind) -> some View {
        HStack(spacing: Space.sm) {
            SegmentedControl(selection: Binding(get: { tab }, set: { tabName = $0.rawValue }),
                             options: [(TaskSource.Kind.slack, "Slack (\(count(.slack)))"), (TaskSource.Kind.gmail, "Email (\(count(.gmail)))")])
                .help("Slack messages or emails")
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
                let items = integrations.items(tab)
                Button(items.count >= 2 ? "Add All \(items.count) as Tasks" : "Add All as Tasks") { addAll(items) }
                    .disabled(items.count < 2)
                Divider()
                Button("Connections…") { sheet = .plain }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Color.ink)
                    .frame(width: 32, height: 32)
            }
            .menuChrome(Circle())
            .help("Add all as tasks, or set up Slack and Gmail")
        }
    }
}

/// Under the header: what's wrong with the tab's service, and the permissions it still needs.
private struct InboxBanners: View {
    @ObservedObject private var integrations = Integrations.shared
    let kind: TaskSource.Kind
    let updateSlack: () -> Void

    var body: some View {
        let problems = self.problems
        let permissions = kind == .slack ? InboxItemText.slackPermissionBanner(missing: integrations.missingSlackScopes) : nil
        let reconnect = kind == .gmail && integrations.isGmailConnected && !integrations.gmailCanCompose
        VStack(alignment: .leading, spacing: Space.sm) {
            ForEach(problems, id: \.self) { ProblemLine(text: $0) }
            if let permissions {
                BannerLine(icon: "lock.open", text: permissions) {
                    Button("Update the app", action: updateSlack)
                        .buttonStyle(SecondaryPill(height: 28))
                        .help("Opens Slack to create the Docket app again with the new permissions, then shows the two steps left")
                }
            }
            if reconnect {
                BannerLine(icon: "paperplane",
                           text: integrations.isSigningInToGmail ? "Finish signing in to Google in your browser." : "Reconnect Gmail to reply from Docket.") {
                    if integrations.isSigningInToGmail {
                        ProgressView().controlSize(.small)
                        Button("Cancel") { integrations.cancelGmailSignIn() }
                            .buttonStyle(SecondaryPill(height: 28))
                            .help("Stop waiting for the browser")
                    } else {
                        Button("Reconnect") { integrations.connectGmail() }
                            .buttonStyle(SecondaryPill(height: 28))
                            .help("Sign in to Google again and allow Docket to send your replies and save drafts")
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, Space.gutter)
        .padding(.bottom, problems.isEmpty && permissions == nil && !reconnect ? 0 : Space.md)
        .animation(Motion.base, value: problems)
    }

    /// This tab's service, then AI; each once (they're also the ForEach ids).
    private var problems: [String] {
        let list = kind == .slack ? [integrations.slackProblem, integrations.slackScopeWarning, integrations.aiProblem]
            : [integrations.gmailProblem, integrations.aiProblem]
        var seen = Set<String>()
        return list.compactMap { $0 }.filter { seen.insert($0).inserted }
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
    /// What it opens for: the page as it is, or with the steps for updating the Docket app in Slack.
    enum Opening: String, Identifiable {
        case plain, updateSlack
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
            ConnectionsSettingsPage(updatingSlack: opening == .updateSlack)
        }
        // The Settings window's size; short enough for the smallest main window (600 pt).
        .frame(width: 620, height: 540)
        .background(Color.paper)
        .tint(Color.ink)
    }
}

// MARK: - Settings → Connections

/// Settings → Connections: Slack and Gmail, what each one does, and how suggestions are found.
struct ConnectionsSettingsPage: View {
    @ObservedObject private var integrations = Integrations.shared
    @ObservedObject private var ai = AIService.shared
    /// The steps for updating the Docket app in Slack (new permissions) are open.
    @State private var updatingSlack: Bool

    init(updatingSlack: Bool = false) {
        _updatingSlack = State(initialValue: updatingSlack)
    }

    var body: some View {
        SettingsPage {
            SlackConnection(integrations: integrations, aiOn: ai.isConfigured, updating: $updatingSlack)
            // While the Slack update is under way, its Connect is the page's one primary button.
            GmailConnection(integrations: integrations, aiOn: ai.isConfigured, isNextStep: integrations.isSlackConnected && !updatingSlack)
            if integrations.isAnyConnected {
                SuggestionSettings(integrations: integrations, aiOn: ai.isConfigured)
            }
        }
    }
}

private struct SlackConnection: View {
    @ObservedObject var integrations: Integrations
    let aiOn: Bool
    @Binding var updating: Bool
    @AppStorage(Prefs.Key.slackSaveEmoji) private var saveEmoji = SlackSaveEmoji.standard
    @AppStorage(Prefs.Key.slackMentions) private var mentions = true
    @AppStorage(Prefs.Key.slackFocusStatus) private var focusStatus = true
    @State private var token = ""
    @State private var connecting = false
    @State private var problem: String?
    /// The updated app's token was just connected: time to delete the old app.
    @State private var updated = false

    private static let appsPage = URL(string: "https://api.slack.com/apps")!

    var body: some View {
        SettingsSection(title: "Slack", footer: "Docket uses a Slack app of your own, so messages go straight from Slack to this Mac. The token stays in your keychain.") {
            if let account = integrations.slackAccount, integrations.isSlackConnected {
                if let issue = integrations.slackProblem { IssueRow(text: issue) }
                if let warning = integrations.slackScopeWarning { IssueRow(text: warning) }
                SettingsRow(title: "Connected as @\(account.userName) in \(account.teamName)",
                            subtitle: account.teamURL?.host) {
                    Button("Disconnect") { withAnimation(Motion.base) { integrations.disconnectSlack() } }
                        .buttonStyle(SecondaryPill(height: 30))
                        .help("Forget the Slack token and the Slack suggestions waiting")
                }
                if let missing = InboxItemText.slackPermissionBanner(missing: integrations.missingSlackScopes) {
                    if updating {
                        updateSteps
                    } else {
                        SettingsRow(title: missing, subtitle: InboxItemText.slackPermissionEffect(missing: integrations.missingSlackScopes)) {
                            Button("Update the app") {
                                NSWorkspace.shared.open(SlackManifest.createAppURL)
                                withAnimation(Motion.base) { updating = true }
                            }
                            .buttonStyle(SecondaryPill(height: 30))
                            .help("Opens Slack to create the Docket app again with the new permissions")
                        }
                    }
                } else if updated {
                    SettingsRow(title: "Updated. Now delete the old Docket app",
                                subtitle: "On your Slack apps page, open the old Docket app and click Delete App at the bottom of Basic Information.") {
                        Button { NSWorkspace.shared.open(Self.appsPage) } label: { Label("Your apps", systemImage: "arrow.up.right") }
                            .buttonStyle(SecondaryPill(height: 30))
                            .help("Opens your apps on api.slack.com in your browser")
                    }
                }
                SettingsRow(title: "Save with a reaction",
                            subtitle: "React to a message (from the last 30 days) with this and it shows up in From Slack & Gmail.") {
                    ChoiceMenu(selection: $saveEmoji, options: emojiOptions)
                        .help("The reaction that saves a message to Docket")
                }
                ToggleRow(title: "Mentions",
                          subtitle: aiOn ? "Messages that @mention you (last 3 days). AI keeps only the ones that need you."
                              : "Every message that @mentions you (last 3 days). Turn on AI to keep only the ones that need you.",
                          isOn: $mentions)
                    .help("Suggest tasks from messages that mention you")
                ToggleRow(title: "Focus status", subtitle: "During a focus session your status says “Heads down” 🎯 and notifications are paused.",
                          isOn: $focusStatus, divider: false)
                    .help("Set your Slack status and pause notifications while you focus")
            } else {
                if let issue = integrations.slackProblem { IssueRow(text: issue) }
                StepRow(number: "1", title: "Create the Docket app in Slack",
                        detail: "Opens Slack with everything filled in. Pick your workspace, then click Create.") {
                    Button { NSWorkspace.shared.open(SlackManifest.createAppURL) } label: { Label("Create app", systemImage: "arrow.up.right") }
                        .buttonStyle(SecondaryPill(height: 30))
                        .help("Opens api.slack.com in your browser")
                }
                StepRow(number: "2", title: "Install it and paste the token",
                        detail: "On the app's page, click Install to Workspace and allow it. Then copy the User OAuth Token (it starts with xoxp-).",
                        divider: false) { EmptyView() }
                tokenEntry(cancel: nil)
            }
        }
        .onChange(of: saveEmoji) { _ in integrations.refresh() }
        .onChange(of: mentions) { _ in integrations.refresh() }
    }

    /// An app made before Docket showed files and threads: make it again from the new manifest (Slack was
    /// opened with it already), paste its token, then delete the old app.
    @ViewBuilder
    private var updateSteps: some View {
        StepRow(number: "1", title: "Create and install the updated app",
                detail: "Slack opened in your browser with the new permissions filled in. Pick your workspace, click Create, then Install to Workspace and allow it.") {
            Button { NSWorkspace.shared.open(SlackManifest.createAppURL) } label: { Label("Open again", systemImage: "arrow.up.right") }
                .buttonStyle(SecondaryPill(height: 30))
                .help("Opens api.slack.com in your browser")
        }
        StepRow(number: "2", title: "Paste the new token, then delete the old app",
                detail: "Copy the new app's User OAuth Token (it starts with xoxp-) and paste it below. Then delete the old Docket app from your Slack apps.",
                divider: false) {
            Button { NSWorkspace.shared.open(Self.appsPage) } label: { Label("Your apps", systemImage: "arrow.up.right") }
                .buttonStyle(SecondaryPill(height: 30))
                .help("Opens your apps on api.slack.com, where the old Docket app can be deleted")
        }
        tokenEntry(cancel: { withAnimation(Motion.base) { updating = false } })
    }

    /// The token field and Connect, with what went wrong under it.
    @ViewBuilder
    private func tokenEntry(cancel: (() -> Void)?) -> some View {
        HStack(spacing: Space.sm) {
            SecureField("xoxp-…", text: $token)
                .connectionField()
                .onSubmit(connect)
                .help("Paste the User OAuth Token from your Slack app")
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
                .buttonStyle(PrimaryPill(height: 32))
                .disabled(token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || connecting)
                .help("Check the token with Slack and connect")
        }
        .padding(.leading, Space.lg + 22 + Space.md)
        .padding(.trailing, Space.lg)
        .padding(.bottom, problem == nil ? Space.lg : Space.sm)
        if let problem {
            Text(problem)
                .textStyle(.footnote)
                .foregroundStyle(Color.dangerText)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.leading, Space.lg + 22 + Space.md)
                .padding(.trailing, Space.lg)
                .padding(.bottom, Space.lg)
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
        connecting = true
        problem = nil
        Task {
            do {
                try await integrations.connectSlack(token: value)
                token = ""
                if updating {
                    withAnimation(Motion.base) {
                        updating = false
                        updated = true
                    }
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
    /// Slack is done, so connecting Gmail is the obvious next step (the page's primary button).
    let isNextStep: Bool
    @AppStorage(Prefs.Key.gmailNeedsReply) private var needsReply = true
    @State private var clientID = ""
    @State private var clientSecret = ""
    @State private var changingClient = false

    /// What Docket does with Gmail, in so many words.
    static let promise = "Docket reads your mail and only sends or saves a draft when you click Send or Save draft. It never deletes or archives anything."

    var body: some View {
        let client = integrations.googleClient
        SettingsSection(title: "Gmail", footer: footer(configured: client != nil)) {
            if let issue = integrations.gmailProblem { IssueRow(text: issue) }
            if let email = integrations.gmailAddress, integrations.isGmailConnected {
                SettingsRow(title: "Connected as \(email)",
                            subtitle: integrations.gmailCanCompose ? Self.promise : "Docket can read your mail. Reconnect to reply from Docket too.") {
                    Button("Disconnect") { withAnimation(Motion.base) { integrations.disconnectGmail() } }
                        .buttonStyle(SecondaryPill(height: 30))
                        .help("Sign Docket out of Gmail")
                }
                if !integrations.gmailCanCompose {
                    if integrations.isSigningInToGmail {
                        SettingsRow(title: "Waiting for you in the browser…", subtitle: "Sign in with Google and allow Docket to send your replies.") {
                            HStack(spacing: Space.sm) {
                                ProgressView().controlSize(.small)
                                Button("Cancel") { integrations.cancelGmailSignIn() }
                                    .buttonStyle(SecondaryPill(height: 30))
                                    .help("Stop waiting for the browser")
                            }
                        }
                    } else {
                        SettingsRow(title: "Reconnect Gmail to reply from Docket", subtitle: Self.promise) {
                            Button("Reconnect") { integrations.connectGmail() }
                                .buttonStyle(SecondaryPill(height: 30))
                                .help("Sign in to Google again and allow Docket to send your replies and save drafts")
                        }
                    }
                }
                SettingsRow(title: "Starred emails", subtitle: "Emails you star (last 30 days) show up in From Slack & Gmail.") {
                    Badge(text: "On", tone: .neutral, icon: "star")
                }
                ToggleRow(title: "Needs a reply",
                          subtitle: aiOn ? "Unread, important emails from the last 2 days. AI keeps only the ones that need you."
                              : "Unread, important emails from the last 2 days. Turn on AI to keep only the ones that need you.",
                          isOn: $needsReply, divider: false)
                    .help("Suggest tasks from unread, important email")
            } else if let client, !changingClient {
                if integrations.isSigningInToGmail {
                    SettingsRow(title: "Waiting for you in the browser…", subtitle: "Sign in with Google and allow Docket to read your mail and send your replies.") {
                        HStack(spacing: Space.sm) {
                            ProgressView().controlSize(.small)
                            Button("Cancel") { integrations.cancelGmailSignIn() }
                                .buttonStyle(SecondaryPill(height: 30))
                                .help("Stop waiting for the browser")
                        }
                    }
                } else {
                    SettingsRow(title: "Connect Gmail", subtitle: "Sign in with Google in your browser. " + Self.promise) {
                        if isNextStep {
                            Button("Connect Gmail") { integrations.connectGmail() }
                                .buttonStyle(PrimaryPill(height: 30))
                                .help("Opens Google sign-in in your browser")
                        } else {
                            Button("Connect Gmail") { integrations.connectGmail() }
                                .buttonStyle(SecondaryPill(height: 30))
                                .help("Opens Google sign-in in your browser")
                        }
                    }
                }
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
            } else {
                setup(canCancel: client != nil)
            }
        }
        .onChange(of: needsReply) { _ in integrations.refresh() }
    }

    private func footer(configured: Bool) -> String {
        configured
            ? "If your OAuth app is External and in testing, Google signs Docket out every 7 days; just connect again. Docket never sees your password."
            : "Gmail needs a free OAuth client of your own, so your mail goes straight from Google to this Mac. If the app is External and in testing, Google signs Docket out every 7 days; just connect again."
    }

    @ViewBuilder
    private func setup(canCancel: Bool) -> some View {
        StepRow(number: "1", title: "Create a Google Cloud project", detail: nil) { link("https://console.cloud.google.com/projectcreate") }
        StepRow(number: "2", title: "Turn on the Gmail API", detail: nil) {
            link("https://console.cloud.google.com/apis/library/gmail.googleapis.com")
        }
        StepRow(number: "3", title: "Set up the OAuth consent screen",
                detail: "Choose Internal if you use Google Workspace. Otherwise choose External and add your own address as a test user.") {
            link("https://console.cloud.google.com/apis/credentials/consent")
        }
        StepRow(number: "4", title: "Create an OAuth client ID",
                detail: "Application type: Desktop app. Then paste its client ID and secret below.", divider: false) {
            link("https://console.cloud.google.com/apis/credentials/oauthclient")
        }
        VStack(spacing: Space.sm) {
            TextField("Client ID", text: $clientID)
                .connectionField()
                .help("The client ID of your Desktop app OAuth client")
            SecureField("Client secret", text: $clientSecret)
                .connectionField()
                .onSubmit(saveClient)
                .help("The client secret of the same OAuth client")
            HStack(spacing: Space.sm) {
                Spacer()
                if canCancel {
                    Button("Cancel") { withAnimation(Motion.base) { changingClient = false } }
                        .buttonStyle(SecondaryPill(height: 30))
                        .help("Keep the current OAuth client")
                }
                if isNextStep {
                    Button("Save", action: saveClient)
                        .buttonStyle(PrimaryPill(height: 30))
                        .disabled(!canSave)
                        .help("Keep the client ID and secret in your keychain")
                } else {
                    Button("Save", action: saveClient)
                        .buttonStyle(SecondaryPill(height: 30))
                        .disabled(!canSave)
                        .help("Keep the client ID and secret in your keychain")
                }
            }
        }
        .padding(.leading, Space.lg + 22 + Space.md)
        .padding(.trailing, Space.lg)
        .padding(.bottom, Space.lg)
    }

    private var canSave: Bool {
        !clientID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !clientSecret.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func saveClient() {
        guard canSave else { return }
        integrations.saveGoogleClient(id: clientID, secret: clientSecret)
        clientSecret = ""
        withAnimation(Motion.base) { changingClient = false }
    }

    private func link(_ address: String) -> some View {
        Button {
            if let url = URL(string: address) { NSWorkspace.shared.open(url) }
        } label: { Label("Open", systemImage: "arrow.up.right") }
            .buttonStyle(SecondaryPill(height: 30))
            .help("Opens Google Cloud Console in your browser")
    }
}

private struct SuggestionSettings: View {
    @ObservedObject var integrations: Integrations
    let aiOn: Bool

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
            SettingsRow(title: "Sort with AI",
                        subtitle: aiOn ? "Gemini picks out what needs you and writes the task."
                            : "Turn on AI in Settings → AI (it needs a Gemini API key) to use this.",
                        divider: false) {
                Badge(text: aiOn ? "On" : "Off", tone: aiOn ? .success : .neutral, icon: aiOn ? "sparkles" : nil)
            }
        }
    }

    private var checkedSubtitle: String {
        var text = "Every 15 minutes, and when you come back to Docket."
        if let last = integrations.lastRefresh {
            text += Calendar.current.isDateInToday(last) ? " Last checked \(Fmt.time(last))." : " Last checked \(Fmt.dateTime(last))."
        }
        return text
    }
}

/// A numbered setup step inside a settings card.
private struct StepRow<Trailing: View>: View {
    var number: String
    var title: String
    var detail: String?
    var divider = true
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(alignment: .top, spacing: Space.md) {
            Text(number)
                .font(.system(size: 12, weight: .bold))
                .monospacedDigit()
                .foregroundStyle(Color.ink)
                .frame(width: 22, height: 22)
                .background(Circle().fill(Color.fill))
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(Color.ink)
                if let detail {
                    Text(detail)
                        .textStyle(.footnote)
                        .foregroundStyle(Color.ink2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.top, 2)
            Spacer(minLength: Space.md)
            trailing
        }
        .padding(.horizontal, Space.lg)
        .padding(.vertical, 11)
        .frame(minHeight: 48)
        .overlay(alignment: .bottom) {
            if divider { Rectangle().fill(Color.hair).frame(height: 1).padding(.leading, Space.lg) }
        }
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
