import SwiftUI

// The add-task dropdowns (Date, Time, List, More) under every quick-add field: the main window's,
// the menu bar's and Quick Capture's. Each chip shows what the task will get: what the typed text
// says, unless that dropdown was used, which wins; whatever is still open comes from the screen
// (the Calendar's day, a list's page, …). The merge is a pure function, so the chips preview
// exactly what Return adds and the rules are unit tested.

// MARK: - Picks

/// One dropdown's state.
enum AddPick<Value: Equatable>: Equatable {
    /// Untouched: the typed text decides, then the screen's default.
    case auto
    /// Picked "No date", "No time", "Inbox", "No estimate" or "No reminder".
    case cleared
    case value(Value)
}

/// A reminder picked in the More menu: minutes before the deadline, as a notification or an alarm.
struct AddReminder: Hashable {
    var minutesBefore: Int
    var isAlarm: Bool
}

/// What the screen around a quick-add field means for a new task.
struct AddContext: Equatable {
    /// The day an undated task is planned for (the Calendar's day, or today in the menu bar). Nil: no date.
    var day: Date?
    /// A list's page adds to that list.
    var listID: UUID?
    /// A tag's page adds that tag.
    var tag: String?
    /// The Important page makes new tasks at least High.
    var minimumPriority: Priority = .none

    init(day: Date? = nil, listID: UUID? = nil, tag: String? = nil, minimumPriority: Priority = .none) {
        self.day = day
        self.listID = listID
        self.tag = tag
        self.minimumPriority = minimumPriority
    }

    /// The defaults of a main-window page. `day` is the Calendar's day; the other pages have none.
    init(selection: SidebarItem, day: Date?) {
        switch selection {
        case .calendar: self.init(day: day)
        case .list(let id): self.init(listID: id)
        case .tag(let tag): self.init(tag: tag)
        case .important: self.init(minimumPriority: .high)
        default: self.init()
        }
    }
}

/// What was picked in the dropdowns. A pick beats the typed text; anything left alone follows the
/// text, then the screen. Reset after each add, so the screen's own defaults (its list, its day) return.
struct AddOptions: Equatable {
    var date: AddPick<Date> = .auto
    /// Minutes after midnight.
    var time: AddPick<Int> = .auto
    /// `.cleared` is the Inbox.
    var list: AddPick<UUID> = .auto
    var estimate: AddPick<Int> = .auto
    /// Nil until picked (Priority has its own "None").
    var priority: Priority?
    var reminder: AddPick<AddReminder> = .auto

    var hasPicks: Bool { self != AddOptions() }

    mutating func reset() { self = AddOptions() }

    /// A day, or nil for "No date", which also lets go of a picked time: nothing is dated any more.
    mutating func pickDate(_ day: Date?, calendar: Calendar = .current) {
        if let day {
            date = .value(calendar.startOfDay(for: day))
        } else {
            date = .cleared
            time = .auto
        }
    }

    /// A time (minutes after midnight), or nil for "No time". A time needs a day, so it undoes "No date":
    /// the typed day, else the screen's day (today outside the Calendar).
    mutating func pickTime(_ minutes: Int?) {
        guard let minutes else {
            time = .cleared
            return
        }
        time = .value(min(max(minutes, 0), 24 * 60 - 1))
        if date == .cleared { date = .auto }
    }

    /// A list, or nil for the Inbox.
    mutating func pickList(_ id: UUID?) {
        list = id.map { .value($0) } ?? .cleared
    }

    /// Minutes, or nil for "No estimate".
    mutating func pickEstimate(_ minutes: Int?) {
        if let minutes, minutes > 0 { estimate = .value(minutes) } else { estimate = .cleared }
    }

    mutating func pickPriority(_ p: Priority) { priority = p }

    /// A reminder, or nil for "No reminder" (which also turns off the default one from Settings).
    mutating func pickReminder(_ r: AddReminder?) {
        reminder = r.map { .value($0) } ?? .cleared
    }
}

// MARK: - The merge

extension AddOptions {
    /// The task a quick add creates from the parsed text: picks first, then the text, then the screen.
    /// Pure, so the chips can preview exactly what Return adds.
    func makeTask(parsed p: ParsedTask, context: AddContext, lists: [TaskList], now: Date = Date(),
                  calendar cal: Calendar = .current,
                  defaultReminder: Int = Prefs.defaultReminder, defaultIsAlarm: Bool = Prefs.defaultReminderIsAlarm) -> TaskItem {
        var t = TaskItem(title: p.title)
        t.recurrence = p.recurrence
        t.tags = p.tags
        if let tag = context.tag?.trimmingCharacters(in: .whitespaces), !tag.isEmpty,
           !t.tags.contains(where: { $0.caseInsensitiveCompare(tag) == .orderedSame }) {
            t.tags.append(tag)
        }

        let when = resolveWhen(parsed: p, context: context, now: now, calendar: cal)
        t.dueDate = when.due
        t.dueHasTime = when.hasTime
        t.scheduledDate = when.planned

        switch list {
        case .auto: t.listID = p.listID ?? context.listID
        case .cleared: t.listID = nil
        case .value(let id): t.listID = id
        }
        // A list deleted since it was picked means the Inbox.
        if let id = t.listID, !lists.contains(where: { $0.id == id }) { t.listID = nil }

        switch estimate {
        case .auto: t.estimateMinutes = p.estimateMinutes
        case .cleared: t.estimateMinutes = nil
        case .value(let minutes): t.estimateMinutes = minutes
        }

        t.priority = priority ?? max(p.priority, context.minimumPriority)

        switch reminder {
        case .value(let r):
            t.reminders = [Reminder(trigger: .beforeDue(minutes: max(0, r.minutesBefore)), isAlarm: r.isAlarm)]
        case .cleared:
            t.reminders = []
        case .auto:
            // As typed ("@alarm10"), else the default from Settings once there's a deadline with a time.
            if !p.reminders.isEmpty {
                t.reminders = p.reminders.map { Reminder(trigger: .beforeDue(minutes: $0.minutesBefore), isAlarm: $0.isAlarm) }
            } else if t.dueHasTime, defaultReminder >= 0 {
                t.reminders = [Reminder(trigger: .beforeDue(minutes: defaultReminder), isAlarm: defaultIsAlarm)]
            }
        }
        return t
    }

    /// The deadline, or (on the Calendar and in the menu bar) the day an undated task is planned for.
    /// Typed and picked dates are deadlines, like everything typed into quick add.
    private func resolveWhen(parsed p: ParsedTask, context: AddContext, now: Date,
                             calendar cal: Calendar) -> (due: Date?, hasTime: Bool, planned: Date?) {
        let today = cal.startOfDay(for: now)
        // The screen's day, never in the past.
        let contextDay = context.day.map { max(cal.startOfDay(for: $0), today) }

        // "No date": no deadline and no plan date either.
        if date == .cleared { return (nil, false, nil) }

        // Nothing picked: exactly what was typed (so "in 2 hours" keeps its minute), else the screen's day.
        if date == .auto, time == .auto {
            if let due = p.dueDate { return (due, p.dueHasTime, nil) }
            return (nil, false, contextDay)
        }

        var day: Date?
        if case .value(let picked) = date {
            day = cal.startOfDay(for: picked)
        } else {
            day = p.dueDate.map { cal.startOfDay(for: $0) }
        }

        var minutes: Int?
        switch time {
        case .value(let m): minutes = m
        case .cleared: minutes = nil
        case .auto: minutes = p.dueHasTime ? p.dueDate.map { Self.minutes(of: $0, calendar: cal) } : nil
        }

        guard let minutes else {
            if let day { return (day, false, nil) }
            return (nil, false, contextDay)
        }
        if let day { return (Self.moment(minutes, on: day, calendar: cal), true, nil) }

        // A time with no day lands on the screen's day (today elsewhere). Once that time has passed,
        // it means the next day, just as typing "3pm" at 4pm does.
        let base = contextDay ?? today
        let due = Self.moment(minutes, on: base, calendar: cal)
        if due < now.addingTimeInterval(-60), let next = cal.date(byAdding: .day, value: 1, to: base) {
            return (Self.moment(minutes, on: next, calendar: cal), true, nil)
        }
        return (due, true, nil)
    }
}

// MARK: - Menu contents and chip labels

extension AddOptions {
    /// A Date menu shortcut and the real day it lands on.
    struct QuickDay: Identifiable, Equatable {
        var label: String
        var day: Date
        var id: String { label }
    }

    /// Today, Tomorrow, This weekend, Next week (Monday) and In a week, as the date picker has them.
    static func quickDays(now: Date = Date(), calendar cal: Calendar = .current) -> [QuickDay] {
        let today = cal.startOfDay(for: now)
        func plus(_ days: Int) -> Date { cal.date(byAdding: .day, value: days, to: today) ?? today }
        let weekday = cal.component(.weekday, from: today) // 1 = Sunday … 7 = Saturday
        return [
            QuickDay(label: "Today", day: today),
            QuickDay(label: "Tomorrow", day: plus(1)),
            // The coming Saturday (today on a Saturday).
            QuickDay(label: "This weekend", day: plus((7 - weekday + 7) % 7)),
            QuickDay(label: "Next week", day: Recurrence(frequency: .weekly, weekdays: [2]).advance(today, calendar: cal)),
            QuickDay(label: "In a week", day: plus(7)),
        ]
    }

    static let timePresets = [9 * 60, 12 * 60, 15 * 60, 18 * 60]
    static let durations = [5, 10, 15, 20, 30, 45, 60, 90, 120, 180, 240]
    /// The same choices as "Add reminder" in the task detail.
    static let reminderOffsets = [0, 5, 10, 15, 30, 60, 120, 1440]

    /// The first of this month and the next `count - 1` months ("Pick a date" in the floating panels).
    static func months(from now: Date = Date(), count: Int = 6, calendar cal: Calendar = .current) -> [Date] {
        guard let first = cal.dateInterval(of: .month, for: now)?.start else { return [] }
        return (0..<count).compactMap { cal.date(byAdding: .month, value: $0, to: first) }
    }

    /// Every day of `month` from today on.
    static func days(inMonthOf month: Date, from now: Date = Date(), calendar cal: Calendar = .current) -> [Date] {
        guard let interval = cal.dateInterval(of: .month, for: month) else { return [] }
        let today = cal.startOfDay(for: now)
        var result: [Date] = []
        var day = interval.start
        while day < interval.end {
            if day >= today { result.append(day) }
            guard let next = cal.date(byAdding: .day, value: 1, to: day) else { break }
            day = next
        }
        return result
    }

    static func minutes(of date: Date, calendar cal: Calendar = .current) -> Int {
        cal.component(.hour, from: date) * 60 + cal.component(.minute, from: date)
    }

    /// `minutes` after midnight on `day`.
    static func moment(_ minutes: Int, on day: Date, calendar cal: Calendar = .current) -> Date {
        cal.date(bySettingHour: minutes / 60, minute: minutes % 60, second: 0, of: day)
            ?? cal.startOfDay(for: day).addingTimeInterval(Double(minutes) * 60)
    }

    /// Where "Custom…" starts when there's no time yet: the next whole hour.
    static func nextWholeHour(after now: Date, calendar cal: Calendar = .current) -> Int {
        min(23, cal.component(.hour, from: now) + 1) * 60
    }

    /// The day the Date chip shows: the deadline's, else the day it's planned for.
    static func day(of t: TaskItem, calendar cal: Calendar = .current) -> Date? {
        (t.dueDate ?? t.scheduledDate).map { cal.startOfDay(for: $0) }
    }

    /// Always the real date ("Mon 5 Oct"), never "Today".
    static func dateLabel(_ t: TaskItem, now: Date = Date(), calendar cal: Calendar = .current) -> String {
        day(of: t, calendar: cal).map { Fmt.absoluteDay($0, now: now, calendar: cal) } ?? "No date"
    }

    static func timeLabel(_ t: TaskItem) -> String {
        guard t.dueHasTime, let due = t.dueDate else { return "No time" }
        return Fmt.time(due)
    }

    /// One part of the More chip's face.
    struct MoreItem: Equatable {
        enum Kind { case duration, priority, reminder }
        var kind: Kind
        var icon: String
        var text: String
    }

    /// What the More chip shows: duration, priority and reminder, when set. Empty: it just says "More".
    static func moreItems(_ t: TaskItem) -> [MoreItem] {
        var items: [MoreItem] = []
        if let minutes = t.estimateMinutes {
            items.append(MoreItem(kind: .duration, icon: "hourglass", text: Fmt.duration(minutes: minutes)))
        }
        if t.priority != .none {
            items.append(MoreItem(kind: .priority, icon: "flag", text: t.priority.label))
        }
        if let text = reminderSummary(t) {
            items.append(MoreItem(kind: .reminder, icon: t.hasAlarm ? "alarm" : "bell", text: text))
        }
        return items
    }

    /// "15m before", "At deadline", "On the day", or "2 reminders".
    static func reminderSummary(_ t: TaskItem) -> String? {
        guard let first = t.reminders.first else { return nil }
        if t.reminders.count > 1 { return "\(t.reminders.count) reminders" }
        switch first.trigger {
        case .absolute(let date):
            return Fmt.dateTime(date)
        case .beforeDue(let minutes):
            if minutes == 0 { return t.dueDate != nil && !t.dueHasTime ? "On the day" : "At deadline" }
            return "\(Fmt.duration(minutes: minutes)) before"
        }
    }

    /// The reminder the More menu checks: the task's only one, when it counts from the deadline.
    static func currentReminder(_ t: TaskItem) -> AddReminder? {
        guard t.reminders.count == 1, let r = t.reminders.first, case .beforeDue(let minutes) = r.trigger else { return nil }
        return AddReminder(minutesBefore: minutes, isAlarm: r.isAlarm)
    }
}

// MARK: - The chip row

/// The hand pickers a chip can open in a popover (main window only).
enum AddPicker: Hashable { case date, time }

/// The Date, Time, List and More dropdowns under a quick-add field, each showing what the task will get,
/// followed by what has no chip of its own (tags, repeat).
struct AddOptionsBar: View {
    enum Arrangement {
        /// Wraps onto a second line when narrow (main window, menu bar).
        case wrap
        /// One line; tags and the hint drop out when there's no room (Quick Capture's fixed-size panel).
        case oneLine
    }

    @Binding var options: AddOptions
    let parsed: ParsedTask
    let context: AddContext
    let lists: [TaskList]
    let now: Date
    /// Docket's floating panels close as soon as they lose focus, which a popover would take, so there
    /// "Pick a date" and the custom time are submenus instead.
    let usesPopovers: Bool
    let arrangement: Arrangement
    /// Quiet text after the chips while nothing else is shown.
    let hint: String?
    @Binding var picker: AddPicker?
    /// After every pick, so the field can take the cursor back.
    let onPick: () -> Void
    /// Whether a chip has keyboard focus (Full Keyboard Access), so the row isn't hidden from under it.
    let onFocusChange: (Bool) -> Void

    private enum ChipSlot: Hashable { case date, time, list, more }
    @FocusState private var focusedChip: ChipSlot?

    init(options: Binding<AddOptions>, parsed: ParsedTask, context: AddContext, lists: [TaskList], now: Date = Date(),
         usesPopovers: Bool = true, arrangement: Arrangement = .wrap, hint: String? = nil,
         picker: Binding<AddPicker?> = .constant(nil), onPick: @escaping () -> Void = {},
         onFocusChange: @escaping (Bool) -> Void = { _ in }) {
        _options = options
        self.parsed = parsed
        self.context = context
        self.lists = lists
        self.now = now
        self.usesPopovers = usesPopovers
        self.arrangement = arrangement
        self.hint = hint
        _picker = picker
        self.onPick = onPick
        self.onFocusChange = onFocusChange
    }

    var body: some View {
        let task = options.makeTask(parsed: parsed, context: context, lists: lists, now: now)
        Group {
            switch arrangement {
            case .wrap:
                FlowLayout(spacing: 6, lineSpacing: 6) {
                    chips(task)
                    trailing(task)
                }
            case .oneLine:
                HStack(spacing: 6) {
                    chips(task)
                    // All or nothing: half a tag row would read as clutter.
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 6) { trailing(task) }
                        Color.clear.frame(width: 0, height: 0)
                    }
                    .layoutPriority(-1)
                    Spacer(minLength: 0)
                }
            }
        }
        .onChange(of: focusedChip) { onFocusChange($0 != nil) }
        .onChange(of: picker) { if $0 == nil { onPick() } }
    }

    @ViewBuilder
    private func chips(_ t: TaskItem) -> some View {
        dateChip(t)
        timeChip(t)
        listChip(t)
        moreChip(t)
    }

    /// Tags and repeat, which have no chip, or the hint when there's nothing to show.
    @ViewBuilder
    private func trailing(_ t: TaskItem) -> some View {
        if t.tags.isEmpty && t.recurrence == nil {
            if let hint {
                Text(hint)
                    .textStyle(.subhead)
                    .foregroundStyle(Color.ink3)
                    .lineLimit(1)
                    .fixedSize()
                    .frame(height: 26)
                    .padding(.leading, 4)
            }
        } else {
            ForEach(t.tags, id: \.self) { tag in
                Chip(icon: "number", text: tag)
                    .fixedSize()
                    .frame(height: 26)
            }
            if let rule = t.recurrence {
                Chip(icon: "repeat", text: rule.summary)
                    .fixedSize()
                    .frame(height: 26)
            }
        }
    }

    // MARK: Date

    private func dateChip(_ t: TaskItem) -> some View {
        let day = AddOptions.day(of: t)
        let picks = AddOptions.quickDays(now: now)
        return Menu {
            ForEach(picks) { pick in
                checkItem("\(pick.label) · \(Fmt.absoluteDay(pick.day, now: now))", on: day == pick.day) {
                    options.pickDate(pick.day)
                    onPick()
                }
            }
            // A typed or picked day that isn't a shortcut still gets its tick.
            if let day, !picks.contains(where: { $0.day == day }) {
                checkItem(Fmt.absoluteDay(day, now: now), on: true) {}
            }
            Divider()
            if usesPopovers {
                Button("Pick a date…") { picker = .date }
            } else {
                daySubmenu
            }
            Divider()
            checkItem("No date", on: day == nil) {
                options.pickDate(nil)
                onPick()
            }
        } label: {
            ChipFace(icon: "calendar", text: day.map { Fmt.absoluteDay($0, now: now) } ?? "No date", active: t.dueDate != nil)
        }
        .menuChrome(Capsule())
        .focused($focusedChip, equals: .date)
        .popover(isPresented: pickerShown(.date), arrowEdge: .bottom) {
            DatePopover(date: Binding(get: { day }, set: { options.pickDate($0) }), hasTime: .constant(false),
                        allowsTime: false, title: "Date", close: { picker = nil })
        }
        .help(dateHelp(t))
    }

    private func dateHelp(_ t: TaskItem) -> String {
        if t.dueDate == nil, t.scheduledDate != nil { return "Planned for this day. Pick a date, or type one like “fri” or “dec 3”" }
        return "Pick a date, or type one like “fri” or “dec 3”"
    }

    /// Floating panels: every day of the next six months, by month.
    private var daySubmenu: some View {
        Menu("Pick a date") {
            ForEach(AddOptions.months(from: now), id: \.self) { month in
                Menu(Self.monthFormatter.string(from: month)) {
                    ForEach(AddOptions.days(inMonthOf: month, from: now), id: \.self) { day in
                        Button(Fmt.absoluteDay(day, now: now)) {
                            options.pickDate(day)
                            onPick()
                        }
                    }
                }
            }
        }
    }

    private static let monthFormatter: DateFormatter = {
        let f = DateFormatter()
        f.setLocalizedDateFormatFromTemplate("MMMM yyyy")
        return f
    }()

    // MARK: Time

    private func timeChip(_ t: TaskItem) -> some View {
        let minutes = t.dueHasTime ? t.dueDate.map { AddOptions.minutes(of: $0) } : nil
        let today = Calendar.current.startOfDay(for: now)
        // A typed time that isn't a preset shows in the list too, ticked.
        let choices = Array(Set(AddOptions.timePresets + (minutes.map { [$0] } ?? []))).sorted()
        return Menu {
            checkItem("No time", on: minutes == nil) {
                options.pickTime(nil)
                onPick()
            }
            Divider()
            ForEach(choices, id: \.self) { m in
                checkItem(Fmt.time(AddOptions.moment(m, on: today)), on: minutes == m) {
                    options.pickTime(m)
                    onPick()
                }
            }
            Divider()
            if usesPopovers {
                Button("Custom…") { picker = .time }
            } else {
                timeSubmenu(today: today)
            }
        } label: {
            ChipFace(icon: "clock", text: AddOptions.timeLabel(t), active: minutes != nil)
        }
        .menuChrome(Capsule())
        .focused($focusedChip, equals: .time)
        .popover(isPresented: pickerShown(.time), arrowEdge: .bottom) {
            AddTimePopover(minutes: minutes ?? AddOptions.nextWholeHour(after: now),
                           onSet: { options.pickTime($0) }, close: { picker = nil })
        }
        .help("Pick a time, or type one like “3pm” or “10:30”")
    }

    /// Floating panels: any quarter hour, by hour.
    private func timeSubmenu(today: Date) -> some View {
        Menu("Custom") {
            ForEach(0..<24, id: \.self) { hour in
                Menu(Fmt.uses12Hour ? Fmt.hourLabel(hour) : String(format: "%02d:00", hour)) {
                    ForEach([0, 15, 30, 45], id: \.self) { minute in
                        Button(Fmt.time(AddOptions.moment(hour * 60 + minute, on: today))) {
                            options.pickTime(hour * 60 + minute)
                            onPick()
                        }
                    }
                }
            }
        }
    }

    // MARK: List

    private func listChip(_ t: TaskItem) -> some View {
        let list = lists.first { $0.id == t.listID }
        return Menu {
            checkItem("Inbox", icon: "tray", on: list == nil) {
                options.pickList(nil)
                onPick()
            }
            if !lists.isEmpty { Divider() }
            ForEach(lists) { l in
                checkItem(l.name, icon: l.icon, on: l.id == list?.id) {
                    options.pickList(l.id)
                    onPick()
                }
            }
        } label: {
            ChipFace(icon: list?.icon ?? "tray", text: list?.name ?? "Inbox",
                     active: options.list != .auto || parsed.listID != nil, maxTextWidth: 140)
        }
        .menuChrome(Capsule())
        .focused($focusedChip, equals: .list)
        .help("Pick a list, or type # and its name")
    }

    // MARK: More (duration, priority, reminder)

    private func moreChip(_ t: TaskItem) -> some View {
        let items = AddOptions.moreItems(t)
        let reminderNeedsDate = !t.reminders.isEmpty && t.dueDate == nil
        return Menu {
            Menu {
                durationItems(t)
            } label: {
                Label(t.estimateMinutes.map { "Duration · \(Fmt.duration(minutes: $0))" } ?? "Duration", systemImage: "hourglass")
            }
            Menu {
                ForEach(Priority.allCases.reversed()) { p in
                    checkItem(p.label, on: t.priority == p) {
                        options.pickPriority(p)
                        onPick()
                    }
                }
            } label: {
                Label(t.priority == .none ? "Priority" : "Priority · \(t.priority.label)", systemImage: "flag")
            }
            Menu {
                reminderItems(t)
            } label: {
                Label(AddOptions.reminderSummary(t).map { "Reminder · \($0)" } ?? "Reminder", systemImage: t.hasAlarm ? "alarm" : "bell")
            }
        } label: {
            MoreFace(items: items, priority: t.priority, reminderNeedsDate: reminderNeedsDate)
        }
        .menuChrome(Capsule())
        .focused($focusedChip, equals: .more)
        .help(reminderNeedsDate
              ? "The reminder needs a date and time to ring. Pick them, or type “fri 3pm”"
              : "Duration, priority and reminder. Or type “45m”, “!!” or “@alarm10”")
    }

    @ViewBuilder
    private func durationItems(_ t: TaskItem) -> some View {
        checkItem("No estimate", on: t.estimateMinutes == nil) {
            options.pickEstimate(nil)
            onPick()
        }
        Divider()
        let choices = Array(Set(AddOptions.durations + (t.estimateMinutes.map { [$0] } ?? []))).sorted()
        ForEach(choices, id: \.self) { m in
            checkItem(Fmt.duration(minutes: m), on: t.estimateMinutes == m) {
                options.pickEstimate(m)
                onPick()
            }
        }
    }

    @ViewBuilder
    private func reminderItems(_ t: TaskItem) -> some View {
        let current = AddOptions.currentReminder(t)
        checkItem("No reminder", on: t.reminders.isEmpty) {
            options.pickReminder(nil)
            onPick()
        }
        Section("Notification") {
            ForEach(AddOptions.reminderOffsets, id: \.self) { m in
                reminderItem(m, alarm: false, t, current)
            }
        }
        Section("Alarm") {
            ForEach(AddOptions.reminderOffsets, id: \.self) { m in
                reminderItem(m, alarm: true, t, current)
            }
        }
    }

    private func reminderItem(_ minutes: Int, alarm: Bool, _ t: TaskItem, _ current: AddReminder?) -> some View {
        let r = AddReminder(minutesBefore: minutes, isAlarm: alarm)
        let title: String
        if minutes == 0 {
            title = t.dueDate != nil && !t.dueHasTime
                ? "On the day (\(Fmt.time(AddOptions.moment(Prefs.allDayHour * 60, on: now))))"
                : "At the deadline"
        } else {
            title = "\(Fmt.duration(minutes: minutes)) before"
        }
        return checkItem(title, on: current == r) {
            options.pickReminder(r)
            onPick()
        }
    }

    // MARK: Helpers

    /// A menu item ticked when it's the current value. Choosing the ticked one again changes nothing.
    private func checkItem(_ title: String, icon: String? = nil, on: Bool, _ action: @escaping () -> Void) -> some View {
        Toggle(isOn: Binding(get: { on }, set: { if $0 { action() } })) {
            if let icon {
                Label(title, systemImage: icon)
            } else {
                Text(title)
            }
        }
    }

    private func pickerShown(_ p: AddPicker) -> Binding<Bool> {
        Binding(get: { usesPopovers && picker == p }, set: { shown in
            if !shown, picker == p { picker = nil }
        })
    }
}

/// A dropdown chip's face: icon, value and a small chevron on a 26pt capsule edged with a hairline.
/// Quiet (ink2) while it shows a default; ink once it holds something typed or picked.
private struct ChipFace: View {
    var icon: String?
    var text: String
    var active: Bool
    var maxTextWidth: CGFloat = 160

    var body: some View {
        HStack(spacing: 4) {
            if let icon {
                Image(systemName: icon).font(.system(size: 10.5, weight: .semibold))
            }
            Text(text)
                .lineLimit(1)
                .frame(maxWidth: maxTextWidth)
            ChipChevron()
        }
        .chipFace(active: active)
    }
}

/// The More chip: "More" until something is set, then each value with its icon ("45m", "High", "15m before").
private struct MoreFace: View {
    var items: [AddOptions.MoreItem]
    var priority: Priority
    /// A reminder with nothing to count from shows in the danger colour.
    var reminderNeedsDate: Bool

    var body: some View {
        HStack(spacing: 4) {
            if items.isEmpty {
                Text("More")
            }
            ForEach(Array(items.enumerated()), id: \.offset) { i, item in
                HStack(spacing: 3) {
                    Image(systemName: item.icon).font(.system(size: 10, weight: .semibold))
                    Text(item.text).lineLimit(1)
                }
                .foregroundStyle(tint(item))
                .padding(.leading, i == 0 ? 0 : 4)
            }
            ChipChevron()
        }
        .chipFace(active: !items.isEmpty)
    }

    private func tint(_ item: AddOptions.MoreItem) -> Color {
        switch item.kind {
        case .priority: priority.tone?.fg ?? .ink
        case .reminder: reminderNeedsDate ? .dangerText : .ink
        case .duration: .ink
        }
    }
}

private struct ChipChevron: View {
    var body: some View {
        Image(systemName: "chevron.down")
            .font(.system(size: 7.5, weight: .heavy))
            .foregroundStyle(Color.ink3)
            .padding(.leading, 1)
    }
}

extension View {
    /// Badge-like body of an add-option chip (the Menu's capsule fill sits behind it).
    fileprivate func chipFace(active: Bool) -> some View {
        font(.system(size: 12, weight: .semibold))
            .monospacedDigit()
            .foregroundStyle(active ? Color.ink : Color.ink2)
            .padding(.horizontal, 9)
            .frame(height: 26)
            .overlay(Capsule().strokeBorder(Color.hair, lineWidth: 1))
            .contentShape(Capsule())
    }
}

/// "Custom…" in the Time menu: hour and minute pills, then Set.
struct AddTimePopover: View {
    @State private var minutes: Int
    let onSet: (Int) -> Void
    let close: () -> Void

    init(minutes: Int, onSet: @escaping (Int) -> Void, close: @escaping () -> Void) {
        _minutes = State(initialValue: minutes)
        self.onSet = onSet
        self.close = close
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Space.md) {
            Text("Time")
                .font(.system(size: 17, weight: .bold))
                .tracking(-0.2)
                .foregroundStyle(Color.ink)
            TimeOfDayPicker(minutes: $minutes)
            HStack {
                Spacer(minLength: 0)
                Button("Set time") {
                    onSet(minutes)
                    close()
                }
                .buttonStyle(PrimaryPill(height: 32))
                .keyboardShortcut(.defaultAction)
                .help("Use this time (Return)")
            }
        }
        .padding(Space.lg)
        .frame(width: 240)
        .background(Color.raised)
        .tint(Color.ink)
    }
}
