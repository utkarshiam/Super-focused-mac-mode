import SwiftUI

struct TaskRow: View {
    @EnvironmentObject var store: Store
    @EnvironmentObject var app: AppState
    @EnvironmentObject var focus: FocusTimer
    let task: TaskItem
    var context: SidebarItem
    /// The calendar day this row is listed under (nil in Overdue and in plain lists).
    var day: Date?
    var index = 0
    /// Calendar only: another task dropped on this row lands just above it (returns whether it was accepted).
    var onDropBefore: ((UUID) -> Bool)?
    /// Whether a dragged task may land above this row (drags only reorder; they never change a date).
    var canDropBefore: ((UUID) -> Bool)?
    @State private var hovering = false
    @State private var dropTarget = false

    private var isSelected: Bool { app.selectedTaskID == task.id }
    private var dimmed: Bool { task.isCompleted }

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            CheckCircle(done: task.isCompleted, priority: task.priority) {
                app.toggle(task.id, in: store)
            }

            TitleWhenLayout {
                VStack(alignment: .leading, spacing: 4) {
                    Text(task.title)
                        .font(.system(size: 15, weight: .semibold))
                        .tracking(-0.2)
                        .foregroundStyle(dimmed ? Color.ink3 : Color.ink)
                        .strikethrough(dimmed, color: .ink3)
                        .lineLimit(2)
                    meta
                }
                HStack(spacing: Space.sm) {
                    if focus.taskID == task.id {
                        Badge(text: "Focusing", tone: .primary, icon: "timer")
                    }
                    WhenLabel(task: task, context: context, day: day, now: app.clock)
                }
                .fixedSize()
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .background(
            RoundedRectangle(cornerRadius: Radius.md, style: .continuous)
                .fill(isSelected ? Color.fill : (hovering ? Color.pressedTint : Color.clear))
        )
        .overlay(
            RoundedRectangle(cornerRadius: Radius.md, style: .continuous)
                .strokeBorder(isSelected ? Color.hairStrong : Color.clear, lineWidth: 1)
        )
        .overlay(alignment: .leading) {
            // A grip on hover says "you can drag this".
            if onDropBefore != nil, hovering, !task.isCompleted {
                Image(systemName: "line.3.horizontal")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(Color.ink3)
                    .padding(.leading, 2)
                    .transition(.opacity)
            }
        }
        .overlay(alignment: .top) {
            // Where a dragged task will land.
            if dropTarget {
                Capsule()
                    .fill(Color.ink)
                    .frame(height: 2.5)
                    .padding(.horizontal, 8)
                    .offset(y: -2)
                    .transition(.opacity)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            // Opening and closing the panel animate; switching to another task is instant.
            if app.selectedTaskID == nil || isSelected {
                withAnimation(Motion.sheet) { app.selectedTaskID = isSelected ? nil : task.id }
            } else {
                app.selectedTaskID = task.id
            }
        }
        .onHover { h in withAnimation(Motion.fast) { hovering = h } }
        .contextMenu { TaskContextMenu(task: task, inCalendar: context == .calendar) }
        .draggable(dragPayload()) {
            Text(task.title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Color.onPrimary)
                .padding(.horizontal, 14)
                .frame(height: 32)
                .background(Capsule().fill(Color.primaryFill))
        }
        .modifier(RowDrop(enabled: onDropBefore != nil && !task.isCompleted, rowID: task.id, dragging: app.draggingTaskID,
                          accepts: canDropBefore ?? { _ in true }, onDrop: onDropBefore, targeted: $dropTarget))
        .opacity(task.isCompleted && app.recentlyCompleted.contains(task.id) ? 0.5 : 1)
        .enterUp(index)
    }

    /// Evaluated when a drag starts: remember which task is moving.
    private func dragPayload() -> String {
        let id = task.id
        DispatchQueue.main.async { app.draggingTaskID = id }
        return id.uuidString
    }

    @ViewBuilder
    private var meta: some View {
        let list = store.list(task.listID)
        let progress = task.subtaskProgress
        let showList = list != nil && !isListContext
        let hasMeta = showList || task.trackedSeconds >= 60 || !task.tags.isEmpty || progress.total > 0
            || (context == .calendar && day != nil && task.dueDate.map { !Calendar.current.isDate($0, inSameDayAs: day!) } == true)
            || task.recurrence != nil || !task.reminders.isEmpty || !task.notes.isEmpty || task.linkedNoteID != nil || task.priority.tone != nil

        if hasMeta {
            HStack(spacing: 10) {
                if let tone = task.priority.tone, !task.isCompleted {
                    Badge(text: task.priority.label, tone: tone)
                        .fixedSize()
                }
                if let list, showList {
                    metaItem(list.icon, list.name)
                        .layoutPriority(1)
                }
                if task.trackedSeconds >= 60 {
                    metaItem("timer", "\(Fmt.duration(seconds: task.trackedSeconds)) spent")
                        .layoutPriority(2)
                }
                if context == .calendar, let day, let due = task.dueDate, !task.isCompleted,
                   !Calendar.current.isDate(due, inSameDayAs: day) {
                    metaItem("flag", "Due \(Fmt.absoluteDay(due, now: app.clock))")
                        .layoutPriority(2)
                }
                if progress.total > 0 {
                    metaItem("checklist", "\(progress.done)/\(progress.total)")
                        .layoutPriority(2)
                }
                if let first = task.tags.first {
                    // Whole tags or none: squeezed tags would show as stray dots.
                    ViewThatFits(in: .horizontal) {
                        Text(task.tags.prefix(3).map { "#\($0)" }.joined(separator: "  "))
                        Text("#\(first)")
                        Color.clear.frame(width: 0, height: 0)
                    }
                }
                if task.recurrence != nil { Image(systemName: "repeat") }
                if !task.reminders.isEmpty, !task.isCompleted {
                    Image(systemName: task.hasAlarm ? "alarm" : "bell")
                }
                if !task.notes.isEmpty || task.linkedNoteID != nil {
                    Image(systemName: task.linkedNoteID != nil ? "doc.text" : "text.alignleft")
                }
            }
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(Color.ink2)
            .lineLimit(1)
        }
    }

    private var isListContext: Bool {
        if case .list = context { return true }
        return false
    }

    private func metaItem(_ icon: String, _ text: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon).font(.system(size: 10, weight: .semibold))
            Text(text)
        }
    }
}

/// Accepts a dragged task id (not the row's own) that `accepts` allows, and reports hover so the row
/// can draw its insertion line. Rows that wouldn't take the dragged task show no line.
private struct RowDrop: ViewModifier {
    let enabled: Bool
    let rowID: UUID
    /// The task being dragged, when known.
    let dragging: UUID?
    let accepts: (UUID) -> Bool
    let onDrop: ((UUID) -> Bool)?
    @Binding var targeted: Bool

    func body(content: Content) -> some View {
        if enabled, let onDrop {
            content.dropDestination(for: String.self) { items, _ in
                guard let dragged = items.compactMap(UUID.init(uuidString:)).first, dragged != rowID, accepts(dragged) else { return false }
                return withAnimation(Motion.gentle) { onDrop(dragged) }
            } isTargeted: { t in
                let allowed = dragging.map { $0 != rowID && accepts($0) } ?? true
                withAnimation(Motion.fast) { targeted = t && allowed }
            }
        } else {
            content
        }
    }
}

/// The right side of every line: the date (and time) in bold, then how long it takes.
/// Always the real date ("Mon 5 Oct"), never "Today"/"Tomorrow".
struct WhenLabel: View {
    let task: TaskItem
    var context: SidebarItem
    /// In the Calendar list: the date this line sits on (nil for overdue tasks).
    var day: Date?
    var now: Date

    var body: some View {
        HStack(spacing: Space.sm) {
            if let text = dateText {
                Text(text)
                    .font(.system(size: 15, weight: .bold))
                    .tracking(-0.2)
                    .monospacedDigit()
                    .foregroundStyle(color)
                    .lineLimit(1)
            }
            if let minutes = task.estimateMinutes, !task.isCompleted {
                DurationPill(minutes: minutes)
            }
        }
        .fixedSize()
    }

    private var color: Color {
        if task.isCompleted { return .ink3 }
        return task.isOverdue(now: now) ? .danger : .ink
    }

    private var dateText: String? {
        let cal = Calendar.current
        if let done = task.completedAt {
            return "\(Fmt.absoluteDay(done, now: now)) · \(Fmt.time(done))"
        }
        // In the Calendar the line's date is where the task sits; its time shows when it's due that day.
        if context == .calendar, let day {
            if task.dueHasTime, let due = task.dueDate, cal.isDate(due, inSameDayAs: day) {
                return "\(Fmt.absoluteDay(day, now: now)) · \(Fmt.time(due))"
            }
            return Fmt.absoluteDay(day, now: now)
        }
        if let due = task.dueDate {
            return task.dueHasTime ? "\(Fmt.absoluteDay(due, now: now)) · \(Fmt.time(due))" : Fmt.absoluteDay(due, now: now)
        }
        if let planned = task.scheduledDate {
            return Fmt.absoluteDay(planned, now: now)
        }
        return nil
    }
}

/// A line's title block on the left and its bold date on the right. When the row is too narrow for
/// both, the date drops under the title instead of squeezing the title down to a few letters.
struct TitleWhenLayout: Layout {
    var spacing: CGFloat = 16
    /// The title keeps at least this much (or its whole width, if shorter) beside the date.
    var minTitleWidth: CGFloat = 140
    /// Below this every row stacks, so a narrow list reads as one pattern rather than a mix.
    var minSideBySideWidth: CGFloat = 360
    var stackedSpacing: CGFloat = Space.sm

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard subviews.count == 2 else { return .zero }
        let when = subviews[1].sizeThatFits(.unspecified)
        let reserved = when.width > 0 ? when.width + spacing : 0
        guard let width = proposal.width, width.isFinite else {
            let title = subviews[0].sizeThatFits(.unspecified)
            return CGSize(width: title.width + reserved, height: max(title.height, when.height))
        }
        if sideBySide(width, subviews) {
            let title = subviews[0].sizeThatFits(ProposedViewSize(width: max(0, width - reserved), height: nil))
            return CGSize(width: width, height: max(title.height, when.height))
        }
        let title = subviews[0].sizeThatFits(ProposedViewSize(width: width, height: nil))
        return CGSize(width: width, height: title.height + stackedSpacing + when.height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard subviews.count == 2 else { return }
        let when = subviews[1].sizeThatFits(.unspecified)
        if sideBySide(bounds.width, subviews) {
            let titleWidth = max(0, bounds.width - (when.width > 0 ? when.width + spacing : 0))
            let title = subviews[0].sizeThatFits(ProposedViewSize(width: titleWidth, height: nil))
            subviews[0].place(at: CGPoint(x: bounds.minX, y: bounds.midY - title.height / 2),
                              proposal: ProposedViewSize(width: titleWidth, height: title.height))
            subviews[1].place(at: CGPoint(x: bounds.maxX - when.width, y: bounds.midY - when.height / 2), proposal: ProposedViewSize(when))
        } else {
            let title = subviews[0].sizeThatFits(ProposedViewSize(width: bounds.width, height: nil))
            subviews[0].place(at: CGPoint(x: bounds.minX, y: bounds.minY), proposal: ProposedViewSize(width: bounds.width, height: title.height))
            subviews[1].place(at: CGPoint(x: bounds.minX, y: bounds.minY + title.height + stackedSpacing), proposal: ProposedViewSize(when))
        }
    }

    private func sideBySide(_ width: CGFloat, _ subviews: Subviews) -> Bool {
        let when = subviews[1].sizeThatFits(.unspecified).width
        guard when > 0 else { return true }
        guard width >= minSideBySideWidth else { return false }
        let title = subviews[0].sizeThatFits(.unspecified).width
        return width - when - spacing >= min(minTitleWidth, title)
    }
}

/// "45m" in a soft pill: the time a task (or meeting) takes.
struct DurationPill: View {
    var minutes: Int

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: "hourglass").font(.system(size: 9, weight: .bold))
            Text(Fmt.duration(minutes: minutes))
        }
        .font(.system(size: 12, weight: .semibold))
        .monospacedDigit()
        .foregroundStyle(Color.ink2)
        .padding(.horizontal, 8)
        .frame(height: 22)
        .background(Capsule().fill(Color.fill))
    }
}

/// A calendar event in the agenda: a quiet bar instead of a checkbox, time on the right.
struct EventRow: View {
    let event: CalendarService.Event
    var day: Date
    var index = 0

    var body: some View {
        let cal = Calendar.current
        HStack(alignment: .center, spacing: 14) {
            Capsule()
                .fill(Color.ink3)
                .frame(width: 3, height: 26)
                .frame(width: 22)
            TitleWhenLayout {
                VStack(alignment: .leading, spacing: 3) {
                    Text(event.title)
                        .font(.system(size: 15, weight: .medium))
                        .tracking(-0.2)
                        .foregroundStyle(Color.ink2)
                        .lineLimit(1)
                    Text(event.calendarName)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Color.ink3)
                        .lineLimit(1)
                }
                HStack(spacing: Space.sm) {
                    Text(event.isAllDay ? "\(Fmt.absoluteDay(day)) · All day"
                         : (cal.isDate(event.start, inSameDayAs: day) ? "\(Fmt.absoluteDay(day)) · \(Fmt.time(event.start))" : "\(Fmt.absoluteDay(day)) · Ongoing"))
                        .font(.system(size: 15, weight: .bold))
                        .tracking(-0.2)
                        .monospacedDigit()
                        .foregroundStyle(Color.ink2)
                        .lineLimit(1)
                    if !event.isAllDay {
                        DurationPill(minutes: max(1, Int(event.end.timeIntervalSince(event.start) / 60)))
                    }
                }
                .fixedSize()
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .enterUp(index)
    }
}

struct TaskContextMenu: View {
    @EnvironmentObject var store: Store
    @EnvironmentObject var app: AppState
    @EnvironmentObject var focus: FocusTimer
    let task: TaskItem
    var inCalendar = false

    var body: some View {
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        let tomorrow = cal.date(byAdding: .day, value: 1, to: today)!
        let nextMonday = Recurrence(frequency: .weekly, weekdays: [2]).advance(today)

        Button(task.isCompleted ? "Mark as Not Done" : "Mark as Done") { app.toggle(task.id, in: store) }
        if inCalendar, let list = store.dayList(containing: task.id), list.ids.count > 1 {
            Divider()
            Button("Move to Top of Day") {
                withAnimation(Motion.gentle) { store.placeInDay(task.id, before: list.ids.first) }
            }
            .disabled(list.ids.first == task.id)
            Button("Move Up") { withAnimation(Motion.gentle) { _ = store.moveInDay(task.id, by: -1) } }
                .disabled(list.ids.first == task.id)
            Button("Move Down") { withAnimation(Motion.gentle) { _ = store.moveInDay(task.id, by: 1) } }
                .disabled(list.ids.last == task.id)
        }
        Divider()
        Button("Do Today") { store.setScheduled(task.id, today) }
        Button("Do Tomorrow") { store.setScheduled(task.id, tomorrow) }
        if task.scheduledDate != nil {
            Button("Remove Plan Date") { store.setScheduled(task.id, nil) }
        }
        Menu("Deadline") {
            Button("Today") { store.setDueDay(task.id, today) }
            Button("Tomorrow") { store.setDueDay(task.id, tomorrow) }
            Button("Next Monday") { store.setDueDay(task.id, nextMonday) }
            Button("In a Week") { store.setDueDay(task.id, cal.date(byAdding: .day, value: 7, to: today)) }
            if task.dueDate != nil {
                Divider()
                Button("Remove Deadline") { store.setDueDay(task.id, nil) }
            }
        }
        Menu("Priority") {
            ForEach(Priority.allCases.reversed()) { p in
                Button { store.mutateTask(task.id, undo: "Set Priority") { $0.priority = p } } label: {
                    if task.priority == p { Label(p.label, systemImage: "checkmark") } else { Text(p.label) }
                }
            }
        }
        Menu("Move to List") {
            Button("Inbox") { store.mutateTask(task.id, undo: "Move") { $0.listID = nil } }
            ForEach(store.lists) { list in
                Button(list.name) { store.mutateTask(task.id, undo: "Move") { $0.listID = list.id } }
            }
        }
        Divider()
        if focus.taskID == task.id {
            Button("Stop Focus Session") { focus.stop(markDone: false) }
        } else {
            let minutes = task.remainingMinutes > 0 ? task.remainingMinutes : Prefs.focusMinutes
            Button("Start Focus (\(Fmt.duration(minutes: minutes)))") { focus.start(taskID: task.id, minutes: minutes) }
        }
        Button("Duplicate") {
            if let copy = store.duplicateTask(task.id) { app.selectedTaskID = copy.id }
        }
        Divider()
        Button("Delete", role: .destructive) {
            if app.selectedTaskID == task.id { app.selectedTaskID = nil }
            store.deleteTasks([task.id])
        }
    }
}
