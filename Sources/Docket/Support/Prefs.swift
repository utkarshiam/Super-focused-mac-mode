import Foundation

/// UserDefaults keys and typed accessors. Views use @AppStorage with the same keys.
enum Prefs {
    enum Key {
        static let workdayStart = "workdayStartMinutes"
        static let workdayEnd = "workdayEndMinutes"
        static let defaultReminder = "defaultReminderMinutes"     // -1 = none
        static let defaultReminderIsAlarm = "defaultReminderIsAlarm"
        static let allDayHour = "allDayReminderHour"
        static let alarmSound = "alarmSound"
        static let briefingEnabled = "briefingEnabled"
        static let briefingMinutes = "briefingMinutes"
        static let showMenuBar = "showMenuBarIcon"
        static let menuBarShowsCount = "menuBarShowsCount"
        static let dockBadge = "dockBadge"
        static let hideDockIcon = "hideDockIcon"
        static let hotkeyEnabled = "hotkeyEnabled"
        static let hotkeyPreset = "hotkeyPreset"
        static let focusMinutes = "focusDefaultMinutes"
        static let useCalendar = "useCalendarForCapacity"
        static let sortMode = "taskSortMode"
        static let showCompletedInLists = "showCompletedInLists"
        static let appearance = "appearance"
        static let compactRows = "compactRows"
    }

    static func registerDefaults() {
        UserDefaults.standard.register(defaults: [
            Key.workdayStart: 9 * 60,
            Key.workdayEnd: 18 * 60,
            Key.defaultReminder: 15,
            Key.defaultReminderIsAlarm: false,
            Key.allDayHour: 9,
            Key.alarmSound: AlarmSound.docket.rawValue,
            Key.briefingEnabled: true,
            Key.briefingMinutes: 8 * 60 + 30,
            Key.showMenuBar: true,
            Key.menuBarShowsCount: true,
            Key.dockBadge: true,
            Key.hideDockIcon: false,
            Key.hotkeyEnabled: true,
            Key.hotkeyPreset: HotKeyPreset.controlOptionT.rawValue,
            Key.focusMinutes: 25,
            Key.useCalendar: false,
            Key.sortMode: SortMode.smart.rawValue,
            Key.showCompletedInLists: false,
            Key.appearance: AppearanceMode.system.rawValue,
        ])
    }

    private static var d: UserDefaults { .standard }

    static var workdayStart: Int { d.integer(forKey: Key.workdayStart) }
    static var workdayEnd: Int { d.integer(forKey: Key.workdayEnd) }
    static var defaultReminder: Int { d.integer(forKey: Key.defaultReminder) }
    static var defaultReminderIsAlarm: Bool { d.bool(forKey: Key.defaultReminderIsAlarm) }
    static var allDayHour: Int { d.integer(forKey: Key.allDayHour) }
    static var alarmSound: AlarmSound { AlarmSound(rawValue: d.string(forKey: Key.alarmSound) ?? "") ?? .docket }
    static var briefingEnabled: Bool { d.bool(forKey: Key.briefingEnabled) }
    static var briefingMinutes: Int { d.integer(forKey: Key.briefingMinutes) }
    static var showMenuBar: Bool { d.bool(forKey: Key.showMenuBar) }
    static var menuBarShowsCount: Bool { d.bool(forKey: Key.menuBarShowsCount) }
    static var dockBadge: Bool { d.bool(forKey: Key.dockBadge) }
    /// Only honoured while the menu bar icon is visible, so the app can always be reached.
    static var hideDockIcon: Bool { d.bool(forKey: Key.hideDockIcon) && showMenuBar }
    static var hotkeyEnabled: Bool { d.bool(forKey: Key.hotkeyEnabled) }
    static var hotkeyPreset: HotKeyPreset { HotKeyPreset(rawValue: d.string(forKey: Key.hotkeyPreset) ?? "") ?? .controlOptionT }
    static var focusMinutes: Int { max(1, d.integer(forKey: Key.focusMinutes)) }
    static var useCalendar: Bool { d.bool(forKey: Key.useCalendar) }
    static var appearance: AppearanceMode { AppearanceMode(rawValue: d.string(forKey: Key.appearance) ?? "") ?? .system }
}

enum SortMode: String, CaseIterable, Identifiable {
    case smart, dueDate, priority, estimate, title
    var id: String { rawValue }
    var label: String {
        switch self {
        case .smart: "Smart"
        case .dueDate: "Deadline"
        case .priority: "Priority"
        case .estimate: "Shortest first"
        case .title: "Title"
        }
    }
}

enum AppearanceMode: String, CaseIterable, Identifiable {
    case system, light, dark
    var id: String { rawValue }
    var label: String {
        switch self {
        case .system: "Match System"
        case .light: "Light"
        case .dark: "Dark"
        }
    }
}

enum AlarmSound: String, CaseIterable, Identifiable {
    case docket = "Docket Alarm"
    case sosumi = "Sosumi"
    case glass = "Glass"
    case hero = "Hero"
    case submarine = "Submarine"
    case funk = "Funk"
    case ping = "Ping"
    case purr = "Purr"
    var id: String { rawValue }
}

enum HotKeyPreset: String, CaseIterable, Identifiable {
    case controlOptionT = "⌃⌥T"
    case controlOptionSpace = "⌃⌥Space"
    case controlOptionN = "⌃⌥N"
    case commandShiftSpace = "⇧⌘Space"
    case commandOptionK = "⌥⌘K"
    var id: String { rawValue }
}
