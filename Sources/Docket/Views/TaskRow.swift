import AppKit
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

    /// The focused task and every task in a multi-selection share the selected look.
    private var isSelected: Bool { app.isSelected(task.id) }
    private var dimmed: Bool { task.isCompleted }
    private var compact: Bool { app.compactRows }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: compact ? Radius.sm : Radius.md, style: .continuous)
        Group {
            if compact { compactLine } else { regularLine }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, compact ? 6 : 11)
        .background(shape.fill(isSelected ? Color.fill : (hovering ? Color.pressedTint : Color.clear)))
        .overlay(shape.strokeBorder(isSelected ? Color.hairStrong : Color.clear, lineWidth: 1))
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
        .onTapGesture(perform: handleClick)
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
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .enterUp(index)
    }

    private var regularLine: some View {
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
    }

    /// Compact rows: one ~30pt line. Small check, the title (truncated, never wrapped), tiny glyphs for
    /// the details, then the date and duration on the right.
    private var compactLine: some View {
        HStack(alignment: .center, spacing: 10) {
            CheckCircle(done: task.isCompleted, priority: task.priority, size: 16) {
                app.toggle(task.id, in: store)
            }
            // The title always keeps room to be read; the glyphs, then source, delegation and tags, get what's left.
            CompactLineLayout {
                Text(task.title)
                    .font(.system(size: 13.5, weight: .semibold))
                    .tracking(-0.1)
                    .foregroundStyle(dimmed ? Color.ink3 : Color.ink)
                    .strikethrough(dimmed, color: .ink3)
                    .lineLimit(1)
                    .truncationMode(.tail)
                compactGlyphs
                // Source, delegation and tags only when the whole title fits beside them.
                ViewThatFits(in: .horizontal) {
                    compactExtras(tagCount: 2)
                    compactExtras(tagCount: 0)
                    Color.clear.frame(width: 0, height: 0)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: 6) {
                if focus.taskID == task.id {
                    Image(systemName: "timer")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(Color.ink)
                        .help("Focusing on this now")
                }
                WhenLabel(task: task, context: context, day: day, now: app.clock, compact: true)
            }
            .fixedSize()
        }
        .frame(minHeight: 18)
    }

    /// The compact row's details as tiny icons; each one says what it means on hover. A narrow row keeps
    /// as many as fit beside the title, dropping them from the end.
    private var compactGlyphs: some View {
        let glyphs = compactGlyphItems
        return ViewThatFits(in: .horizontal) {
            ForEach(Array((0...glyphs.count).reversed()), id: \.self) { count in
                HStack(spacing: 5) {
                    ForEach(glyphs.prefix(count)) { RowGlyphView(glyph: $0) }
                }
                .fixedSize()
            }
        }
        .font(.system(size: 10.5, weight: .semibold))
        .foregroundStyle(Color.ink3)
    }

    private var compactGlyphItems: [RowGlyph] {
        var glyphs: [RowGlyph] = []
        if let tone = task.priority.tone, !task.isCompleted {
            glyphs.append(RowGlyph(id: "priority", symbol: "flag.fill", help: "\(task.priority.label) priority", tint: tone.fg))
        }
        if let list = store.list(task.listID), !isListContext {
            glyphs.append(RowGlyph(id: "list", symbol: list.icon, help: list.name))
        }
        if context == .calendar, let day, let due = task.dueDate, !task.isCompleted,
           !Calendar.current.isDate(due, inSameDayAs: day) {
            glyphs.append(RowGlyph(id: "due", symbol: "flag", help: "Due \(Fmt.absoluteDay(due, now: app.clock))"))
        }
        let progress = task.subtaskProgress
        if progress.total > 0 {
            glyphs.append(RowGlyph(id: "steps", text: "\(progress.done)/\(progress.total)",
                                   help: "\(progress.done) of \(progress.total) steps done"))
        }
        if let rule = task.recurrence {
            glyphs.append(RowGlyph(id: "repeat", symbol: "repeat", help: rule.summary))
        }
        if !task.reminders.isEmpty, !task.isCompleted {
            glyphs.append(RowGlyph(id: "reminder", symbol: task.hasAlarm ? "alarm" : "bell",
                                   help: task.hasAlarm ? "Has an alarm" : "Has a reminder"))
        }
        if task.linkedNoteID != nil {
            glyphs.append(RowGlyph(id: "note", symbol: "doc.text", help: "From a note"))
        } else if !task.notes.isEmpty {
            glyphs.append(RowGlyph(id: "note", symbol: "text.alignleft", help: "Has notes"))
        }
        return glyphs
    }

    /// Where it came from, who it's waiting on, and the first tags: shown in compact rows only when they fit.
    private func compactExtras(tagCount: Int) -> some View {
        HStack(spacing: 6) {
            if let source = task.source {
                SourceBadge(source: source)
            }
            TaskRowBadges(task: task)
            if tagCount > 0, !task.tags.isEmpty {
                Text(task.tags.prefix(tagCount).map { "#\($0)" }.joined(separator: " "))
                    .foregroundStyle(Color.ink3)
            }
        }
        .font(.system(size: 11.5, weight: .medium))
        .foregroundStyle(Color.ink2)
        .lineLimit(1)
        .fixedSize()
    }

    /// Plain click, ⌘-click (add or remove), ⇧-click (a range) or double-click (open), read from the click itself.
    private func handleClick() {
        let event = NSApp?.currentEvent
        let flags = event?.modifierFlags ?? NSEvent.modifierFlags
        let kind: AppState.RowClick
        if flags.contains(.command) {
            kind = .toggle
        } else if flags.contains(.shift) {
            kind = .range
        } else if let event, [NSEvent.EventType.leftMouseDown, .leftMouseUp].contains(event.type), event.clickCount >= 2 {
            kind = .open
        } else {
            kind = .plain
        }
        // Clicking a row puts the keyboard on the list (arrows, Return, t / m / w / x), out of any text field.
        if let window = NSApp?.keyWindow, window.firstResponder is NSText {
            window.makeFirstResponder(nil)
        }
        // Clicking the open task closes it, but only once the click can't be the start of a double-click
        // (which keeps it open). Capped so a slow double-click setting doesn't make closing feel stuck.
        app.click(task.id, kind, in: store, closeDelay: min(NSEvent.doubleClickInterval, 0.35))
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
            || task.source != nil || task.waitingOn != nil || task.postponeCount >= 3

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
                if let source = task.source {
                    SourceBadge(source: source)
                        .layoutPriority(1)
                }
                TaskRowBadges(task: task)
                    .layoutPriority(2)
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

/// One of a compact row's detail glyphs: a symbol (or a short count like "1/2") and what it means.
private struct RowGlyph: Identifiable {
    let id: String
    var symbol: String?
    var text: String?
    var help: String
    var tint: Color?
}

private struct RowGlyphView: View {
    let glyph: RowGlyph

    var body: some View {
        Group {
            if let symbol = glyph.symbol {
                Image(systemName: symbol)
            } else {
                Text(glyph.text ?? "").monospacedDigit()
            }
        }
        .foregroundStyle(glyph.tint ?? Color.ink3)
        .help(glyph.help)
    }
}

/// The middle of a compact row, on one line: the title, its detail glyphs, then the extras (source, waiting
/// on, tags). The title always keeps `minTitleWidth` (all of it, when shorter); the glyphs get what's left
/// after that, and the extras whatever remains. Both are ViewThatFits, so each shows the fullest version
/// that fits its room, and nothing ever pushes the date on the right out of the row.
private struct CompactLineLayout: Layout {
    var spacing: CGFloat = 6
    var minTitleWidth: CGFloat = 100

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let line = arrange(proposal.width, subviews)
        return CGSize(width: line.width, height: line.height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let line = arrange(bounds.width, subviews)
        var x = bounds.minX
        for (view, size) in zip(subviews, line.sizes) {
            view.place(at: CGPoint(x: x, y: bounds.midY), anchor: .leading, proposal: ProposedViewSize(size))
            if size.width > 0 { x += size.width + spacing }
        }
    }

    /// Each part's size, and the line's. Without a width (or an infinite one) every part is at its fullest.
    private func arrange(_ proposed: CGFloat?, _ subviews: Subviews) -> (sizes: [CGSize], width: CGFloat, height: CGFloat) {
        guard subviews.count == 3 else { return (subviews.map { _ in .zero }, 0, 0) }
        let title = subviews[0], glyphs = subviews[1], extras = subviews[2]
        let idealTitle = title.sizeThatFits(.unspecified)
        guard let available = proposed, available.isFinite else {
            let sizes = [idealTitle, glyphs.sizeThatFits(.unspecified), extras.sizeThatFits(.unspecified)]
            let shown = sizes.filter { $0.width > 0 }
            let width = shown.reduce(0) { $0 + $1.width } + spacing * CGFloat(max(0, shown.count - 1))
            return (sizes, width, sizes.map(\.height).max() ?? 0)
        }
        let room = max(0, available)
        // The glyphs may use whatever the title's minimum leaves.
        let glyphRoom = max(0, room - min(idealTitle.width, minTitleWidth) - spacing)
        var glyphSize = glyphs.sizeThatFits(ProposedViewSize(width: glyphRoom, height: nil))
        if glyphSize.width > glyphRoom { glyphSize.width = 0 }
        let afterGlyphs = glyphSize.width > 0 ? glyphSize.width + spacing : 0
        let titleWidth = min(idealTitle.width, max(0, room - afterGlyphs))
        let titleSize = CGSize(width: titleWidth, height: title.sizeThatFits(ProposedViewSize(width: titleWidth, height: nil)).height)
        let extrasRoom = max(0, room - titleWidth - afterGlyphs - spacing)
        var extrasSize = extras.sizeThatFits(ProposedViewSize(width: extrasRoom, height: nil))
        if extrasSize.width > extrasRoom { extrasSize.width = 0 }
        let sizes = [titleSize, glyphSize, extrasSize]
        return (sizes, room, sizes.map(\.height).max() ?? 0)
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
    /// Compact rows: a smaller date, and the duration as plain text instead of a pill.
    var compact = false

    var body: some View {
        HStack(spacing: compact ? 6 : Space.sm) {
            if let text = dateText {
                Text(text)
                    .font(.system(size: compact ? 13 : 15, weight: .bold))
                    .tracking(compact ? -0.1 : -0.2)
                    .monospacedDigit()
                    .foregroundStyle(color)
                    .lineLimit(1)
            }
            if let minutes = task.estimateMinutes, !task.isCompleted {
                if compact {
                    Text(Fmt.duration(minutes: minutes))
                        .font(.system(size: 12, weight: .semibold))
                        .monospacedDigit()
                        .foregroundStyle(Color.ink2)
                } else {
                    DurationPill(minutes: minutes)
                }
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
    /// Compact rows: one line, like the tasks around it.
    var compact = false

    var body: some View {
        Group {
            if compact { compactLine } else { regularLine }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, compact ? 6 : 9)
        .enterUp(index)
    }

    private var regularLine: some View {
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
                    Text(whenText)
                        .font(.system(size: 15, weight: .bold))
                        .tracking(-0.2)
                        .monospacedDigit()
                        .foregroundStyle(Color.ink2)
                        .lineLimit(1)
                    if !event.isAllDay {
                        DurationPill(minutes: minutes)
                    }
                }
                .fixedSize()
            }
        }
    }

    private var compactLine: some View {
        HStack(alignment: .center, spacing: 10) {
            Capsule()
                .fill(Color.ink3)
                .frame(width: 3, height: 14)
                .frame(width: 16)
            HStack(spacing: 6) {
                Text(event.title)
                    .font(.system(size: 13.5, weight: .medium))
                    .tracking(-0.1)
                    .foregroundStyle(Color.ink2)
                    .lineLimit(1)
                    .layoutPriority(1)
                // The calendar's name only when it fits whole.
                ViewThatFits(in: .horizontal) {
                    Text(event.calendarName)
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(Color.ink3)
                        .lineLimit(1)
                        .fixedSize()
                    Color.clear.frame(width: 0, height: 0)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: 6) {
                Text(whenText)
                    .font(.system(size: 13, weight: .bold))
                    .tracking(-0.1)
                    .monospacedDigit()
                    .foregroundStyle(Color.ink2)
                    .lineLimit(1)
                if !event.isAllDay {
                    Text(Fmt.duration(minutes: minutes))
                        .font(.system(size: 12, weight: .semibold))
                        .monospacedDigit()
                        .foregroundStyle(Color.ink2)
                }
            }
            .fixedSize()
        }
        .frame(minHeight: 18)
    }

    /// "Mon 5 Oct · 10:00 AM", "… · All day", or "… · Ongoing" for a meeting that started on an earlier day.
    private var whenText: String {
        let date = Fmt.absoluteDay(day)
        if event.isAllDay { return "\(date) · All day" }
        return Calendar.current.isDate(event.start, inSameDayAs: day) ? "\(date) · \(Fmt.time(event.start))" : "\(date) · Ongoing"
    }

    private var minutes: Int { max(1, Int(event.end.timeIntervalSince(event.start) / 60)) }
}

struct TaskContextMenu: View {
    @EnvironmentObject var store: Store
    @EnvironmentObject var app: AppState
    @EnvironmentObject var focus: FocusTimer
    let task: TaskItem
    var inCalendar = false

    var body: some View {
        // Right-clicking one of several selected tasks acts on all of them.
        if app.isMultiSelecting && app.selectedTaskIDs.contains(task.id) {
            selectionItems
        } else {
            taskItems
        }
    }

    @ViewBuilder
    private var selectionItems: some View {
        let count = app.selectedTaskIDs.count
        let open = store.tasks.filter { !$0.isCompleted && app.selectedTaskIDs.contains($0.id) }
        Button(open.isEmpty ? "Mark \(count) as Not Done" : "Mark \(open.count) as Done") {
            app.toggleDone(targets, in: store)
            app.deselectAll()
        }
        Divider()
        // Dates move only on open tasks; done ones keep theirs.
        if !open.isEmpty {
            ForEach(QuickDay.allCases, id: \.self) { day in
                Button(day == .nextWeek ? "Move to Next Monday" : "Move to \(day.label)") {
                    app.move(targets, toDay: day.date(), in: store)
                }
            }
            Button("Remove Dates") { app.clearDates(targets, in: store) }
                .disabled(!open.contains { $0.dueDate != nil || $0.scheduledDate != nil })
        }
        Menu("Priority") {
            ForEach(Priority.allCases.reversed()) { p in
                Button(p.label) { app.setPriority(p, for: targets, in: store) }
            }
        }
        Menu("Move to List") {
            Button("Inbox") { app.setList(nil, for: targets, in: store) }
            ForEach(store.lists) { list in
                Button(list.name) { app.setList(list.id, for: targets, in: store) }
            }
        }
        Divider()
        Button("Copy as Checklist") { app.copyChecklist(targets, in: store) }
        Divider()
        Button("Delete \(count) Tasks", role: .destructive) {
            app.delete(targets, in: store) { app.deselectAll() }
        }
    }

    /// The selected tasks in list order, worked out when a command runs rather than while drawing the menu.
    private var targets: [UUID] { app.actionTargets(in: store) }

    @ViewBuilder
    private var taskItems: some View {
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
            if let copy = store.duplicateTask(task.id) { app.selectOnly(copy.id) }
        }
        Divider()
        Button("Delete", role: .destructive) {
            if app.selectedTaskID == task.id { app.selectedTaskID = nil }
            app.selectedTaskIDs.remove(task.id)
            store.deleteTasks([task.id])
        }
    }
}
