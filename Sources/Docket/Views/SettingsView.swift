import AppKit
import ServiceManagement
import SwiftUI
import UserNotifications

struct SettingsView: View {
    // Six tabs at 94pt fit the 620pt window; labels stay one short word (the longest, "Connections", is ~72pt).
    enum Tab: String, CaseIterable, Identifiable {
        case general = "General", alerts = "Reminders", planner = "Planner", ai = "AI", connections = "Connections", data = "Data"
        var id: String { rawValue }
        var icon: String {
            switch self {
            case .general: "gearshape"
            case .alerts: "alarm"
            case .planner: "calendar"
            case .ai: "sparkles"
            case .connections: "link"
            case .data: "externaldrive"
            }
        }
    }

    @State private var tab: Tab = .general
    @Namespace private var ns

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                ForEach(Tab.allCases) { t in
                    Button { withAnimation(Motion.snappy) { tab = t } } label: {
                        VStack(spacing: 5) {
                            Image(systemName: t.icon).font(.system(size: 17, weight: .medium))
                            Text(t.rawValue).font(.system(size: 11.5, weight: .semibold))
                        }
                        .foregroundStyle(tab == t ? Color.onPrimary : Color.ink2)
                        .frame(width: 94, height: 56)
                        .background {
                            if tab == t {
                                RoundedRectangle(cornerRadius: Radius.md, style: .continuous)
                                    .fill(Color.primaryFill)
                                    .matchedGeometryEffect(id: "settings-tab", in: ns)
                            }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(PressScale(scale: 0.97))
                }
            }
            .padding(.vertical, Space.md)
            Rectangle().fill(Color.hair).frame(height: 1)
            Group {
                switch tab {
                case .general: GeneralSettings()
                case .alerts: AlertSettings()
                case .planner: PlannerSettings()
                case .ai: AISettingsPage()
                case .connections: ConnectionsSettingsPage()
                case .data: DataSettings()
                }
            }
            .transition(.opacity)
        }
        .frame(width: 620, height: 560)
        .background(Color.paper)
        .tint(Color.ink)
    }
}

// MARK: - Building blocks (shared with the AI and Connections pages)

struct SettingsPage<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Space.xxl) {
                content
            }
            .padding(.horizontal, Space.xxl)
            .padding(.vertical, Space.xl)
        }
    }
}

struct SettingsSection<Content: View>: View {
    var title: String
    var footer: String?
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: Space.sm) {
            Eyebrow(text: title).padding(.leading, 4)
            VStack(spacing: 0) { content }
                .hairlineCard(radius: Radius.lg)
            if let footer {
                Text(footer)
                    .textStyle(.footnote)
                    .foregroundStyle(Color.ink2)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 4)
            }
        }
    }
}

struct SettingsRow<Trailing: View>: View {
    var title: String
    var subtitle: String?
    var divider = true
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(spacing: Space.md) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(Color.ink)
                if let subtitle {
                    Text(subtitle)
                        .textStyle(.footnote)
                        .foregroundStyle(Color.ink2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
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

struct ToggleRow: View {
    var title: String
    var subtitle: String?
    @Binding var isOn: Bool
    var divider = true

    var body: some View {
        SettingsRow(title: title, subtitle: subtitle, divider: divider) {
            Toggle("", isOn: $isOn)
                .toggleStyle(.switch)
                .labelsHidden()
                .controlSize(.small)
        }
    }
}

/// A value pill that opens a menu of choices.
struct ChoiceMenu<Value: Hashable>: View {
    @Binding var selection: Value
    var options: [(Value, String)]

    var body: some View {
        Menu {
            ForEach(options, id: \.0) { value, label in
                Button {
                    selection = value
                } label: {
                    if value == selection { Label(label, systemImage: "checkmark") } else { Text(label) }
                }
            }
        } label: {
            // One Text with the chevron inline: macOS moves a label's separate image to the front.
            (Text(options.first { $0.0 == selection }?.1 ?? "") + Text("  ") + Text(Image(systemName: "chevron.up.chevron.down")).font(.system(size: 9, weight: .bold)))
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Color.ink)
                .padding(.horizontal, 12)
                .frame(height: 30)
        }
        .menuChrome(Capsule())
    }
}

// MARK: - General

struct GeneralSettings: View {
    @EnvironmentObject var app: AppState
    @AppStorage(Prefs.Key.showMenuBar) private var showMenuBar = true
    @AppStorage(Prefs.Key.menuBarShowsCount) private var menuBarShowsCount = true
    @AppStorage(Prefs.Key.dockBadge) private var dockBadge = true
    @AppStorage(Prefs.Key.hideDockIcon) private var hideDockIcon = false
    @AppStorage(Prefs.Key.hotkeyEnabled) private var hotkeyEnabled = true
    @AppStorage(Prefs.Key.hotkeyPreset) private var hotkeyPreset = HotKeyPreset.controlOptionT.rawValue
    @AppStorage(Prefs.Key.appearance) private var appearance = AppearanceMode.system.rawValue
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var loginError: String?

    var body: some View {
        SettingsPage {
            SettingsSection(title: "Startup", footer: loginError ?? "Docket needs to be running for alarms to ring. Reminders still arrive as notifications when it's closed.") {
                ToggleRow(title: "Open Docket when I log in", isOn: Binding(get: { launchAtLogin }, set: setLaunchAtLogin), divider: false)
            }

            SettingsSection(title: "Appearance") {
                SettingsRow(title: "Theme", divider: false) {
                    SegmentedControl(selection: $appearance, options: AppearanceMode.allCases.map { ($0.rawValue, $0.label) })
                }
            }

            SettingsSection(title: "Quick capture",
                            footer: hotkeyEnabled && !app.hotkeyRegistered ? "Another app is using this shortcut. Pick a different one." : nil) {
                ToggleRow(title: "Global shortcut", subtitle: "Opens Quick Capture from any app", isOn: $hotkeyEnabled)
                SettingsRow(title: "Shortcut", divider: false) {
                    ChoiceMenu(selection: $hotkeyPreset, options: HotKeyPreset.allCases.map { ($0.rawValue, $0.rawValue) })
                        .disabled(!hotkeyEnabled)
                        .opacity(hotkeyEnabled ? 1 : 0.4)
                }
            }

            SettingsSection(title: "Menu bar and Dock") {
                ToggleRow(title: "Show Docket in the menu bar", isOn: $showMenuBar)
                ToggleRow(title: "Today's count next to the menu bar icon", isOn: $menuBarShowsCount)
                    .disabled(!showMenuBar)
                    .opacity(showMenuBar ? 1 : 0.45)
                ToggleRow(title: "Today's count on the Dock icon", isOn: $dockBadge)
                ToggleRow(title: "Menu-bar-only mode", subtitle: "Hide the Dock icon when the window is closed", isOn: $hideDockIcon, divider: false)
                    .disabled(!showMenuBar)
                    .opacity(showMenuBar ? 1 : 0.45)
            }
        }
    }

    private func setLaunchAtLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            loginError = nil
        } catch {
            loginError = "Couldn't change this: \(error.localizedDescription). Move Docket to Applications and try again."
        }
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }
}

// MARK: - Reminders and alarms

struct AlertSettings: View {
    @EnvironmentObject var notifications: NotificationService
    @EnvironmentObject var alarms: AlarmService
    @AppStorage(Prefs.Key.defaultReminder) private var defaultReminder = 15
    @AppStorage(Prefs.Key.defaultReminderIsAlarm) private var defaultIsAlarm = false
    @AppStorage(Prefs.Key.allDayHour) private var allDayHour = 9
    @AppStorage(Prefs.Key.alarmSound) private var alarmSound = AlarmSound.docket.rawValue
    @AppStorage(Prefs.Key.briefingEnabled) private var briefingEnabled = true
    @AppStorage(Prefs.Key.briefingMinutes) private var briefingMinutes = 8 * 60 + 30

    var body: some View {
        SettingsPage {
            SettingsSection(title: "Notifications",
                            footer: NotificationService.isAvailable ? nil : "Notifications only work when Docket runs as an app (build it with scripts/build.sh).") {
                SettingsRow(title: "macOS notifications", divider: false) {
                    HStack(spacing: Space.sm) {
                        switch notifications.authorization {
                        case .authorized, .provisional:
                            Badge(text: "On", tone: .success, icon: "checkmark")
                        case .denied:
                            Badge(text: "Turned off", tone: .danger)
                        default:
                            Badge(text: "Not set up", tone: .warning)
                        }
                        if notifications.authorization == .notDetermined {
                            Button("Allow") { notifications.requestAuthorization() }
                                .buttonStyle(PrimaryPill(height: 30))
                        } else {
                            Button("System Settings") { notifications.openSystemSettings() }
                                .buttonStyle(SecondaryPill(height: 30))
                        }
                    }
                }
            }

            SettingsSection(title: "Defaults for new tasks") {
                SettingsRow(title: "Remind me", subtitle: "When a task has a deadline time") {
                    ChoiceMenu(selection: $defaultReminder, options: [(-1, "Never"), (0, "At the deadline")]
                        + [5, 10, 15, 30, 60].map { ($0, "\(Fmt.duration(minutes: $0)) before") })
                }
                ToggleRow(title: "Use a loud alarm", subtitle: "Instead of a quiet notification", isOn: $defaultIsAlarm)
                    .disabled(defaultReminder < 0)
                    .opacity(defaultReminder < 0 ? 0.45 : 1)
                SettingsRow(title: "Date-only reminders", subtitle: "For deadlines without a time", divider: false) {
                    ChoiceMenu(selection: $allDayHour, options: (5...13).map { ($0, Fmt.hourLabel($0)) })
                }
            }

            SettingsSection(title: "Alarms", footer: "Alarms ring until you snooze or dismiss them. The sound stops after 5 minutes; the window stays.") {
                SettingsRow(title: "Sound") {
                    HStack(spacing: Space.sm) {
                        ChoiceMenu(selection: $alarmSound, options: AlarmSound.allCases.map { ($0.rawValue, $0.rawValue) })
                        Button { SoundPlayer.playPreview(AlarmSound(rawValue: alarmSound) ?? .docket) } label: { Image(systemName: "play.fill") }
                            .buttonStyle(IconButtonStyle(size: 30, filled: true))
                            .help("Preview")
                    }
                }
                SettingsRow(title: "Try it", subtitle: "Rings a sample alarm now", divider: false) {
                    Button("Test alarm") { alarms.test() }
                        .buttonStyle(SecondaryPill(height: 30))
                }
            }

            SettingsSection(title: "Morning briefing") {
                ToggleRow(title: "Send a summary of the day", isOn: $briefingEnabled)
                SettingsRow(title: "At", divider: false) {
                    TimeOfDayPicker(minutes: $briefingMinutes)
                        .disabled(!briefingEnabled)
                        .opacity(briefingEnabled ? 1 : 0.4)
                }
            }
        }
        .onAppear { notifications.refreshStatus() }
    }
}

// MARK: - Planner

struct PlannerSettings: View {
    @EnvironmentObject var calendar: CalendarService
    @AppStorage(Prefs.Key.workdayStart) private var workdayStart = 9 * 60
    @AppStorage(Prefs.Key.workdayEnd) private var workdayEnd = 18 * 60
    @AppStorage(Prefs.Key.focusMinutes) private var focusMinutes = 25
    @AppStorage(Prefs.Key.useCalendar) private var useCalendar = false

    var body: some View {
        SettingsPage {
            SettingsSection(title: "Workday", footer: "“eod” in quick add means the end of your workday.") {
                SettingsRow(title: "Starts") { TimeOfDayPicker(minutes: $workdayStart) }
                SettingsRow(title: "Ends", divider: false) { TimeOfDayPicker(minutes: $workdayEnd) }
            }

            SettingsSection(title: "Calendar",
                            footer: calendar.isDenied ? "Calendar access is off for Docket."
                                : (useCalendar ? "Meetings appear in Calendar next to your tasks, with their times on the right." : nil)) {
                ToggleRow(title: "Show calendar events", subtitle: "Your meetings, next to your tasks", isOn: Binding(get: { useCalendar }, set: { on in
                    if on {
                        Task {
                            let ok = await calendar.requestAccess()
                            useCalendar = ok
                            calendar.refresh()
                        }
                    } else {
                        useCalendar = false
                        calendar.refresh()
                    }
                }), divider: calendar.isDenied)
                if calendar.isDenied {
                    SettingsRow(title: "Allow access", subtitle: "In Privacy and Security", divider: false) {
                        Button("Open Settings") {
                            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars")!)
                        }
                        .buttonStyle(SecondaryPill(height: 30))
                    }
                }
            }

            SettingsSection(title: "Focus") {
                SettingsRow(title: "Default session", subtitle: "For tasks without an estimate", divider: false) {
                    NumberStepper(value: $focusMinutes, range: 5...180, step: 5) { Fmt.duration(minutes: $0) }
                }
            }
        }
    }
}

// MARK: - Data

struct DataSettings: View {
    @EnvironmentObject var store: Store

    var body: some View {
        SettingsPage {
            SettingsSection(title: "Storage", footer: "Everything stays on this Mac. Docket keeps a daily backup of your tasks and notes for 30 days; photos and videos live in the attachments folder next to the data file.") {
                SettingsRow(title: "Data file", subtitle: store.persistence.fileURL.path) {
                    Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([store.persistence.fileURL]) }
                        .buttonStyle(SecondaryPill(height: 30))
                }
                SettingsRow(title: "Backups", divider: false) {
                    Button("Open folder") {
                        try? FileManager.default.createDirectory(at: store.persistence.backupsURL, withIntermediateDirectories: true)
                        NSWorkspace.shared.open(store.persistence.backupsURL)
                    }
                    .buttonStyle(SecondaryPill(height: 30))
                }
            }

            SettingsSection(title: "Import and export") {
                SettingsRow(title: "Back up everything", subtitle: "Tasks, notes and lists as one file. Photos and videos go in an attachments folder next to it.") {
                    Button("Export") { DataTransfer.export(store: store) }
                        .buttonStyle(SecondaryPill(height: 30))
                }
                SettingsRow(title: "Restore or merge a backup") {
                    Button("Import") { DataTransfer.import(store: store) }
                        .buttonStyle(SecondaryPill(height: 30))
                }
                SettingsRow(title: "Notes as Markdown", subtitle: "One .md file per note", divider: false) {
                    Button("Export") { DataTransfer.exportNotes(store: store) }
                        .buttonStyle(SecondaryPill(height: 30))
                }
            }

            SettingsSection(title: "About") {
                let info = Bundle.main.infoDictionary
                SettingsRow(title: "Version") {
                    Text("\(info?["CFBundleShortVersionString"] as? String ?? "dev") (\(info?["CFBundleVersion"] as? String ?? "0"))")
                        .font(.system(size: 13, weight: .semibold))
                        .monospacedDigit()
                        .foregroundStyle(Color.ink2)
                }
                SettingsRow(title: "Tasks and notes", divider: false) {
                    Text("\(store.tasks.count) tasks · \(store.notes.count) notes")
                        .font(.system(size: 13, weight: .semibold))
                        .monospacedDigit()
                        .foregroundStyle(Color.ink2)
                }
            }
        }
    }
}
