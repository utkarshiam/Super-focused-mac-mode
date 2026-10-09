import AppKit
import SwiftUI

// The guided setup on the Connections page: a numbered checklist per service, written for someone who has
// never opened Google Cloud or Slack's app pages. Each step is one sentence of what to click or type, a button
// that opens the exact page, copy buttons for anything to paste, and a ✓ once Docket can tell it's done. The
// next step is open; done ones are one line. "Check setup" runs real checks and lists what works and what to fix.

// MARK: - Steps (pure, so they're easy to test)

/// One step of a checklist.
struct SetupStep: Identifiable, Equatable {
    /// Something to paste or type, with a copy button.
    struct Copy: Equatable {
        enum Kind: Equatable {
            case fixed(String)
            /// The user's own Google address: typed once (or known from the sign-in), then copied.
            case email
        }
        var label: String
        var kind: Kind
    }

    var id: String
    /// What to do, in one short sentence.
    var title: String
    /// Exactly what to click or type there, in a sentence or two.
    var detail: String?
    var link: URL?
    var linkTitle: String?
    var copies: [Copy] = []
    /// Docket can tell when it's done (a token works, a client is saved, signed in). The others are ticked by
    /// the user ("Done"), or count as done once a later step Docket can check is.
    var verifiable = false
    var done = false
}

enum SetupSteps {
    struct SlackFacts: Equatable {
        var connected = false
        /// The token has every permission Docket asks for.
        var permissionsComplete = false
    }

    struct GmailFacts: Equatable {
        var hasClient = false
        var connected = false
        /// The sign-in allows starring and replying (gmail.modify).
        var canModify = false
    }

    static let slackAppsPage = URL(string: "https://api.slack.com/apps")!

    /// Slack: create the app from the manifest, install it, paste its token, every permission.
    static func slack(_ f: SlackFacts, ticked: Set<String>, createAppURL: URL = SlackManifest.createAppURL) -> [SetupStep] {
        let steps = [
            SetupStep(id: "slack.create", title: "Create the Docket app in Slack",
                      detail: "Slack opens with everything filled in. Pick your workspace, click Next, then Create.",
                      link: createAppURL, linkTitle: "Open Slack"),
            SetupStep(id: "slack.install", title: "Install it to your workspace",
                      detail: "On the app's page, click OAuth & Permissions on the left, then Install to Workspace, then Allow.",
                      link: slackAppsPage, linkTitle: "Your Slack apps"),
            SetupStep(id: "slack.token", title: "Paste the User OAuth Token here",
                      detail: "It's on OAuth & Permissions under OAuth Tokens and starts with xoxp-. Click Copy next to it, paste it below, click Connect.",
                      verifiable: true),
            f.connected
                ? SetupStep(id: "slack.permissions", title: "Allow every permission",
                            detail: "Your Docket app in Slack is missing permissions. Create it again (it opens with everything ticked), install it, paste its new token below, then delete the old app.",
                            link: createAppURL, linkTitle: "Create it again", verifiable: true)
                : SetupStep(id: "slack.permissions", title: "Allow every permission",
                            detail: "Docket checks this by itself once the token is in. An app made from step 1 has them all.",
                            verifiable: true),
        ]
        return resolve(steps, verified: ["slack.token": f.connected, "slack.permissions": f.connected && f.permissionsComplete], ticked: ticked)
    }

    static let projectPage = URL(string: "https://console.cloud.google.com/projectcreate")!
    static let gmailAPIPage = URL(string: "https://console.cloud.google.com/apis/library/gmail.googleapis.com")!
    static let consentPage = URL(string: "https://console.cloud.google.com/auth/overview/create")!
    static let audiencePage = URL(string: "https://console.cloud.google.com/auth/audience")!
    static let clientPage = URL(string: "https://console.cloud.google.com/auth/clients/create")!

    /// Gmail: a Google Cloud project with the Gmail API, the consent screen, the user as a test user, a
    /// Desktop app client pasted here, then signing in with every permission.
    static func gmail(_ f: GmailFacts, ticked: Set<String>) -> [SetupStep] {
        let steps = [
            SetupStep(id: "gmail.project", title: "Create a project in Google Cloud",
                      detail: "Sign in with your Google account if asked. Project name: Docket. Click Create.",
                      link: projectPage, linkTitle: "Open Google Cloud",
                      copies: [SetupStep.Copy(label: "Project name", kind: .fixed("Docket"))]),
            SetupStep(id: "gmail.api", title: "Turn on the Gmail API",
                      detail: "Check that Docket is the project shown at the top, then click Enable.",
                      link: gmailAPIPage, linkTitle: "Open Gmail API"),
            SetupStep(id: "gmail.consent", title: "Set up the Google sign-in screen",
                      detail: "Click Get started. App name: Docket. Support email and contact email: your address. Audience: External. Agree, then Create.",
                      link: consentPage, linkTitle: "Open sign-in setup",
                      copies: [SetupStep.Copy(label: "App name", kind: .fixed("Docket")), SetupStep.Copy(label: "Your address", kind: .email)]),
            SetupStep(id: "gmail.testUsers", title: "Add yourself as a test user",
                      detail: "Under Test users, click Add users, paste your Gmail address, click Save. Skip this and Google says “Access blocked”.",
                      link: audiencePage, linkTitle: "Open Audience",
                      copies: [SetupStep.Copy(label: "Your address", kind: .email)]),
            SetupStep(id: "gmail.client", title: "Create a Desktop app client",
                      detail: "Application type: Desktop app. Name: Docket. Click Create. Leave the page open: it shows the Client ID and Client secret.",
                      link: clientPage, linkTitle: "Open Clients",
                      copies: [SetupStep.Copy(label: "Application type", kind: .fixed("Desktop app")), SetupStep.Copy(label: "Name", kind: .fixed("Docket"))]),
            SetupStep(id: "gmail.paste", title: "Paste the Client ID and Client secret here",
                      detail: "Copy each one from the page Google showed (or from the client's page under Clients), paste it below, click Save.",
                      verifiable: true),
            SetupStep(id: "gmail.signIn", title: f.connected ? "Sign in again to allow starring and replying" : "Sign in with Google",
                      detail: "Pick your account. Google will say the app isn't verified: click Continue. Tick every box it shows, then Continue.",
                      verifiable: true),
            SetupStep(id: "gmail.publish", title: "Keep Gmail signed in: publish the app",
                      detail: "On the Audience page, click Publish app, then Confirm. Until you do, Google signs Docket out every 7 days. (You'll still see the “isn't verified” notice when signing in. That's fine for your own app.)",
                      link: audiencePage, linkTitle: "Open Audience"),
        ]
        return resolve(steps, verified: ["gmail.paste": f.hasClient || f.connected, "gmail.signIn": f.connected && f.canModify], ticked: ticked)
    }

    /// Marks each step done: one Docket can check by what it found (`verified`); any other when the user ticked
    /// it, or once a later step Docket can check is done (so a working setup reads as all done).
    static func resolve(_ steps: [SetupStep], verified: [String: Bool], ticked: Set<String>) -> [SetupStep] {
        var result = steps
        var laterDone = false
        for i in result.indices.reversed() {
            if result[i].verifiable {
                result[i].done = verified[result[i].id] ?? false
                if result[i].done { laterDone = true }
            } else {
                result[i].done = ticked.contains(result[i].id) || laterDone
            }
        }
        return result
    }

    /// The step to do next: the first one not done (nil when all are).
    static func current(_ steps: [SetupStep]) -> String? {
        steps.first { !$0.done }?.id
    }

    /// "2 of 7 done".
    static func progress(_ steps: [SetupStep]) -> String {
        "\(steps.filter(\.done).count) of \(steps.count) done"
    }

    /// The steps the user ticked, as kept in UserDefaults ("slack.create,slack.install").
    static func ticked(_ raw: String) -> Set<String> {
        Set(raw.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty })
    }

    static func raw(_ ticked: Set<String>) -> String {
        ticked.sorted().joined(separator: ",")
    }
}

extension Prefs.Key {
    /// Setup steps the user ticked, per service; the Google address they typed for the steps.
    static let setupTickedSlack = "setupTicked.slack"
    static let setupTickedGmail = "setupTicked.gmail"
    static let setupGoogleAddress = "setupGoogleAddress"
}

// MARK: - The checklist

/// A numbered checklist in a settings card: the next step open (what to do, the page to open, things to copy,
/// and `extra` for its fields), done ones as one line with a ✓, later ones as one quiet line. Any step opens
/// with a click.
struct SetupChecklist<Extra: View>: View {
    let steps: [SetupStep]
    /// The open step's main button is the page's one primary button.
    let leads: Bool
    @Binding var ticked: Set<String>
    /// The user's Google address, for copy buttons that need it.
    @Binding var email: String
    /// A step to show open whatever its state (the status line asked for it).
    var forceOpen: String?
    /// The step's fields and buttons beyond the standard ones; `leads`: its main button is the primary.
    @ViewBuilder let extra: (SetupStep, _ leads: Bool) -> Extra
    @State private var opened: String?

    var body: some View {
        let current = SetupSteps.current(steps)
        let open = opened ?? forceOpen ?? current
        VStack(spacing: 0) {
            ForEach(Array(steps.enumerated()), id: \.element.id) { i, step in
                SetupStepRow(number: i + 1, step: step, isOpen: step.id == open, isCurrent: step.id == current,
                             leads: leads && step.id == current, isLast: i == steps.count - 1, email: $email,
                             toggle: { withAnimation(Motion.snappy) { opened = open == step.id ? (step.id == current ? "" : nil) : step.id } },
                             tick: { done in
                                 withAnimation(Motion.snappy) {
                                     if done { ticked.insert(step.id) } else { ticked.remove(step.id) }
                                     opened = nil
                                 }
                             }) {
                    extra(step, leads && step.id == current)
                }
            }
        }
        .onChange(of: current) { _ in
            // A step got done: on to the next one.
            withAnimation(Motion.snappy) { opened = nil }
        }
    }
}

private struct SetupStepRow<Extra: View>: View {
    let number: Int
    let step: SetupStep
    let isOpen: Bool
    let isCurrent: Bool
    let leads: Bool
    let isLast: Bool
    @Binding var email: String
    let toggle: () -> Void
    let tick: (Bool) -> Void
    @ViewBuilder let extra: Extra

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button(action: toggle) {
                HStack(alignment: .center, spacing: Space.md) {
                    marker
                    Text(step.title)
                        .font(.system(size: 14, weight: isOpen ? .semibold : .medium))
                        .foregroundStyle(step.done && !isOpen ? Color.ink2 : (isCurrent || isOpen ? Color.ink : Color.ink3))
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: Space.sm)
                    if !isOpen {
                        Image(systemName: "chevron.down")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(Color.ink3)
                    }
                }
                .padding(.vertical, isOpen ? 12 : 10)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(isOpen ? "Close this step" : (step.done ? "Done. Click to see this step again" : "Click to see this step"))
            .accessibilityLabel("Step \(number): \(step.title)\(step.done ? ", done" : "")")

            if isOpen {
                VStack(alignment: .leading, spacing: Space.sm) {
                    if let detail = step.detail {
                        Text(detail)
                            .textStyle(.footnote)
                            .foregroundStyle(Color.ink2)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if step.link != nil || !step.copies.isEmpty {
                        FlowRow {
                            if let link = step.link {
                                linkButton(link)
                            }
                            ForEach(Array(step.copies.enumerated()), id: \.offset) { _, copy in
                                CopyChip(copy: copy, email: $email)
                            }
                        }
                    }
                    extra
                    if !step.verifiable {
                        HStack(spacing: Space.sm) {
                            if step.done {
                                Button("Not done yet") { tick(false) }
                                    .buttonStyle(.plain)
                                    .font(.system(size: 12.5, weight: .semibold))
                                    .foregroundStyle(Color.ink2)
                                    .help("Mark this step as not done")
                            } else {
                                Button { tick(true) } label: { Label("Done", systemImage: "checkmark") }
                                    .buttonStyle(SecondaryPill(height: 28))
                                    .help("I did this step: on to the next one")
                            }
                        }
                        .padding(.top, 2)
                    }
                }
                .padding(.leading, 22 + Space.md)
                .padding(.bottom, Space.md)
                .transition(.opacity)
            }
        }
        .padding(.horizontal, Space.lg)
        .overlay(alignment: .bottom) {
            if !isLast { Rectangle().fill(Color.hair).frame(height: 1).padding(.leading, Space.lg) }
        }
    }

    /// ✓ when done; the number, in ink for the step to do now.
    private var marker: some View {
        ZStack {
            if step.done {
                Circle().fill(Color.primaryFill)
                Image(systemName: "checkmark")
                    .font(.system(size: 10, weight: .heavy))
                    .foregroundStyle(Color.onPrimary)
            } else {
                Circle().fill(isCurrent ? Color.fillStrong : Color.fill)
                Text("\(number)")
                    .font(.system(size: 12, weight: .bold))
                    .monospacedDigit()
                    .foregroundStyle(isCurrent ? Color.ink : Color.ink3)
            }
        }
        .frame(width: 22, height: 22)
        .accessibilityHidden(true)
    }

    @ViewBuilder
    private func linkButton(_ url: URL) -> some View {
        let title = step.linkTitle ?? "Open"
        let help = "Opens \(url.host ?? "the page") in your browser"
        // An unchecked step's link is what to do; a step with fields of its own leads with those.
        if leads && !step.verifiable {
            Button { NSWorkspace.shared.open(url) } label: { Label(title, systemImage: "arrow.up.right") }
                .buttonStyle(PrimaryPill(height: 30))
                .help(help)
        } else {
            Button { NSWorkspace.shared.open(url) } label: { Label(title, systemImage: "arrow.up.right") }
                .buttonStyle(SecondaryPill(height: 30))
                .help(help)
        }
    }
}

/// "Desktop app ⧉": a value to paste somewhere, copied with a click. The user's address is typed once first.
private struct CopyChip: View {
    let copy: SetupStep.Copy
    @Binding var email: String
    @State private var copied = false

    var body: some View {
        switch copy.kind {
        case .fixed(let value):
            chip(value)
        case .email:
            HStack(spacing: 6) {
                TextField("you@gmail.com", text: $email)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(Color.ink)
                    .frame(width: 170)
                    .help("Your Gmail address, to paste in Google Cloud")
                Button { put(email) } label: {
                    Image(systemName: copied ? "checkmark" : "doc.on.doc")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Color.ink)
                }
                .buttonStyle(.plain)
                .disabled(email.trimmingCharacters(in: .whitespaces).isEmpty)
                .help("Copy your address")
                .accessibilityLabel("Copy your address")
            }
            .padding(.horizontal, 12)
            .frame(height: 30)
            .background(Capsule().fill(Color.fill))
        }
    }

    private func chip(_ value: String) -> some View {
        Button { put(value) } label: {
            HStack(spacing: 6) {
                Text(copy.label + ":")
                    .foregroundStyle(Color.ink2)
                Text(value)
                    .foregroundStyle(Color.ink)
                Image(systemName: copied ? "checkmark" : "doc.on.doc")
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(Color.ink2)
            }
            .font(.system(size: 12.5, weight: .semibold))
            .lineLimit(1)
            .padding(.horizontal, 12)
            .frame(height: 30)
            .background(Capsule().fill(Color.fill))
            .overlay(Capsule().strokeBorder(Color.hair, lineWidth: 1))
            .contentShape(Capsule())
        }
        .buttonStyle(PressScale(scale: 0.97))
        .help("Copy “\(value)” to paste in the page")
        .accessibilityLabel("Copy \(value)")
    }

    private func put(_ value: String) {
        let text = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        withAnimation(Motion.fast) { copied = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) { withAnimation(Motion.fast) { copied = false } }
    }
}

/// Buttons and chips on as many lines as they need.
private struct FlowRow<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: Space.sm) { content }
            VStack(alignment: .leading, spacing: Space.sm) { content }
        }
    }
}

/// "Setup · all 4 steps done ✓   Show steps": a finished checklist as one line.
struct SetupDoneRow: View {
    let count: Int
    let show: () -> Void

    var body: some View {
        HStack(spacing: Space.md) {
            ZStack {
                Circle().fill(Color.primaryFill)
                Image(systemName: "checkmark")
                    .font(.system(size: 10, weight: .heavy))
                    .foregroundStyle(Color.onPrimary)
            }
            .frame(width: 22, height: 22)
            .accessibilityHidden(true)
            Text("Setup done · all \(count) steps")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(Color.ink2)
            Spacer(minLength: Space.sm)
            Button("Show steps", action: show)
                .buttonStyle(.plain)
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(Color.ink2)
                .help("See the setup steps again")
        }
        .padding(.horizontal, Space.lg)
        .frame(minHeight: 44)
        .overlay(alignment: .bottom) { Rectangle().fill(Color.hair).frame(height: 1).padding(.leading, Space.lg) }
    }
}

// MARK: - Check setup

/// "Check setup": runs the real checks on demand and lists what works (✓) and what to fix (✗, the fix in plain
/// words and a button for it).
struct SetupCheckSection: View {
    @ObservedObject private var integrations = Integrations.shared
    /// Runs once as it appears (opened from Messages' ⋯ → Check Setup).
    let runOnAppear: Bool
    let fix: (SetupCheckItem.Fix) -> Void
    @State private var results: [SetupCheckItem]?
    @State private var running = false
    @State private var checkedAt: Date?

    var body: some View {
        SettingsSection(title: "Check setup") {
            SettingsRow(title: headline, subtitle: subtitle, divider: results?.isEmpty == false) {
                Button {
                    Task { await run() }
                } label: {
                    if running {
                        HStack(spacing: 6) {
                            ProgressView().controlSize(.small)
                            Text("Checking…")
                        }
                    } else {
                        Label(results == nil ? "Check setup" : "Check again", systemImage: "checkmark.shield")
                    }
                }
                .buttonStyle(SecondaryPill(height: 30))
                .disabled(running)
                .help("Ask Slack, Google and Gemini right now whether everything works")
            }
            if let results {
                ForEach(Array(results.enumerated()), id: \.element.id) { i, item in
                    SetupCheckRow(item: item, divider: i < results.count - 1, fix: fix)
                }
            }
        }
        .task {
            if runOnAppear, results == nil { await run() }
        }
    }

    private var headline: String {
        guard let results, !running else { return "See that everything works" }
        let problems = results.filter { !$0.ok }.count
        return problems == 0 ? "Everything works" : "\(Fmt.plural(problems, "thing")) to fix"
    }

    private var subtitle: String {
        if running { return "Asking Slack, Google and Gemini…" }
        if let checkedAt { return "Checked \(Fmt.time(checkedAt)). Slack, Gmail and AI, for real." }
        return "Docket asks Slack, Google and Gemini right now and tells you what to fix."
    }

    private func run() async {
        guard !running else { return }
        running = true
        let found = await integrations.checkSetup()
        withAnimation(Motion.base) {
            results = found
            checkedAt = Date()
        }
        running = false
    }
}

private struct SetupCheckRow: View {
    let item: SetupCheckItem
    let divider: Bool
    let fix: (SetupCheckItem.Fix) -> Void

    var body: some View {
        HStack(alignment: .top, spacing: Space.md) {
            Image(systemName: item.ok ? "checkmark.circle.fill" : "xmark.circle.fill")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(item.ok ? Color.success : Color.danger)
                .frame(width: 22)
                .accessibilityLabel(item.ok ? "Works" : "Needs fixing")
            VStack(alignment: .leading, spacing: 2) {
                Text("\(item.service.rawValue) · \(item.title)")
                    .font(.system(size: 13.5, weight: .medium))
                    .foregroundStyle(Color.ink)
                if let detail = item.detail {
                    Text(detail)
                        .textStyle(.footnote)
                        .foregroundStyle(Color.ink2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: Space.sm)
            if let f = item.fix, !item.ok {
                Button(f.title) { fix(f) }
                    .buttonStyle(SecondaryPill(height: 28))
                    .help(helpText(f))
            }
        }
        .padding(.horizontal, Space.lg)
        .padding(.vertical, 10)
        .overlay(alignment: .bottom) {
            if divider { Rectangle().fill(Color.hair).frame(height: 1).padding(.leading, Space.lg) }
        }
        .transition(.opacity)
    }

    private func helpText(_ f: SetupCheckItem.Fix) -> String {
        switch f {
        case .setUpSlack: "Go to the Slack steps on this page"
        case .updateSlack: "Opens Slack to create the Docket app again with every permission"
        case .setUpGmail: "Go to the Gmail steps on this page"
        case .signInGmail: "Opens Google sign-in in your browser"
        case .aiSettings: "Opens Settings → AI"
        }
    }
}
