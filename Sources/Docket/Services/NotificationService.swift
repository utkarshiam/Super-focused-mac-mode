import AppKit
@preconcurrency import UserNotifications

/// Schedules macOS notifications for reminders and the morning briefing, and handles their action buttons.
/// The pending set is diffed on every data change, so edits are reflected immediately.
@MainActor
final class NotificationService: NSObject, ObservableObject {
    static let shared = NotificationService()

    @Published private(set) var authorization: UNAuthorizationStatus = .notDetermined

    weak var store: Store?
    weak var app: AppState?
    private var rescheduleTask: Task<Void, Never>?

    enum Category {
        static let task = "TASK"
        static let alarm = "ALARM"
        static let briefing = "BRIEFING"
        static let focus = "FOCUS"
    }

    enum Action {
        static let complete = "COMPLETE"
        static let snooze10 = "SNOOZE_10"
        static let snooze60 = "SNOOZE_60"
        static let tomorrow = "TOMORROW"
    }

    /// UNUserNotificationCenter crashes when the binary isn't inside an .app bundle (e.g. `swift run`).
    static var isAvailable: Bool {
        Bundle.main.bundleURL.pathExtension == "app" && Bundle.main.bundleIdentifier != nil
    }

    private var center: UNUserNotificationCenter? { Self.isAvailable ? .current() : nil }

    func setUp(store: Store, app: AppState) {
        self.store = store
        self.app = app
        guard let center else { return }
        center.delegate = self

        let complete = UNNotificationAction(identifier: Action.complete, title: "Complete")
        let snooze10 = UNNotificationAction(identifier: Action.snooze10, title: "Snooze 10 min")
        let snooze60 = UNNotificationAction(identifier: Action.snooze60, title: "Snooze 1 hour")
        let tomorrow = UNNotificationAction(identifier: Action.tomorrow, title: "Move to Tomorrow")
        let actions = [complete, snooze10, snooze60, tomorrow]
        center.setNotificationCategories([
            UNNotificationCategory(identifier: Category.task, actions: actions, intentIdentifiers: []),
            UNNotificationCategory(identifier: Category.alarm, actions: actions, intentIdentifiers: []),
            UNNotificationCategory(identifier: Category.briefing, actions: [], intentIdentifiers: []),
            UNNotificationCategory(identifier: Category.focus, actions: [], intentIdentifiers: []),
        ])
        requestAuthorization()
    }

    func requestAuthorization() {
        center?.requestAuthorization(options: [.alert, .sound, .badge]) { [weak self] _, _ in
            Task { @MainActor in self?.refreshStatus() }
        }
    }

    func refreshStatus() {
        center?.getNotificationSettings { [weak self] settings in
            let status = settings.authorizationStatus
            Task { @MainActor in self?.authorization = status }
        }
    }

    func openSystemSettings() {
        let id = Bundle.main.bundleIdentifier ?? ""
        if let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension?id=\(id)") {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: Scheduling

    func reschedule() {
        guard let center, let store else { return }
        let desired = buildRequests(store: store)
        rescheduleTask?.cancel()
        rescheduleTask = Task {
            let pending = await center.pendingNotificationRequests()
            guard !Task.isCancelled else { return }
            let ours = Set(pending.map(\.identifier).filter { $0.hasPrefix("r|") || $0.hasPrefix("b|") })
            let stale = ours.subtracting(desired.keys)
            if !stale.isEmpty { center.removePendingNotificationRequests(withIdentifiers: Array(stale)) }
            for (id, request) in desired where !ours.contains(id) {
                try? await center.add(request)
            }
        }
    }

    private func buildRequests(store: Store) -> [String: UNNotificationRequest] {
        let now = Date()
        let horizon = now.addingTimeInterval(21 * 86_400)
        let cal = Calendar.current
        var items: [(fire: Date, id: String, content: UNMutableNotificationContent)] = []

        for t in store.tasks where !t.isCompleted {
            for r in t.reminders {
                guard let fire = r.fireDate(for: t, allDayHour: Prefs.allDayHour), fire > now, fire < horizon else { continue }
                let content = UNMutableNotificationContent()
                content.title = r.isAlarm ? "⏰ \(t.title)" : t.title
                content.body = Self.body(for: t, reminder: r, list: store.list(t.listID))
                content.sound = r.isAlarm ? Self.alarmNotificationSound : .default
                content.categoryIdentifier = r.isAlarm ? Category.alarm : Category.task
                content.threadIdentifier = t.id.uuidString
                content.userInfo = ["taskID": t.id.uuidString, "isAlarm": r.isAlarm]
                let id = "r|\(t.id)|\(r.id)|\(Int(fire.timeIntervalSince1970))|\(stableHash(content.title + content.body))"
                items.append((fire, id, content))
            }
        }

        if Prefs.briefingEnabled {
            let today = cal.startOfDay(for: now)
            for offset in 0..<7 {
                let day = cal.date(byAdding: .day, value: offset, to: today)!
                guard let fire = cal.date(byAdding: .minute, value: Prefs.briefingMinutes, to: day), fire > now,
                      let content = briefing(for: day, isToday: offset == 0, store: store) else { continue }
                let id = "b|\(Fmt.dayKey(day))|\(stableHash(content.title + content.body))"
                items.append((fire, id, content))
            }
        }

        // macOS keeps a limited number of pending notifications per app; keep the soonest.
        items.sort { $0.fire < $1.fire }
        var result: [String: UNNotificationRequest] = [:]
        for item in items.prefix(60) {
            let comps = cal.dateComponents([.year, .month, .day, .hour, .minute, .second], from: item.fire)
            let trigger = UNCalendarNotificationTrigger(dateMatching: comps, repeats: false)
            result[item.id] = UNNotificationRequest(identifier: item.id, content: item.content, trigger: trigger)
        }
        return result
    }

    static func body(for t: TaskItem, reminder r: Reminder, list: TaskList?) -> String {
        var parts: [String] = []
        if let due = t.dueDate {
            switch r.trigger {
            case .beforeDue(let m) where m > 0:
                parts.append(t.dueHasTime ? "Due in \(Fmt.duration(minutes: m)) · \(Fmt.time(due))" : "Due \(Fmt.absoluteDay(due))")
            case .beforeDue:
                parts.append(t.dueHasTime ? "Due now · \(Fmt.time(due))" : "Due today")
            case .absolute:
                parts.append((r.isSnooze ? "Snoozed · " : "") + "Due \(Fmt.absoluteDay(due))" + (t.dueHasTime ? " at \(Fmt.time(due))" : ""))
            }
        } else {
            parts.append(r.isSnooze ? "Snoozed reminder" : "Reminder")
        }
        if let est = t.estimateMinutes { parts.append("~\(Fmt.duration(minutes: est))") }
        if let list { parts.append(list.name) }
        if t.priority >= .high { parts.append(t.priority.label + " priority") }
        return parts.joined(separator: " · ")
    }

    private func briefing(for day: Date, isToday: Bool, store: Store) -> UNMutableNotificationContent? {
        let cal = Calendar.current
        let items = store.tasks.filter { t in
            guard !t.isCompleted else { return false }
            let onDay = [t.dueDate, t.scheduledDate].compactMap { $0 }.contains { cal.isDate($0, inSameDayAs: day) }
            return onDay || (isToday && t.isOverdue(now: day, calendar: cal))
        }
        guard !items.isEmpty else { return nil }
        let overdue = isToday ? items.filter { $0.isOverdue(now: day, calendar: cal) }.count : 0
        let minutes = items.reduce(0) { $0 + $1.remainingMinutes }
        let firstTimed = items.filter { $0.dueHasTime && $0.dueDate.map { cal.isDate($0, inSameDayAs: day) } == true }
            .min { $0.dueDate! < $1.dueDate! }

        let content = UNMutableNotificationContent()
        content.title = "Good morning — \(Fmt.plural(items.count, "task")) today"
        var parts: [String] = []
        if minutes > 0 { parts.append("≈\(Fmt.duration(minutes: minutes)) planned") }
        if overdue > 0 { parts.append("\(overdue) overdue") }
        if let first = firstTimed, let due = first.dueDate { parts.append("First: \(Fmt.time(due)) \(first.title)") }
        let top = items.filter { $0.priority >= .high }.prefix(2).map(\.title)
        if !top.isEmpty { parts.append("Focus: " + top.joined(separator: ", ")) }
        content.body = parts.joined(separator: " · ")
        content.sound = .default
        content.categoryIdentifier = Category.briefing
        return content
    }

    static var alarmNotificationSound: UNNotificationSound {
        switch Prefs.alarmSound {
        case .docket:
            return UNNotificationSound(named: UNNotificationSoundName("DocketAlarm.wav"))
        case let other:
            return UNNotificationSound(named: UNNotificationSoundName("\(other.rawValue).aiff"))
        }
    }

    /// Immediate notification (focus timer finished, etc.).
    func deliver(title: String, body: String, category: String = Category.focus, taskID: UUID? = nil) {
        guard let center else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        content.categoryIdentifier = category
        if let taskID { content.userInfo = ["taskID": taskID.uuidString] }
        center.add(UNNotificationRequest(identifier: "n|\(UUID())", content: content, trigger: nil))
    }

    /// Clears a delivered alarm banner once the alarm window has taken over.
    func removeDelivered(forTask id: UUID) {
        guard let center else { return }
        center.getDeliveredNotifications { notes in
            let ids = notes.filter { $0.request.identifier.hasPrefix("r|\(id.uuidString)|") }.map(\.request.identifier)
            if !ids.isEmpty { center.removeDeliveredNotifications(withIdentifiers: ids) }
        }
    }

    // MARK: Actions

    fileprivate func handle(action: String, taskID: UUID?, isAlarm: Bool, category: String) {
        guard let store, let app else { return }
        switch action {
        case Action.complete:
            if let id = taskID { store.setCompleted(id, true) }
        case Action.snooze10:
            if let id = taskID { store.snooze(id, minutes: 10, isAlarm: isAlarm) }
        case Action.snooze60:
            if let id = taskID { store.snooze(id, minutes: 60, isAlarm: isAlarm) }
        case Action.tomorrow:
            if let id = taskID { store.pushToTomorrow(id) }
        case UNNotificationDefaultActionIdentifier:
            if category == Category.briefing {
                app.selection = .calendar
                app.goTo(day: Date())
                app.showMainWindow()
            } else if let id = taskID {
                app.reveal(task: id, in: store)
            } else {
                app.showMainWindow()
            }
        default:
            break
        }
    }
}

extension NotificationService: UNUserNotificationCenterDelegate {
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        // While Docket is running, alarms ring in their own window, so the banner would just be noise.
        if notification.request.content.categoryIdentifier == Category.alarm {
            completionHandler([.list])
        } else {
            completionHandler([.banner, .sound, .list])
        }
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let content = response.notification.request.content
        let taskID = (content.userInfo["taskID"] as? String).flatMap(UUID.init(uuidString:))
        let isAlarm = content.userInfo["isAlarm"] as? Bool ?? false
        let action = response.actionIdentifier
        let category = content.categoryIdentifier
        Task { @MainActor in
            NotificationService.shared.handle(action: action, taskID: taskID, isAlarm: isAlarm, category: category)
            completionHandler()
        }
    }
}
