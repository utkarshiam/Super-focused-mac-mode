import AppKit
import SwiftUI

// MARK: - From Slack & Gmail

/// Sidebar "From Slack & Gmail": messages that may deserve a task, each with a proposed task.
struct SuggestionsView: View {
    @EnvironmentObject var store: Store
    @EnvironmentObject var app: AppState
    @ObservedObject private var integrations = Integrations.shared
    @AppStorage(Prefs.Key.slackSaveEmoji) private var saveEmoji = SlackSaveEmoji.standard
    @State private var showConnections = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            PageHeader(title: "From Slack & Gmail", subtitle: subtitle) { headerControls }
            ForEach(problems, id: \.self) { problem in
                ProblemLine(text: problem)
                    .padding(.horizontal, Space.gutter)
                    .padding(.bottom, Space.sm)
            }
            content
        }
        .background(Color.paper)
        .animation(Motion.base, value: problems)
        .sheet(isPresented: $showConnections) { ConnectionsSheet() }
    }

    private var problems: [String] {
        [integrations.slackProblem, integrations.gmailProblem].compactMap { $0 }
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
        guard integrations.isAnyConnected || !integrations.suggestions.isEmpty else { return "Turn messages into tasks" }
        if integrations.isRefreshing, let sources { return "Checking \(sources)…" }
        var parts: [String] = []
        if !integrations.suggestions.isEmpty { parts.append(Fmt.plural(integrations.suggestions.count, "suggestion")) }
        if let last = integrations.lastRefresh {
            parts.append(Calendar.current.isDate(last, inSameDayAs: app.clock) ? "Updated \(Fmt.time(last))" : "Updated \(Fmt.dateTime(last))")
        }
        if let sources { parts.append(sources) }
        return parts.joined(separator: " · ")
    }

    private var headerControls: some View {
        HStack(spacing: Space.sm) {
            if integrations.suggestions.count >= 2 {
                Button("Add all") { withAnimation(Motion.gentle) { integrations.addAll() } }
                    .buttonStyle(SecondaryPill(height: 32))
                    .help("Add every suggestion as a task")
            }
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
            Button { showConnections = true } label: { Image(systemName: "slider.horizontal.3") }
                .buttonStyle(IconButtonStyle(filled: true))
                .help("Connections")
        }
    }

    @ViewBuilder
    private var content: some View {
        if integrations.suggestions.isEmpty {
            if !integrations.isAnyConnected {
                pitch
            } else if integrations.isRefreshing && integrations.lastRefresh == nil {
                VStack(spacing: Space.md) {
                    ProgressView().controlSize(.small)
                    Text("Looking for messages that need you…").textStyle(.callout).foregroundStyle(Color.ink2)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                EmptyState(icon: "tray.and.arrow.down", title: "Nothing new", message: emptyMessage)
            }
        } else {
            ScrollView {
                EnterUpWindow {
                    LazyVStack(alignment: .leading, spacing: Space.md) {
                        ForEach(Array(integrations.suggestions.enumerated()), id: \.element.id) { i, suggestion in
                            SuggestionCard(suggestion: suggestion, isNext: i == 0, lists: store.lists, now: app.clock, saveEmoji: saveEmoji,
                                           add: { withAnimation(Motion.gentle) { _ = integrations.add(suggestion) } },
                                           edit: { integrations.edit(suggestion) },
                                           dismiss: { withAnimation(Motion.gentle) { integrations.dismiss(suggestion) } },
                                           open: { integrations.open(suggestion) })
                                .enterUp(i)
                                .transition(.asymmetric(insertion: .opacity, removal: .opacity.combined(with: .scale(scale: 0.97))))
                        }
                    }
                    .frame(maxWidth: 760, alignment: .leading)
                    .padding(.horizontal, Space.gutter)
                    .padding(.top, Space.xs)
                    .padding(.bottom, Space.x6)
                }
            }
        }
    }

    private var emptyMessage: String {
        let glyph = SlackSaveEmoji.glyph(saveEmoji)
        switch (integrations.isSlackConnected, integrations.isGmailConnected) {
        case (true, false): return "React with \(glyph) in Slack and it shows up here."
        case (false, true): return "Star an email in Gmail and it shows up here."
        default: return "React with \(glyph) in Slack or star an email in Gmail and it shows up here."
        }
    }

    /// Nothing connected yet: what this is for, and the way in.
    private var pitch: some View {
        VStack(spacing: Space.md) {
            Image(systemName: "tray.and.arrow.down")
                .font(.system(size: 22, weight: .regular))
                .foregroundStyle(Color.ink)
                .frame(width: 56, height: 56)
                .background(Circle().fill(Color.fill))
            Text("Turn messages into tasks")
                .textStyle(.title3)
                .foregroundStyle(Color.ink)
            Text("Connect Slack and Gmail. Messages you react to with \(SlackSaveEmoji.glyph(saveEmoji)), emails you star, and the ones waiting on your reply show up here, ready to become tasks.")
                .textStyle(.callout)
                .foregroundStyle(Color.ink2)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 380)
            Button("Connect Slack or Gmail") { showConnections = true }
                .buttonStyle(PrimaryPill())
                .help("Set up Slack and Gmail")
                .padding(.top, Space.xs)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(Space.x4)
        .enterUp()
    }
}

/// One message and the task it could become.
private struct SuggestionCard: View {
    let suggestion: Suggestion
    /// The top card: its "Add task" is the screen's one primary button.
    let isNext: Bool
    let lists: [TaskList]
    let now: Date
    let saveEmoji: String
    let add: () -> Void
    let edit: () -> Void
    let dismiss: () -> Void
    let open: () -> Void

    private let iconWidth: CGFloat = 26

    var body: some View {
        let draft = suggestion.draft ?? SuggestionDrafts.fallback(for: suggestion)
        VStack(alignment: .leading, spacing: Space.md) {
            header
            message
            proposal(draft)
            actions
        }
        .padding(Space.lg)
        .frame(maxWidth: .infinity, alignment: .leading)
        .hairlineCard(radius: Radius.lg)
    }

    private var header: some View {
        HStack(spacing: Space.sm) {
            Image(systemName: SourceStyle.icon(suggestion.source.kind))
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Color.ink)
                .frame(width: iconWidth, height: iconWidth)
                .background(Circle().fill(Color.fill))
            Text(origin)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Color.ink)
                .lineLimit(1)
                .truncationMode(.tail)
                .help(suggestion.source.label)
            if let why {
                Text("· \(why)")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Color.ink3)
                    .lineLimit(1)
                    .fixedSize()
            }
            Spacer(minLength: Space.sm)
            Text(Fmt.dateTime(suggestion.receivedAt))
                .font(.system(size: 12, weight: .medium))
                .monospacedDigit()
                .foregroundStyle(Color.ink3)
                .lineLimit(1)
                .fixedSize()
        }
    }

    private var origin: String {
        suggestion.source.kind == .gmail || suggestion.source.label.isEmpty ? suggestion.from : suggestion.source.label
    }

    private var why: String? {
        switch suggestion.trigger {
        case .reaction?: "Saved with \(SlackSaveEmoji.glyph(saveEmoji))"
        case .mention?: "Mentions you"
        case .starred?: "Starred"
        case .needsReply?: "Waiting on your reply"
        case nil: nil
        }
    }

    private var message: some View {
        VStack(alignment: .leading, spacing: 3) {
            if let subject = suggestion.subject, !subject.isEmpty {
                Text(subject)
                    .font(.system(size: 15, weight: .semibold))
                    .tracking(-0.2)
                    .foregroundStyle(Color.ink)
                    .lineLimit(1)
            }
            if !suggestion.snippet.isEmpty {
                Text(suggestion.snippet)
                    .textStyle(.callout)
                    .foregroundStyle(Color.ink2)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.leading, iconWidth + Space.sm)
    }

    /// The task it would become, drawn like a task line: title on the left, date bold on the right, duration pill.
    private func proposal(_ draft: TaskDraft) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .center, spacing: Space.sm) {
                Image(systemName: "circle")
                    .font(.system(size: 15, weight: .regular))
                    .foregroundStyle(Color.ink3)
                Text(draft.title)
                    .font(.system(size: 15, weight: .semibold))
                    .tracking(-0.2)
                    .foregroundStyle(Color.ink)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if let due = draft.due {
                    Text(Fmt.due(due, hasTime: draft.dueHasTime, now: now))
                        .font(.system(size: 15, weight: .bold))
                        .tracking(-0.2)
                        .monospacedDigit()
                        .foregroundStyle(Color.ink)
                        .lineLimit(1)
                        .fixedSize()
                }
                if let minutes = draft.estimateMinutes, minutes > 0 {
                    DurationPill(minutes: minutes)
                }
            }
            let chips = details(draft)
            if !chips.isEmpty || draft.reason != nil {
                VStack(alignment: .leading, spacing: 6) {
                    if !chips.isEmpty {
                        HStack(spacing: 6) {
                            ForEach(chips) { chip in Chip(icon: chip.icon, text: chip.text, tone: chip.tone) }
                        }
                    }
                    if let reason = draft.reason, !reason.isEmpty {
                        Label(reason, systemImage: "sparkles")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(Color.ink3)
                            .lineLimit(2)
                    }
                }
                .padding(.leading, 15 + Space.sm)
            }
        }
        .padding(.horizontal, Space.md)
        .padding(.vertical, 10)
        .background(RoundedRectangle(cornerRadius: Radius.md, style: .continuous).fill(Color.fill))
    }

    private struct Detail: Identifiable {
        var icon: String
        var text: String
        var tone: Tone = .neutral
        var id: String { text }
    }

    /// Priority, list, who it's waiting on, steps: whatever the draft has beyond its date and duration.
    private func details(_ draft: TaskDraft) -> [Detail] {
        var chips: [Detail] = []
        if let tone = draft.priority.tone { chips.append(Detail(icon: "flag", text: draft.priority.label, tone: tone)) }
        let listName = (draft.listName ?? "").trimmingCharacters(in: CharacterSet(charactersIn: "#").union(.whitespaces))
        if !listName.isEmpty, let list = lists.first(where: { $0.name.compare(listName, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame }) {
            chips.append(Detail(icon: list.icon, text: list.name))
        }
        if let who = draft.waitingOn?.trimmingCharacters(in: .whitespaces), !who.isEmpty { chips.append(Detail(icon: "hourglass", text: "Waiting on \(who)")) }
        if !draft.subtasks.isEmpty { chips.append(Detail(icon: "checklist", text: Fmt.plural(draft.subtasks.count, "step"))) }
        return chips
    }

    private var actions: some View {
        HStack(spacing: Space.sm) {
            if isNext {
                Button(action: add) { Label("Add task", systemImage: "plus") }
                    .buttonStyle(PrimaryPill(height: 32))
                    .help("Add this as a task")
            } else {
                Button(action: add) { Label("Add task", systemImage: "plus") }
                    .buttonStyle(SecondaryPill(height: 32))
                    .help("Add this as a task")
            }
            Button("Edit…", action: edit)
                .buttonStyle(SecondaryPill(height: 32))
                .help("Change the task before adding it")
            Button("Dismiss", action: dismiss)
                .buttonStyle(SecondaryPill(height: 32))
                .help("Don't suggest this message again")
            Spacer(minLength: Space.sm)
            if suggestion.source.url != nil {
                Button(action: open) { Label(SourceStyle.openTitle(suggestion.source.kind), systemImage: "arrow.up.right") }
                    .buttonStyle(SecondaryPill(height: 32))
                    .help("See the original message")
            }
        }
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
            ConnectionsSettingsPage()
        }
        .frame(width: 620, height: 620)
        .background(Color.paper)
        .tint(Color.ink)
    }
}

// MARK: - Settings → Connections

/// Settings → Connections: Slack and Gmail, what each one does, and how suggestions are found.
struct ConnectionsSettingsPage: View {
    @ObservedObject private var integrations = Integrations.shared
    @ObservedObject private var ai = AIService.shared

    var body: some View {
        SettingsPage {
            SlackConnection(integrations: integrations, aiOn: ai.isConfigured)
            GmailConnection(integrations: integrations, aiOn: ai.isConfigured, isNextStep: integrations.isSlackConnected)
            if integrations.isAnyConnected {
                SuggestionSettings(integrations: integrations, aiOn: ai.isConfigured)
            }
        }
    }
}

private struct SlackConnection: View {
    @ObservedObject var integrations: Integrations
    let aiOn: Bool
    @AppStorage(Prefs.Key.slackSaveEmoji) private var saveEmoji = SlackSaveEmoji.standard
    @AppStorage(Prefs.Key.slackMentions) private var mentions = true
    @AppStorage(Prefs.Key.slackFocusStatus) private var focusStatus = true
    @State private var token = ""
    @State private var connecting = false
    @State private var problem: String?

    var body: some View {
        SettingsSection(title: "Slack", footer: "Docket uses a Slack app of your own, so messages go straight from Slack to this Mac. The token stays in your keychain.") {
            if let account = integrations.slackAccount, integrations.isSlackConnected {
                if let issue = integrations.slackProblem { IssueRow(text: issue) }
                SettingsRow(title: "Connected as @\(account.userName)", subtitle: account.teamName) {
                    Button("Disconnect") { withAnimation(Motion.base) { integrations.disconnectSlack() } }
                        .buttonStyle(SecondaryPill(height: 30))
                        .help("Forget the Slack token")
                }
                SettingsRow(title: "Save with a reaction", subtitle: "React to any message with this and it shows up in From Slack & Gmail.") {
                    ChoiceMenu(selection: $saveEmoji, options: SlackSaveEmoji.choices.map { ($0.name, "\($0.glyph)  \(SlackSaveEmoji.title($0.name))") })
                        .help("The reaction that saves a message to Docket")
                }
                ToggleRow(title: "Mentions",
                          subtitle: aiOn ? "Messages that @mention you (last 3 days). AI keeps only the ones that need you."
                              : "Every message that @mentions you (last 3 days). Turn on AI to keep only the ones that need you.",
                          isOn: $mentions)
                ToggleRow(title: "Focus status", subtitle: "During a focus session your status says “Heads down” 🎯 and notifications are paused.",
                          isOn: $focusStatus, divider: false)
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
                HStack(spacing: Space.sm) {
                    SecureField("xoxp-…", text: $token)
                        .connectionField()
                        .onSubmit(connect)
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
        }
        .onChange(of: saveEmoji) { _ in integrations.refresh() }
        .onChange(of: mentions) { _ in integrations.refresh() }
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

    var body: some View {
        let client = integrations.googleClient
        SettingsSection(title: "Gmail", footer: footer(configured: client != nil)) {
            if let issue = integrations.gmailProblem { IssueRow(text: issue) }
            if let email = integrations.gmailAddress, integrations.isGmailConnected {
                SettingsRow(title: "Connected as \(email)") {
                    Button("Disconnect") { withAnimation(Motion.base) { integrations.disconnectGmail() } }
                        .buttonStyle(SecondaryPill(height: 30))
                        .help("Sign Docket out of Gmail")
                }
                SettingsRow(title: "Starred emails", subtitle: "Emails you star (last 30 days) show up in From Slack & Gmail.") {
                    Badge(text: "On", tone: .neutral, icon: "star")
                }
                ToggleRow(title: "Needs a reply",
                          subtitle: aiOn ? "Unread, important emails from the last 2 days. AI keeps only the ones that need you."
                              : "Unread, important emails from the last 2 days. Turn on AI to keep only the ones that need you.",
                          isOn: $needsReply, divider: false)
            } else if let client, !changingClient {
                if integrations.isSigningInToGmail {
                    SettingsRow(title: "Waiting for you in the browser…", subtitle: "Sign in with Google and allow Docket to read your email.") {
                        HStack(spacing: Space.sm) {
                            ProgressView().controlSize(.small)
                            Button("Cancel") { integrations.cancelGmailSignIn() }
                                .buttonStyle(SecondaryPill(height: 30))
                                .help("Stop waiting for the browser")
                        }
                    }
                } else {
                    SettingsRow(title: "Connect Gmail", subtitle: "Sign in with Google in your browser. Docket only asks to read your email.") {
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
            SecureField("Client secret", text: $clientSecret)
                .connectionField()
                .onSubmit(saveClient)
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
                        footer: aiOn ? "With AI on, the text of new mentions and emails goes to Google Gemini to decide which need a task. Turn AI off in Settings → AI to keep them on this Mac."
                            : "Everything stays on this Mac.") {
            SettingsRow(title: "Check for new messages", subtitle: checkedSubtitle) {
                Button(integrations.isRefreshing ? "Checking…" : "Check now") { integrations.refresh() }
                    .buttonStyle(SecondaryPill(height: 30))
                    .disabled(integrations.isRefreshing)
                    .help("Check Slack and Gmail now")
            }
            SettingsRow(title: "Sort with AI",
                        subtitle: aiOn ? "Gemini picks out what needs you and writes the task." : "Add a Gemini API key in Settings → AI to turn this on.",
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
private enum SourceStyle {
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
    @ObservedObject private var integrations = Integrations.shared
    let taskIDs: [UUID]
    @State private var showing = false

    init(taskIDs: [UUID]) {
        self.taskIDs = taskIDs
    }

    var body: some View {
        if integrations.isSlackConnected {
            Button { showing = true } label: { Label("Share to Slack…", systemImage: "paperplane") }
                .buttonStyle(SecondaryPill())
                .disabled(taskIDs.isEmpty)
                .help("Post these tasks to a Slack channel, as you")
                .popover(isPresented: $showing, arrowEdge: .bottom) {
                    ShareToSlackPopover(taskIDs: taskIDs) { showing = false }
                }
        }
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
                Text("Posts \(Fmt.plural(tasks.count, "task")) as you, in the channel you pick.")
                    .textStyle(.footnote)
                    .foregroundStyle(Color.ink2)
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
                Button(postTitle) { post(count: tasks.count) }
                    .buttonStyle(PrimaryPill(height: 32))
                    .keyboardShortcut(.defaultAction)
                    .disabled(selectedChannel == nil || posting || tasks.isEmpty)
                    .help("Post the message (↩)")
            }
        }
        .padding(Space.lg)
        .frame(width: 360)
        .background(Color.raised)
        .tint(Color.ink)
        .task { await load(reload: false) }
    }

    private var visible: [SlackChannel] {
        let query = filter.trimmingCharacters(in: CharacterSet(charactersIn: "# ").union(.whitespaces))
        return query.isEmpty ? channels : channels.filter { $0.name.localizedCaseInsensitiveContains(query) }
    }

    private var selectedChannel: SlackChannel? {
        channels.first { $0.id == selected }
    }

    private var postTitle: String {
        if posting { return "Posting…" }
        return selectedChannel.map { "Post to #\($0.name)" } ?? "Post"
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
