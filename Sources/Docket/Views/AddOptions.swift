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
    /// Two can land on the same day (on a Sunday, next week starts tomorrow); the menu keeps both, so
    /// the items never move around, and ticks only the first (see `tickedQuickDay`).
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

    /// The one shortcut the Date menu ticks for `day`: the first that lands on it.
    static func tickedQuickDay(_ day: Date?, in picks: [QuickDay]) -> QuickDay? {
        guard let day else { return nil }
        return picks.first { $0.day == day }
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

    /// The narrow chip's real date: "5 Oct", or "5 Oct 2027" outside this year. Never "Today".
    static func shortDateLabel(_ day: Date, now: Date = Date(), calendar cal: Calendar = .current) -> String {
        cal.isDate(day, equalTo: now, toGranularity: .year) ? Fmt.dayMonth(day) : shortDayYearFormatter.string(from: day)
    }

    private static let shortDayYearFormatter: DateFormatter = {
        let f = DateFormatter()
        f.setLocalizedDateFormatFromTemplate("d MMM y")
        return f
    }()

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

    /// What quick add understood that has no dropdown of its own: the repeat rule, then the tags.
    static func extras(_ t: TaskItem) -> [AddExtra] {
        (t.recurrence.map { [AddExtra(icon: "repeat", text: $0.summary)] } ?? [])
            + t.tags.map { AddExtra(icon: "number", text: $0) }
    }
}

/// A repeat rule or a tag, shown as a quiet chip after (or under) the dropdowns.
struct AddExtra: Hashable {
    var icon: String
    var text: String
    /// "#board" or "Every week", for the "+2" chip's tooltip.
    var spoken: String { icon == "number" ? "#\(text)" : text }
}

// MARK: - Chip density

/// How compact the dropdown chips draw. Each step gives up the least useful thing still on show, so the
/// chips stay on one line from Quick Capture (592pt) down to the narrowest list pane (312pt of field).
/// Tooltips always carry the whole value.
struct AddChipDensity: Hashable, Comparable {
    let level: Int

    static let full = AddChipDensity(level: 0)
    /// Fullest first.
    static let all = (0...6).map { AddChipDensity(level: $0) }

    /// "No date" and "No time" become bare icons; More shows priority and reminder as icons ("⧗ 30m ⚑ 🔔").
    var terse: Bool { level >= 1 }
    /// The date, time and list drop their leading icons.
    var plainValues: Bool { level >= 2 }
    /// A list nobody chose (the page's, or the Inbox) is just its icon.
    var quietList: Bool { level >= 3 }
    var chevrons: Bool { level < 4 }
    /// "5 Oct" and "10a" instead of "Mon 5 Oct" and "10:00 AM"; a chosen list's name is cut shorter.
    var short: Bool { level >= 5 }
    /// More keeps only the duration and a High or Urgent flag (or one icon), and every list is just its icon.
    var minimal: Bool { level >= 6 }

    /// The measuring copy's id when repeat and tags ride along (`.oneLine`), distinct from `level`.
    var withExtrasID: String { "extras-\(level)" }

    static func < (a: AddChipDensity, b: AddChipDensity) -> Bool { a.level < b.level }
}

private struct AddChipDensityKey: PreferenceKey {
    static let defaultValue = 0
    static func reduce(value: inout Int, nextValue: () -> Int) { value = max(value, nextValue()) }
}

// MARK: - The chip row

/// The hand pickers a chip can open in a popover (main window only).
enum AddPicker: Hashable { case date, time }

/// The Date, Time, List and More dropdowns under a quick-add field, each showing what the task will get,
/// then what has no dropdown of its own (repeat, tags). The chips never wrap: an invisible copy of their
/// labels, laid out at every `AddChipDensity` by ViewThatFits, finds the fullest one that fits the width.
struct AddOptionsBar: View {
    enum Arrangement {
        /// Repeat and tags get a line of their own under the chips (main window, menu bar).
        case stacked
        /// One line: repeat and tags follow the chips and fold into "+2" when short of room, and the
        /// hint shows while there's nothing to list (Quick Capture's fixed-size panel).
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
    /// Quiet text after the chips while nothing else is shown (`.oneLine` only).
    let hint: String?
    @Binding var picker: AddPicker?
    /// After every pick, so the field can take the cursor back.
    let onPick: () -> Void
    /// Whether a chip has keyboard focus (Full Keyboard Access), so the row isn't hidden from under it.
    let onFocusChange: (Bool) -> Void

    private enum ChipSlot: Hashable { case date, time, list, more }
    @FocusState private var focusedChip: ChipSlot?
    @State private var density = AddChipDensity.full

    init(options: Binding<AddOptions>, parsed: ParsedTask, context: AddContext, lists: [TaskList], now: Date = Date(),
         usesPopovers: Bool = true, arrangement: Arrangement = .stacked, hint: String? = nil,
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
        let extras = AddOptions.extras(task)
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                dateChip(task)
                timeChip(task)
                listChip(task)
                moreChip(task)
                if arrangement == .oneLine {
                    AddExtrasLine(items: extras, hint: hint)
                        .layoutPriority(-1)
                }
            }
            // Exactly the width on offer, never the chips' own: with only a maximum, a row of chips wider
            // than the space would widen the frame, and the measuring copy would think they fit.
            .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
            .background(alignment: .leading) { densityProbe(task, extras: extras) }

            if arrangement == .stacked, !extras.isEmpty {
                AddExtrasLine(items: extras, hint: nil)
                    .transition(.opacity)
            }
        }
        .onPreferenceChange(AddChipDensityKey.self) { density = AddChipDensity(level: $0) }
        .onChange(of: focusedChip) { onFocusChange($0 != nil) }
        .onChange(of: picker) { if $0 == nil { onPick() } }
    }

    /// The chip labels alone (no menus), at every density, fullest first. ViewThatFits keeps the first
    /// copy that fits, and only that copy reports its density, which the real chips then draw at.
    /// (ViewThatFits needs every candidate's id to be unique, hence the two id schemes.)
    private func densityProbe(_ t: TaskItem, extras: [AddExtra]) -> some View {
        ViewThatFits(in: .horizontal) {
            // On one line, give up the More chip's words before folding repeat and tags into "+2".
            if arrangement == .oneLine, !extras.isEmpty {
                ForEach(AddChipDensity.all.prefix(2), id: \.withExtrasID) { d in
                    HStack(spacing: 6) {
                        labels(t, d)
                        AddExtrasLine.chips(extras)
                    }
                    .preference(key: AddChipDensityKey.self, value: d.level)
                }
            }
            ForEach(AddChipDensity.all, id: \.level) { d in
                HStack(spacing: 6) { labels(t, d) }
                    .preference(key: AddChipDensityKey.self, value: d.level)
            }
        }
        .hidden()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    @ViewBuilder
    func labels(_ t: TaskItem, _ d: AddChipDensity) -> some View {
        dateFace(t, d)
        timeFace(t, d)
        listFace(t, d)
        moreFace(t, d)
    }

    // MARK: Faces (shared by the chips and the invisible copy that measures them)

    func dateFace(_ t: TaskItem, _ d: AddChipDensity) -> AddChipFace {
        guard let day = AddOptions.day(of: t) else {
            return AddChipFace(icon: "calendar", text: d.terse ? nil : "No date", active: false, chevron: d.chevrons)
        }
        let text = d.short ? AddOptions.shortDateLabel(day, now: now) : Fmt.absoluteDay(day, now: now)
        return AddChipFace(icon: d.plainValues ? nil : "calendar", text: text, active: t.dueDate != nil, chevron: d.chevrons)
    }

    func timeFace(_ t: TaskItem, _ d: AddChipDensity) -> AddChipFace {
        guard t.dueHasTime, let due = t.dueDate else {
            return AddChipFace(icon: "clock", text: d.terse ? nil : "No time", active: false, chevron: d.chevrons)
        }
        return AddChipFace(icon: d.plainValues ? nil : "clock", text: d.short ? Fmt.compactTime(due) : Fmt.time(due),
                           active: true, chevron: d.chevrons)
    }

    func listFace(_ t: TaskItem, _ d: AddChipDensity) -> AddChipFace {
        let list = lists.first { $0.id == t.listID }
        let icon = list?.icon ?? "tray"
        let chosen = listChosen
        if d.minimal || (d.quietList && !chosen) {
            return AddChipFace(icon: icon, text: nil, active: chosen, chevron: d.chevrons)
        }
        return AddChipFace(icon: d.plainValues ? nil : icon, text: list?.name ?? "Inbox", active: chosen, chevron: d.chevrons,
                           maxTextWidth: d.short ? 80 : 140)
    }

    func moreFace(_ t: TaskItem, _ d: AddChipDensity) -> AddMoreFace {
        AddMoreFace(items: AddOptions.moreItems(t), priority: t.priority, reminderNeedsDate: reminderNeedsDate(t), density: d)
    }

    /// Typed ("#board") or picked, rather than the page's list or the Inbox by default.
    private var listChosen: Bool { options.list != .auto || parsed.listID != nil }

    private func reminderNeedsDate(_ t: TaskItem) -> Bool { !t.reminders.isEmpty && t.dueDate == nil }

    // MARK: Date

    private func dateChip(_ t: TaskItem) -> some View {
        let day = AddOptions.day(of: t)
        let picks = AddOptions.quickDays(now: now)
        let ticked = AddOptions.tickedQuickDay(day, in: picks)
        return Menu {
            ForEach(picks) { pick in
                checkItem("\(pick.label) · \(Fmt.absoluteDay(pick.day, now: now))", on: pick == ticked) {
                    options.pickDate(pick.day)
                    onPick()
                }
            }
            // A typed or picked day that isn't a shortcut still gets its tick.
            if let day, ticked == nil {
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
            dateFace(t, density)
        }
        .menuChrome(Capsule())
        .focused($focusedChip, equals: .date)
        .popover(isPresented: pickerShown(.date), arrowEdge: .bottom) {
            DatePopover(date: Binding(get: { day }, set: { options.pickDate($0) }), hasTime: .constant(false),
                        allowsTime: false, title: "Date", close: { picker = nil })
        }
        .help(dateHelp(t))
        .accessibilityLabel("Date")
        .accessibilityValue(day.map { Fmt.absoluteDay($0, now: now) } ?? "No date")
    }

    /// Leads with the whole value, which a narrow chip may shorten.
    private func dateHelp(_ t: TaskItem) -> String {
        let how = "Pick a date, or type one like “fri” or “dec 3”"
        guard let day = AddOptions.day(of: t) else { return "No date. \(how)" }
        let value = Fmt.absoluteDay(day, now: now)
        return t.dueDate == nil ? "Planned for \(value). \(how)" : "Due \(value). \(how)"
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
            timeFace(t, density)
        }
        .menuChrome(Capsule())
        .focused($focusedChip, equals: .time)
        .popover(isPresented: pickerShown(.time), arrowEdge: .bottom) {
            AddTimePopover(minutes: minutes ?? AddOptions.nextWholeHour(after: now),
                           onSet: { options.pickTime($0) }, close: { picker = nil })
        }
        .help("\(AddOptions.timeLabel(t)). Pick a time, or type one like “3pm” or “10:30”")
        .accessibilityLabel("Time")
        .accessibilityValue(AddOptions.timeLabel(t))
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
        let name = list?.name ?? "Inbox"
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
            listFace(t, density)
        }
        .menuChrome(Capsule())
        .focused($focusedChip, equals: .list)
        .help("\(name). Pick a list, or type # and its name")
        .accessibilityLabel("List")
        .accessibilityValue(name)
    }

    // MARK: More (duration, priority, reminder)

    private func moreChip(_ t: TaskItem) -> some View {
        let summary = AddOptions.moreItems(t).map(\.text).joined(separator: " · ")
        let how = reminderNeedsDate(t)
            ? "The reminder needs a date to ring. Pick one, or type “fri 3pm”"
            : "Duration, priority and reminder. Or type “45m”, “!!” or “@alarm10”"
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
            moreFace(t, density)
        }
        .menuChrome(Capsule())
        .focused($focusedChip, equals: .more)
        .help(summary.isEmpty ? how : "\(summary). \(how)")
        .accessibilityLabel("More options")
        .accessibilityValue(summary.isEmpty ? "None" : summary)
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
        if t.dueDate == nil {
            // A disabled line: reminders count back from the deadline.
            Text("Needs a date to ring")
        }
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

// MARK: - Chip faces

/// A dropdown chip's face: icon and/or value and a small chevron on a 26pt capsule edged with a hairline.
/// Quiet (ink2) while it shows a default; ink once it holds something typed or picked.
struct AddChipFace: View {
    var icon: String?
    var text: String?
    var active: Bool
    var chevron = true
    var maxTextWidth: CGFloat = 160

    var body: some View {
        HStack(spacing: 4) {
            if let icon {
                Image(systemName: icon).font(.system(size: 10.5, weight: .semibold))
            }
            if let text {
                Text(text)
                    .lineLimit(1)
                    .frame(maxWidth: maxTextWidth)
            }
            if chevron { AddChipChevron() }
        }
        .addChipBody(active: active)
    }
}

/// The More chip: "More" until something is set, then each value with its icon ("45m", "High",
/// "15m before"); narrower, priority and reminder keep only their icons.
struct AddMoreFace: View {
    var items: [AddOptions.MoreItem]
    var priority: Priority
    /// A reminder with nothing to count from shows in the danger colour.
    var reminderNeedsDate: Bool
    var density: AddChipDensity

    var body: some View {
        // Narrowest: the duration and a High or Urgent flag (else whichever comes first).
        let kept = items.filter { $0.kind == .duration || ($0.kind == .priority && priority >= .high) }
        let shown = density.minimal ? (kept.isEmpty ? Array(items.prefix(1)) : kept) : items
        HStack(spacing: 4) {
            if shown.isEmpty {
                if density.minimal {
                    Image(systemName: "ellipsis").font(.system(size: 10.5, weight: .bold))
                } else {
                    Text("More")
                }
            }
            ForEach(Array(shown.enumerated()), id: \.offset) { i, item in
                let words = item.kind == .duration || !density.terse
                HStack(spacing: 3) {
                    if !(density.minimal && words) {
                        Image(systemName: item.icon).font(.system(size: 10, weight: .semibold))
                    }
                    if words {
                        Text(item.text).lineLimit(1)
                    }
                }
                .foregroundStyle(tint(item))
                .padding(.leading, i == 0 ? 0 : (density.terse ? 1 : 4))
            }
            if density.chevrons { AddChipChevron() }
        }
        .addChipBody(active: !items.isEmpty)
    }

    private func tint(_ item: AddOptions.MoreItem) -> Color {
        switch item.kind {
        case .priority: priority.tone?.fg ?? .ink
        case .reminder: reminderNeedsDate ? .dangerText : .ink
        case .duration: .ink
        }
    }
}

private struct AddChipChevron: View {
    var body: some View {
        Image(systemName: "chevron.down")
            .font(.system(size: 7.5, weight: .heavy))
            .foregroundStyle(Color.ink3)
            .padding(.leading, 1)
    }
}

extension View {
    /// Badge-like body of an add-option chip (the Menu's capsule fill sits behind it).
    fileprivate func addChipBody(active: Bool) -> some View {
        font(.system(size: 12, weight: .semibold))
            .monospacedDigit()
            .foregroundStyle(active ? Color.ink : Color.ink2)
            .padding(.horizontal, 9)
            .frame(height: 26)
            .overlay(Capsule().strokeBorder(Color.hair, lineWidth: 1))
            .contentShape(Capsule())
    }
}

/// Repeat and tags as quiet chips on one line. Whatever doesn't fit folds into a "+2" chip (its tooltip
/// lists them); with nothing to list it shows the hint, if there's room for all of it.
struct AddExtrasLine: View {
    let items: [AddExtra]
    let hint: String?

    var body: some View {
        ViewThatFits(in: .horizontal) {
            if items.isEmpty {
                if let hint {
                    Text(hint)
                        .textStyle(.subhead)
                        .foregroundStyle(Color.ink3)
                        .lineLimit(1)
                        .fixedSize()
                        .padding(.leading, 4)
                }
            } else {
                ForEach((0...items.count).reversed(), id: \.self) { shown in
                    HStack(spacing: 6) {
                        Self.chips(Array(items.prefix(shown)))
                        if shown < items.count {
                            Chip(text: "+\(items.count - shown)")
                                .fixedSize()
                                .help(items.dropFirst(shown).map(\.spoken).joined(separator: ", "))
                        }
                    }
                }
            }
            Color.clear.frame(width: 0, height: 0)
        }
    }

    /// Long tags are cut short rather than pushing the line wider. (Fixed size outside the frame, so a
    /// short chip keeps its own width instead of growing to the maximum.)
    static func chips(_ items: [AddExtra]) -> some View {
        ForEach(items, id: \.self) { item in
            Chip(icon: item.icon, text: item.text)
                .frame(maxWidth: 180)
                .fixedSize(horizontal: true, vertical: false)
        }
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
