import SwiftUI

/// The calendar: every dated task in one list in date order (overdue first), each line showing its
/// date, time and how long it takes; or the whole month at a glance.
struct CalendarView: View {
    @EnvironmentObject var store: Store
    @EnvironmentObject var app: AppState
    @EnvironmentObject var calendar: CalendarService

    var body: some View {
        VStack(spacing: 0) {
            header
            OverdueRollover()
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, Space.gutter)
                .padding(.bottom, Space.sm)
            if app.calendarMode == .agenda {
                QuickAddField(day: Date())
                    .padding(.horizontal, Space.gutter)
                    .padding(.bottom, Space.sm)
                AgendaList()
                    .transition(.opacity)
            } else {
                MonthGrid()
                    .transition(.opacity)
            }
        }
        .background(Color.paper)
        .animation(Motion.base, value: app.calendarMode)
        .onAppear(perform: loadEvents)
        .onChange(of: app.selectedDay) { _ in loadEvents() }
    }

    @ViewBuilder
    private var header: some View {
        let cal = Calendar.current
        let today = cal.startOfDay(for: app.clock)
        if app.calendarMode == .agenda {
            let entries = store.timeline(keeping: [], now: app.clock)
            let open = entries.compactMap(\.item.task).filter { !$0.isCompleted }
            let overdue = entries.filter { $0.day == nil }.count
            let minutes = open.reduce(0) { $0 + $1.remainingMinutes }
            let subtitle = [Fmt.longDay(today), Fmt.plural(open.count, "task"), minutes > 0 ? Fmt.duration(minutes: minutes) : nil,
                            overdue > 0 ? "\(overdue) overdue" : nil].compactMap { $0 }.joined(separator: " · ")
            PageHeader(title: "Calendar", subtitle: subtitle) {
                HStack(spacing: Space.sm) {
                    OrderMyDayButton()
                    CompactRowsToggle()
                    SegmentedControl(selection: $app.calendarMode, options: [(.agenda, "List"), (.month, "Month")])
                }
            }
        } else {
            let month = DateFormatter()
            let _ = month.setLocalizedDateFormatFromTemplate("MMMM")
            PageHeader(title: month.string(from: app.selectedDay), titleSecondary: "\(cal.component(.year, from: app.selectedDay))",
                       subtitle: Fmt.longDay(today)) {
                HStack(spacing: Space.sm) {
                    SegmentedControl(selection: $app.calendarMode, options: [(.agenda, "List"), (.month, "Month")])
                    Button { step(-1) } label: { Image(systemName: "chevron.left") }
                        .buttonStyle(IconButtonStyle(filled: true))
                        .help("Previous month")
                    Button("This month") {
                        withAnimation(Motion.snappy) { app.selectedDay = today }
                    }
                    .buttonStyle(SecondaryPill(height: 32))
                    Button { step(1) } label: { Image(systemName: "chevron.right") }
                        .buttonStyle(IconButtonStyle(filled: true))
                        .help("Next month")
                }
            }
        }
    }

    private func step(_ direction: Int) {
        let next = Calendar.current.date(byAdding: .month, value: direction, to: app.selectedDay)!
        withAnimation(Motion.snappy) { app.selectedDay = Calendar.current.startOfDay(for: next) }
    }

    private func loadEvents() {
        guard Prefs.useCalendar else { return }
        let cal = Calendar.current
        let start = cal.date(byAdding: .day, value: -42, to: app.selectedDay)!
        let end = cal.date(byAdding: .day, value: 49, to: app.selectedDay)!
        calendar.ensure(from: start, to: end)
    }
}

/// Reschedules dragged tasks (payload: task id strings) onto a day.
@MainActor
func dropTasks(_ items: [String], on day: Date, store: Store, app: AppState) -> Bool {
    let ids = items.compactMap(UUID.init(uuidString:))
    app.draggingTaskID = nil
    guard !ids.isEmpty else { return false }
    withAnimation(Motion.gentle) {
        for id in ids { store.move(id, toDay: day) }
    }
    Haptics.success()
    app.showToast("Moved to \(Fmt.absoluteDay(day))")
    return true
}

// MARK: - List

/// Every dated task in date order. No day headings: each line carries its own date.
struct AgendaList: View {
    @EnvironmentObject var store: Store
    @EnvironmentObject var app: AppState
    @EnvironmentObject var calendar: CalendarService
    @AppStorage(Prefs.Key.useCalendar) private var useCalendar = false

    var body: some View {
        let entries = store.timeline(keeping: app.recentlyCompleted, now: app.clock,
                                     events: { useCalendar ? calendar.events(on: $0) : [] })
        if entries.isEmpty {
            EmptyState(icon: "calendar", title: "Nothing scheduled",
                       message: "Tasks with a date show up here in date order. Add one above, like “Board prep fri 3pm 90m”.")
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    EnterUpWindow {
                    LazyVStack(alignment: .leading, spacing: app.compactRows ? 1 : 2) {
                        ForEach(Array(entries.enumerated()), id: \.element.id) { i, entry in
                            row(entry, index: i)
                                // A little air where the date changes, instead of a heading.
                                .padding(.top, i > 0 && entries[i - 1].day != entry.day ? (app.compactRows ? 6 : Space.md) : 0)
                                .id(entry.id)
                        }
                    }
                    }
                    .padding(.horizontal, Space.gutter - 14)
                    .padding(.top, Space.xs)
                    .padding(.bottom, Space.x6)
                }
                .onChange(of: app.scrollRequest) { request in
                    scroll(proxy, to: request, in: entries)
                }
                .onChange(of: app.selectedTaskID) { id in
                    if let id { withAnimation(Motion.snappy) { proxy.scrollTo("t-\(id)") } }
                }
                .onAppear {
                    if app.scrollRequest != nil {
                        DispatchQueue.main.async { scroll(proxy, to: app.scrollRequest, in: entries) }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func row(_ entry: Store.TimelineEntry, index: Int) -> some View {
        switch entry.item {
        case .task(let t):
            TaskRow(task: t, context: .calendar, day: entry.day, index: index,
                    onDropBefore: { reorder($0, above: t) }, canDropBefore: { canReorder($0, above: t) })
        case .event(let e):
            EventRow(event: e, day: entry.day ?? Calendar.current.startOfDay(for: app.clock), index: index, compact: app.compactRows)
        }
    }

    /// Month view → list: land on the first line of that date (or the next date that has something).
    private func scroll(_ proxy: ScrollViewProxy, to request: Date?, in entries: [Store.TimelineEntry]) {
        guard let request else { return }
        let target = entries.first { ($0.day ?? .distantPast) >= request } ?? entries.last
        if let target { withAnimation(Motion.sheet) { proxy.scrollTo(target.id, anchor: .top) } }
        app.scrollRequest = nil
    }

    /// Dragging only reorders tasks that share a date; it never changes a date (see Store.reorderSlot).
    private func canReorder(_ dragged: UUID, above target: TaskItem) -> Bool {
        store.reorderSlot(dragged, above: target.id, now: app.clock) != nil
    }

    private func reorder(_ dragged: UUID, above target: TaskItem) -> Bool {
        defer { app.draggingTaskID = nil }
        guard let slot = store.reorderSlot(dragged, above: target.id, now: app.clock) else { return false }
        store.placeInDay(dragged, before: slot, now: app.clock)
        Haptics.success()
        return true
    }
}

// MARK: - Month grid

struct MonthGrid: View {
    @EnvironmentObject var store: Store
    @EnvironmentObject var app: AppState
    @EnvironmentObject var calendar: CalendarService
    @AppStorage(Prefs.Key.useCalendar) private var useCalendar = false

    var body: some View {
        let cal = Calendar.current
        let monthStart = cal.dateInterval(of: .month, for: app.selectedDay)?.start ?? app.selectedDay
        let gridStart = cal.dateInterval(of: .weekOfYear, for: monthStart)?.start ?? monthStart
        let days = (0..<42).map { cal.date(byAdding: .day, value: $0, to: gridStart)! }
        let agenda = store.agenda(from: days.first!, to: days.last!,
                                  events: { useCalendar ? calendar.events(on: $0) : [] }, keeping: [], now: app.clock)
        let byDay = Dictionary(uniqueKeysWithValues: agenda.days.map { ($0.day, $0) })
        let today = cal.startOfDay(for: app.clock)
        let symbols = cal.shortWeekdaySymbols
        let first = cal.firstWeekday - 1

        VStack(spacing: 0) {
            HStack(spacing: 0) {
                ForEach(0..<7, id: \.self) { i in
                    Eyebrow(text: symbols[(first + i) % 7])
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.leading, 10)
                }
            }
            .padding(.bottom, Space.sm)

            VStack(spacing: 0) {
                ForEach(0..<6, id: \.self) { week in
                    HStack(spacing: 0) {
                        ForEach(0..<7, id: \.self) { col in
                            let day = days[week * 7 + col]
                            MonthCell(day: day, info: byDay[day], inMonth: cal.isDate(day, equalTo: monthStart, toGranularity: .month),
                                      isToday: day == today, isSelected: cal.isDate(day, inSameDayAs: app.selectedDay),
                                      overdue: day == today ? agenda.overdue.count : 0)
                        }
                    }
                    .frame(maxHeight: .infinity)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: Radius.xl, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Radius.xl, style: .continuous).strokeBorder(Color.hair, lineWidth: 1))
        }
        .padding(.horizontal, Space.gutter)
        .padding(.bottom, Space.xl)
        .id(monthStart)
        .transition(.opacity)
    }
}

private struct MonthCell: View {
    @EnvironmentObject var store: Store
    @EnvironmentObject var app: AppState
    let day: Date
    let info: AgendaDay?
    let inMonth: Bool
    let isToday: Bool
    let isSelected: Bool
    let overdue: Int
    @State private var hovering = false
    @State private var dropTarget = false

    var body: some View {
        let items = (info?.items ?? []).filter { $0.task?.isCompleted != true }
        // As many lines as the cell has room for; every row stays exactly 1/6 of the grid.
        ViewThatFits(in: .vertical) {
            cellBody(items, max: 3)
            cellBody(items, max: 2)
            cellBody(items, max: 1)
            cellBody(items, max: 0)
        }
        .padding(6)
        .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity, alignment: .topLeading)
        .clipped()
        .background(isSelected ? Color.fill : (hovering ? Color.pressedTint : Color.card))
        .overlay(Rectangle().strokeBorder(Color.hair, lineWidth: 0.5))
        .overlay { if dropTarget { Rectangle().strokeBorder(Color.ink, lineWidth: 2) } }
        .contentShape(Rectangle())
        .onHover { h in withAnimation(Motion.fast) { hovering = h } }
        .onTapGesture {
            withAnimation(Motion.base) {
                app.calendarMode = .agenda
                app.goTo(day: day)
            }
            Haptics.select()
        }
        .dropDestination(for: String.self) { items, _ in
            dropTasks(items, on: day, store: store, app: app)
        } isTargeted: { t in
            withAnimation(Motion.fast) { dropTarget = t }
        }
        .help("Show \(Fmt.absoluteDay(day)) in the list")
    }

    private func cellBody(_ items: [AgendaItem], max: Int) -> some View {
        let cal = Calendar.current
        let shown = items.prefix(max)
        return VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 4) {
                Text("\(cal.component(.day, from: day))")
                    .font(.system(size: 13, weight: .bold))
                    .monospacedDigit()
                    .foregroundStyle(isToday ? Color.onPrimary : (inMonth ? Color.ink : Color.ink3))
                    .frame(width: 24, height: 24)
                    .background { if isToday { Circle().fill(Color.primaryFill) } }
                Spacer(minLength: 0)
                if overdue > 0 {
                    ViewThatFits(in: .horizontal) {
                        Badge(text: "\(overdue) overdue", tone: .danger)
                        Badge(text: "\(overdue)", tone: .danger, icon: "exclamationmark")
                        Circle().fill(Color.danger).frame(width: 7, height: 7)
                    }
                }
            }
            ForEach(shown) { item in
                line(item)
            }
            if items.count > shown.count {
                Text("+\(items.count - shown.count) more")
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(Color.ink3)
                    .lineLimit(1)
                    .padding(.leading, 4)
            }
        }
    }

    @ViewBuilder
    private func line(_ item: AgendaItem) -> some View {
        switch item {
        case .task(let t):
            let dot = Circle().strokeBorder(t.priority.ringColor, lineWidth: 1.2).frame(width: 7, height: 7)
            let timed = t.dueHasTime && t.dueDate.map { Calendar.current.isDate($0, inSameDayAs: day) } == true
            // The time shows only when there's still room for some of the title.
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 4) {
                    dot
                    if timed, let due = t.dueDate {
                        Text(Fmt.compactTime(due)).fontWeight(.bold).monospacedDigit().fixedSize()
                    }
                    Text(t.title).lineLimit(1).frame(minWidth: 0, idealWidth: 36, maxWidth: .infinity, alignment: .leading)
                }
                HStack(spacing: 4) {
                    dot
                    Text(t.title).lineLimit(1)
                }
            }
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(Color.ink)
            .padding(.horizontal, 4)
            .draggable(t.id.uuidString)
        case .event(let e):
            let bar = Capsule().fill(Color.ink3).frame(width: 2, height: 9)
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 4) {
                    bar
                    if !e.isAllDay { Text(Fmt.compactTime(e.start)).fontWeight(.semibold).monospacedDigit().fixedSize() }
                    Text(e.title).lineLimit(1).frame(minWidth: 0, idealWidth: 36, maxWidth: .infinity, alignment: .leading)
                }
                HStack(spacing: 4) {
                    bar
                    Text(e.title).lineLimit(1)
                }
            }
            .font(.system(size: 11, weight: .regular))
            .foregroundStyle(Color.ink2)
            .padding(.horizontal, 4)
        }
    }
}
