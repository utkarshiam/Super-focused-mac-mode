import Foundation

struct TaskSection: Identifiable {
    var id: String
    var title: String
    var tasks: [TaskItem]
    var style: Style = .normal

    enum Style { case normal, overdue, done }

    var totalMinutes: Int { tasks.filter { !$0.isCompleted }.reduce(0) { $0 + $1.remainingMinutes } }

    var subtitle: String {
        let open = tasks.filter { !$0.isCompleted }.count
        var parts = [Fmt.plural(open, "task")]
        if totalMinutes > 0 { parts.append(Fmt.duration(minutes: totalMinutes)) }
        return parts.joined(separator: " · ")
    }
}

// MARK: - Calendar agenda

/// One line in a calendar day: a task or a calendar event.
enum AgendaItem: Identifiable {
    case task(TaskItem)
    case event(CalendarService.Event)

    var id: String {
        switch self {
        case .task(let t): "t-\(t.id)"
        case .event(let e): "e-\(e.id)"
        }
    }

    var task: TaskItem? {
        if case .task(let t) = self { return t }
        return nil
    }
}

struct AgendaDay: Identifiable {
    var day: Date
    var items: [AgendaItem]
    var id: String { Fmt.dayKey(day) }

    var openTasks: [TaskItem] { items.compactMap(\.task).filter { !$0.isCompleted } }
    var minutes: Int { openTasks.reduce(0) { $0 + $1.remainingMinutes } }
    var eventCount: Int { items.filter { if case .event = $0 { return true } else { return false } }.count }
}

struct Agenda {
    var overdue: [TaskItem] = []
    var days: [AgendaDay] = []
    var later: [TaskItem] = []

    /// Tasks in display order, for keyboard navigation.
    var taskOrder: [UUID] {
        overdue.map(\.id) + days.flatMap { $0.items.compactMap(\.task).map(\.id) } + later.map(\.id)
    }
}

extension Store {
    // MARK: Sorting

    func sorted(_ items: [TaskItem], by mode: SortMode) -> [TaskItem] {
        let cal = calendar
        func dueKey(_ t: TaskItem) -> Date {
            guard let d = t.dueDate else { return .distantFuture }
            return t.dueHasTime ? d : cal.endOfDay(for: d)
        }
        return items.sorted { a, b in
            if a.isCompleted != b.isCompleted { return !a.isCompleted }
            switch mode {
            case .smart, .dueDate:
                if dueKey(a) != dueKey(b) { return dueKey(a) < dueKey(b) }
                if a.priority != b.priority { return a.priority > b.priority }
            case .priority:
                if a.priority != b.priority { return a.priority > b.priority }
                if dueKey(a) != dueKey(b) { return dueKey(a) < dueKey(b) }
            case .estimate:
                let ea = a.estimateMinutes ?? .max, eb = b.estimateMinutes ?? .max
                if ea != eb { return ea < eb }
                if a.priority != b.priority { return a.priority > b.priority }
            case .title:
                let r = a.title.localizedStandardCompare(b.title)
                if r != .orderedSame { return r == .orderedAscending }
            }
            return a.createdAt < b.createdAt
        }
    }

    /// The day a task sits on in the calendar. Missed plan dates roll forward to today;
    /// missed deadlines go to Overdue instead (see `agenda`). Nil means "anytime".
    func calendarDay(of t: TaskItem, today: Date) -> Date? {
        guard let d = t.agendaDay(calendar: calendar) else { return nil }
        return max(d, today)
    }

    func isOverdueByDay(_ t: TaskItem, today: Date) -> Bool {
        guard let due = t.dueDate else { return false }
        return calendar.startOfDay(for: due) < today
    }

    /// Everything the Calendar view shows between two days: overdue work, each day's tasks
    /// and events (untimed first, then by time, then what was finished), and later tasks.
    func agenda(from start: Date, to end: Date, events: (Date) -> [CalendarService.Event], keeping: Set<UUID>, now: Date = Date()) -> Agenda {
        let cal = calendar
        let today = cal.startOfDay(for: now)
        let first = cal.startOfDay(for: start), last = cal.startOfDay(for: end)
        var result = Agenda()
        var buckets: [Date: [TaskItem]] = [:]
        var done: [Date: [TaskItem]] = [:]

        for t in tasks {
            if t.isCompleted && !keeping.contains(t.id) {
                let day = cal.startOfDay(for: t.completedAt!)
                if day >= first, day <= last { done[day, default: []].append(t) }
                continue
            }
            if isOverdueByDay(t, today: today) {
                result.overdue.append(t)
                continue
            }
            guard let day = calendarDay(of: t, today: today) else { continue }
            if day > last {
                result.later.append(t)
            } else if day >= first {
                buckets[day, default: []].append(t)
            }
        }

        var day = first
        while day <= last {
            let dayTasks = buckets[day] ?? []
            func timeOnDay(_ t: TaskItem) -> Date? {
                guard t.dueHasTime, let due = t.dueDate, cal.isDate(due, inSameDayAs: day) else { return nil }
                return due
            }
            let untimed = dayOrdered(dayTasks.filter { timeOnDay($0) == nil })
            let dayEvents = events(day)
            var timed: [(Date, AgendaItem)] = dayTasks.compactMap { t in timeOnDay(t).map { ($0, .task(t)) } }
            timed += dayEvents.filter { !$0.isAllDay }.map { (max($0.start, day), .event($0)) }
            timed.sort { $0.0 < $1.0 }

            var items: [AgendaItem] = untimed.map { .task($0) }
            items += dayEvents.filter(\.isAllDay).map { .event($0) }
            items += timed.map(\.1)
            items += (done[day] ?? []).sorted { $0.completedAt! < $1.completedAt! }.map { .task($0) }
            result.days.append(AgendaDay(day: day, items: items))
            day = cal.date(byAdding: .day, value: 1, to: day)!
        }

        result.overdue = dayOrdered(result.overdue, fallback: .dueDate)
        result.later = sorted(result.later, by: .dueDate)
        return result
    }

    /// Order within a day: tasks placed by hand (drag and drop) first, in that order; the rest by priority.
    func dayOrdered(_ items: [TaskItem], fallback: SortMode = .priority) -> [TaskItem] {
        let ranked = items.filter { $0.rank != nil }.sorted { ($0.rank!, $0.createdAt) < ($1.rank!, $1.createdAt) }
        let rest = sorted(items.filter { $0.rank == nil }, by: fallback)
        return ranked + rest
    }

    /// Where a task sits in the calendar right now, for reordering: its day's anytime tasks,
    /// or the Overdue group. Timed tasks keep time order, so they have no list.
    func dayList(containing id: UUID, now: Date = Date()) -> (day: Date?, ids: [UUID])? {
        guard let t = task(id), !t.isCompleted else { return nil }
        let today = calendar.startOfDay(for: now)
        if isOverdueByDay(t, today: today) {
            let overdue = tasks.filter { !$0.isCompleted && isOverdueByDay($0, today: today) }
            return (nil, dayOrdered(overdue, fallback: .dueDate).map(\.id))
        }
        guard let day = calendarDay(of: t, today: today) else { return nil }
        func isTimed(_ x: TaskItem) -> Bool {
            guard x.dueHasTime, let due = x.dueDate else { return false }
            return calendar.isDate(due, inSameDayAs: day)
        }
        guard !isTimed(t) else { return nil }
        let same = tasks.filter { x in
            !x.isCompleted && !isOverdueByDay(x, today: today) && calendarDay(of: x, today: today) == day && !isTimed(x)
        }
        return (day, dayOrdered(same).map(\.id))
    }

    /// Where a dragged task lands when dropped above `targetID` in the Calendar: before that task, or
    /// (inner nil) at the end of the day's untimed tasks when the target is a timed task on the same date.
    /// Outer nil means the drop isn't allowed: dragging only reorders tasks that share a date and never
    /// changes a date (the date picker and the Month view do that). Timed tasks keep their time order.
    func reorderSlot(_ draggedID: UUID, above targetID: UUID, now: Date = Date()) -> UUID?? {
        guard draggedID != targetID, let list = dayList(containing: draggedID, now: now), let target = task(targetID) else { return nil }
        if list.ids.contains(targetID) { return .some(targetID) }
        let today = calendar.startOfDay(for: now)
        guard let day = list.day, !target.isCompleted, !isOverdueByDay(target, today: today),
              calendarDay(of: target, today: today) == day,
              target.dueHasTime, let due = target.dueDate, calendar.isDate(due, inSameDayAs: day) else { return nil }
        return .some(nil)
    }

    /// Puts `id` just before `beforeID` (or last when nil) in its day, numbering that day's tasks 1…n.
    func placeInDay(_ id: UUID, before beforeID: UUID?, now: Date = Date()) {
        guard let list = dayList(containing: id, now: now) else { return }
        var ids = list.ids.filter { $0 != id }
        if let beforeID, let i = ids.firstIndex(of: beforeID) { ids.insert(id, at: i) } else { ids.append(id) }
        applyRanks(ids, name: "Reorder")
    }

    /// ⌥⌘↑ / ⌥⌘↓: nudges a task within its day. Returns false when it can't move (timed, or already at the edge).
    @discardableResult
    func moveInDay(_ id: UUID, by delta: Int, now: Date = Date()) -> Bool {
        guard let list = dayList(containing: id, now: now), let i = list.ids.firstIndex(of: id) else { return false }
        let j = i + delta
        guard list.ids.indices.contains(j) else { return false }
        var ids = list.ids
        ids.swapAt(i, j)
        applyRanks(ids, name: "Reorder")
        return true
    }

    private func applyRanks(_ ids: [UUID], name: String) {
        setRanks(Dictionary(uniqueKeysWithValues: ids.enumerated().map { ($1, Double($0 + 1)) }), undo: name)
    }

    /// One line of the Calendar list: a task or an event, and the day it sits on (nil = overdue).
    struct TimelineEntry: Identifiable {
        var item: AgendaItem
        var day: Date?
        var id: String { item.id }
    }

    /// The Calendar as one flat list in date order: overdue first, then every dated task from today on
    /// (each day: hand-ordered/priority tasks, then timed tasks and meetings by time).
    func timeline(keeping: Set<UUID>, now: Date = Date(), events: (Date) -> [CalendarService.Event] = { _ in [] }) -> [TimelineEntry] {
        let cal = calendar
        let today = cal.startOfDay(for: now)
        let lastTaskDay = tasks.compactMap { t -> Date? in
            guard !t.isCompleted || keeping.contains(t.id) else { return nil }
            return calendarDay(of: t, today: today)
        }.max() ?? today
        let eventHorizon = cal.date(byAdding: .day, value: 14, to: today)!
        let last = max(lastTaskDay, today)
        let a = agenda(from: today, to: last, events: { $0 <= eventHorizon ? events($0) : [] }, keeping: keeping, now: now)
        var entries = a.overdue.map { TimelineEntry(item: .task($0), day: nil) }
        for d in a.days {
            for item in d.items {
                // Finished tasks live in Completed; only the ones just ticked linger here for a moment.
                if let t = item.task, t.isCompleted, !keeping.contains(t.id) { continue }
                entries.append(TimelineEntry(item: item, day: d.day))
            }
        }
        return entries
    }

    /// Open tasks per day (for the month grid), keyed by day.
    func openTaskCounts(from start: Date, to end: Date, now: Date = Date()) -> [Date: Int] {
        let today = calendar.startOfDay(for: now)
        var counts: [Date: Int] = [:]
        for t in tasks where !t.isCompleted && !isOverdueByDay(t, today: today) {
            guard let d = calendarDay(of: t, today: today), d >= start, d <= end else { continue }
            counts[d, default: 0] += 1
        }
        return counts
    }

    // MARK: Sections per sidebar item (list views)

    /// `keeping` lists recently completed tasks that should stay where they were for a moment.
    func sections(for item: SidebarItem, keeping: Set<UUID>, sort: SortMode = .smart, showCompleted: Bool = false, now: Date = Date()) -> [TaskSection] {
        let cal = calendar
        let today = cal.startOfDay(for: now)
        let open = tasks.filter { !$0.isCompleted || keeping.contains($0.id) }

        switch item {
        case .calendar:
            // Overdue + today, used for counts and "is it visible here" checks.
            let overdue = open.filter { isOverdueByDay($0, today: today) }
            let ids = Set(overdue.map(\.id))
            let todays = open.filter { !ids.contains($0.id) && calendarDay(of: $0, today: today) == today }
            return [
                TaskSection(id: "overdue", title: "Overdue", tasks: sorted(overdue, by: sort), style: .overdue),
                TaskSection(id: "today", title: "Today", tasks: sorted(todays, by: sort)),
            ].filter { !$0.tasks.isEmpty }

        case .inbox:
            let validLists = Set(lists.map(\.id))
            let items = open.filter { $0.listID == nil || !validLists.contains($0.listID!) }
            return [TaskSection(id: "inbox", title: "Inbox", tasks: sorted(items, by: sort))].filter { !$0.tasks.isEmpty }

        case .important:
            let items = open.filter { $0.priority >= .high }
            return [TaskSection(id: "important", title: "High priority", tasks: sorted(items, by: sort))].filter { !$0.tasks.isEmpty }

        case .all:
            let validLists = Set(lists.map(\.id))
            var result: [TaskSection] = []
            let inbox = open.filter { $0.listID == nil || !validLists.contains($0.listID!) }
            if !inbox.isEmpty { result.append(TaskSection(id: "inbox", title: "Inbox", tasks: sorted(inbox, by: sort))) }
            for list in lists {
                let items = open.filter { $0.listID == list.id }
                if !items.isEmpty { result.append(TaskSection(id: list.id.uuidString, title: list.name, tasks: sorted(items, by: sort))) }
            }
            return result

        case .completed:
            let done = tasks.filter { $0.isCompleted }.sorted { $0.completedAt! > $1.completedAt! }.prefix(500)
            var groups: [(Date, [TaskItem])] = []
            for t in done {
                let day = cal.startOfDay(for: t.completedAt!)
                if let last = groups.last, last.0 == day { groups[groups.count - 1].1.append(t) } else { groups.append((day, [t])) }
            }
            return groups.map { day, items in
                TaskSection(id: Fmt.dayKey(day), title: Fmt.absoluteDay(day, now: now), tasks: items, style: .done)
            }

        case .list(let id):
            var result = [TaskSection(id: "open", title: list(id)?.name ?? "List", tasks: sorted(open.filter { $0.listID == id }, by: sort))]
            if showCompleted {
                let done = tasks.filter { $0.listID == id && $0.isCompleted && !keeping.contains($0.id) }
                    .sorted { $0.completedAt! > $1.completedAt! }
                result.append(TaskSection(id: "done", title: "Completed", tasks: done, style: .done))
            }
            return result.filter { !$0.tasks.isEmpty }

        case .tag(let tag):
            let items = open.filter { $0.tags.contains { $0.caseInsensitiveCompare(tag) == .orderedSame } }
            return [TaskSection(id: "tag", title: "#\(tag)", tasks: sorted(items, by: sort))].filter { !$0.tasks.isEmpty }

        case .waiting:
            let items = open.filter { !($0.waitingOn ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            // Smart order here is by when it's needed back; any other sort the user picked still applies.
            let ordered = sort == .smart ? waitingOrder(items) : sorted(items, by: sort)
            return [TaskSection(id: "waiting", title: "Waiting on others", tasks: ordered)].filter { !$0.tasks.isEmpty }

        case .notes, .insights, .search, .suggestions:
            return []
        }
    }

    /// Delegated tasks by deadline (or plan date when there's none), then title. Undated ones go last.
    private func waitingOrder(_ items: [TaskItem]) -> [TaskItem] {
        let cal = calendar
        func when(_ t: TaskItem) -> Date {
            if let due = t.dueDate { return t.dueHasTime ? due : cal.endOfDay(for: due) }
            if let planned = t.scheduledDate { return cal.endOfDay(for: planned) }
            return .distantFuture
        }
        return items.sorted { a, b in
            let wa = when(a), wb = when(b)
            if wa != wb { return wa < wb }
            let byTitle = a.title.localizedStandardCompare(b.title)
            if byTitle != .orderedSame { return byTitle == .orderedAscending }
            return a.createdAt < b.createdAt
        }
    }

    // MARK: Counts

    func todayTasks(now: Date = Date()) -> [TaskItem] {
        let today = calendar.startOfDay(for: now)
        let open = tasks.filter {
            !$0.isCompleted && ($0.isDue(onOrBefore: today, calendar: calendar) || $0.isScheduled(onOrBefore: today, calendar: calendar))
        }
        let overdue = open.filter { isOverdueByDay($0, today: today) }
        let rest = open.filter { !isOverdueByDay($0, today: today) }
        let timed = rest.filter { $0.dueHasTime && $0.dueDate.map { calendar.isDate($0, inSameDayAs: today) } == true }
        let timedIDs = Set(timed.map(\.id))
        return dayOrdered(overdue, fallback: .dueDate)
            + dayOrdered(rest.filter { !timedIDs.contains($0.id) })
            + timed.sorted { $0.dueDate! < $1.dueDate! }
    }

    func count(for item: SidebarItem) -> Int {
        sections(for: item, keeping: []).filter { $0.style != .done }.reduce(0) { $0 + $1.tasks.count }
    }

    func overdueCount(now: Date = Date()) -> Int {
        tasks.filter { $0.isOverdue(now: now, calendar: calendar) }.count
    }

    var allTags: [String] {
        var seen = Set<String>()
        var result: [String] = []
        for t in tasks where !t.isCompleted {
            for tag in t.tags where seen.insert(tag.lowercased()).inserted { result.append(tag) }
        }
        return result.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    // MARK: Search

    func searchTasks(_ query: String, limit: Int = 30) -> [TaskItem] {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return [] }
        let matches = tasks.filter {
            $0.title.localizedCaseInsensitiveContains(q) || $0.notes.localizedCaseInsensitiveContains(q)
                || $0.tags.contains { $0.localizedCaseInsensitiveContains(q.trimmingCharacters(in: CharacterSet(charactersIn: "#"))) }
        }
        return Array(sorted(matches, by: .smart).prefix(limit))
    }

    func searchNotes(_ query: String, limit: Int = 30) -> [Note] {
        let q = query.trimmingCharacters(in: .whitespaces)
        let base = notes.sorted { ($0.isPinned ? 1 : 0, $0.updatedAt) > ($1.isPinned ? 1 : 0, $1.updatedAt) }
        guard !q.isEmpty else { return base }
        return Array(base.filter { $0.body.localizedCaseInsensitiveContains(q) }.prefix(limit))
    }

    // MARK: Rescheduling

    /// Drag-and-drop onto a day: moves the deadline if the task has one (keeping its time), otherwise the plan date.
    func move(_ id: UUID, toDay day: Date) {
        guard let t = task(id) else { return }
        if t.dueDate != nil {
            setDueDay(id, day)
            if t.scheduledDate != nil { mutateTask(id) { $0.scheduledDate = nil } }
        } else {
            setScheduled(id, day)
        }
    }
}
