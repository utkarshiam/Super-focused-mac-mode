import MemoryKit
import SwiftUI

/// The Mac's open tasks sorted into overdue, this day, the next seven days and later (only debrief tasks
/// the Mac hasn't listed yet land there).
struct TaskBuckets {
    var overdue: [TaskSnapshot] = []
    var today: [TaskSnapshot] = []
    var upcoming: [TaskSnapshot] = []
    var later: [TaskSnapshot] = []

    var isEmpty: Bool { overdue.isEmpty && today.isEmpty && upcoming.isEmpty && later.isEmpty }

    /// The day a task sits on: the earlier of its plan date and its deadline.
    static func day(of task: TaskSnapshot) -> Date? {
        switch (task.scheduledDate, task.dueDate) {
        case let (s?, d?): min(s, d)
        case let (s?, nil): s
        case let (nil, d?): d
        case (nil, nil): nil
        }
    }

    static func isOverdue(_ task: TaskSnapshot, now: Date, calendar: Calendar = .current) -> Bool {
        guard let due = task.dueDate else { return false }
        return task.dueHasTime ? due < now : due < calendar.startOfDay(for: now)
    }

    static func make(_ tasks: [TaskSnapshot], now: Date = Date(), calendar: Calendar = .current) -> TaskBuckets {
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now))!
        let weekOut = calendar.date(byAdding: .day, value: 8, to: calendar.startOfDay(for: now))!
        var buckets = TaskBuckets()
        for task in tasks {
            if isOverdue(task, now: now, calendar: calendar) {
                buckets.overdue.append(task)
            } else if let day = day(of: task), day >= weekOut {
                buckets.later.append(task)
            } else if let day = day(of: task), day >= tomorrow {
                buckets.upcoming.append(task)
            } else {
                buckets.today.append(task)
            }
        }
        func order(_ a: TaskSnapshot, _ b: TaskSnapshot) -> Bool {
            let da = day(of: a) ?? .distantPast, db = day(of: b) ?? .distantPast
            if !calendar.isDate(da, inSameDayAs: db) { return da < db }
            // Same day: timed first by time, then by priority.
            if a.dueHasTime != b.dueHasTime { return a.dueHasTime }
            if a.dueHasTime, let ta = a.dueDate, let tb = b.dueDate, ta != tb { return ta < tb }
            if a.priority != b.priority { return a.priority > b.priority }
            return a.title.localizedCaseInsensitiveCompare(b.title) == .orderedAscending
        }
        buckets.overdue.sort(by: order)
        buckets.today.sort(by: order)
        buckets.upcoming.sort(by: order)
        buckets.later.sort(by: order)
        return buckets
    }

    /// The bold text on the right of a line: "Mon 5 Oct · 14:00", "Mon 5 Oct". Never "Today".
    static func whenText(_ task: TaskSnapshot, now: Date = Date()) -> String? {
        if let due = task.dueDate { return PhoneFmt.due(due, hasTime: task.dueHasTime, now: now) }
        if let planned = task.scheduledDate { return PhoneFmt.day(planned, now: now) }
        return nil
    }
}

struct TodayView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        NavigationStack {
            Group {
                if model.snapshot == nil {
                    ScrollView {
                        LibraryEmptyState()
                            .padding(.horizontal, Space.gutter)
                            .padding(.top, Space.x4)
                    }
                } else {
                    TimelineView(.everyMinute) { context in
                        list(now: context.date)
                    }
                }
            }
            .paperBackground()
            .navigationTitle("Tasks")
            .toolbar { ToolbarItem(placement: .topBarTrailing) { SettingsButton() } }
            .refreshable { await model.refresh(force: true) }
        }
    }

    private func list(now: Date) -> some View {
        let buckets = TaskBuckets.make(model.openTasks, now: now)
        return List {
            if buckets.isEmpty {
                VStack(alignment: .leading, spacing: Space.sm) {
                    Text("Nothing due").textStyle(.title3).foregroundStyle(Color.ink)
                    Text("Tasks that are overdue, due today or in the next 7 days on your Mac show up here.")
                        .font(.system(size: 15))
                        .foregroundStyle(Color.ink2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.top, Space.lg)
                .plainRow()
            }
            section("Overdue", buckets.overdue, now: now, tone: .dangerText)
            section(PhoneFmt.day(now, now: now), buckets.today, now: now)
            section("Next 7 days", buckets.upcoming, now: now)
            section("Later", buckets.later, now: now)
            if let line = model.lastUpdatedLine {
                Text(line)
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(Color.ink3)
                    .padding(.top, Space.lg)
                    .padding(.bottom, Space.x3)
                    .plainRow()
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .environment(\.defaultMinListRowHeight, 1)
    }

    @ViewBuilder
    private func section(_ title: String, _ tasks: [TaskSnapshot], now: Date, tone: Color = .ink3) -> some View {
        if !tasks.isEmpty {
            Eyebrow(title, color: tone)
                .padding(.top, Space.xl)
                .padding(.bottom, Space.xs)
                .plainRow()
            ForEach(Array(tasks.enumerated()), id: \.element.id) { index, task in
                VStack(spacing: 0) {
                    if index > 0 { Hairline().padding(.leading, 38) }
                    TaskLine(task: task, now: now)
                }
                .plainRow()
                .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                    Button(role: .destructive) {
                        model.deleteTask(task)
                    } label: {
                        Label("Delete", systemImage: "trash")
                    }
                }
            }
        }
    }
}

private extension View {
    /// A list row that looks like the rest of the app: paper, no separators, the screen's gutter.
    func plainRow() -> some View {
        listRowInsets(EdgeInsets(top: 0, leading: Space.gutter, bottom: 0, trailing: Space.gutter))
            .listRowSeparator(.hidden)
            .listRowBackground(Color.paper)
    }
}

private struct TaskLine: View {
    let task: TaskSnapshot
    let now: Date
    @EnvironmentObject private var model: AppModel

    private var done: Bool { model.isCompletedHere(task.id) }

    var body: some View {
        HStack(alignment: .center, spacing: Space.md) {
            Button {
                if done { model.uncomplete(task) } else { model.complete(task) }
            } label: {
                ZStack {
                    Circle()
                        .strokeBorder(done ? Color.primaryFill : (task.priority >= 3 ? Color.ink : Color.ink3), lineWidth: 1.6)
                        .background(Circle().fill(done ? Color.primaryFill : Color.clear))
                    if done {
                        Image(systemName: "checkmark")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(Color.onPrimary)
                    }
                }
                .frame(width: 24, height: 24)
                .frame(width: 32, height: 44)
                .contentShape(Rectangle())
            }
            .buttonStyle(PressScale(scale: 0.88))
            .accessibilityLabel(done ? "Mark not done" : "Mark done")

            VStack(alignment: .leading, spacing: 3) {
                Text(task.title)
                    .font(.system(size: 16, weight: .medium))
                    .tracking(-0.1)
                    .foregroundStyle(done ? Color.ink3 : Color.ink)
                    .strikethrough(done, color: Color.ink3)
                    .lineLimit(2)
                if done {
                    Text("Sent to your Mac").font(.system(size: 12.5, weight: .medium)).foregroundStyle(Color.ink3).lineLimit(1)
                } else if let meta = TaskMeta.text(task, extra: extra, now: now) {
                    meta.font(.system(size: 12.5, weight: .medium)).foregroundStyle(Color.ink3).lineLimit(2)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            VStack(alignment: .trailing, spacing: 4) {
                let tone = done ? Color.ink3 : (TaskBuckets.isOverdue(task, now: now) ? Color.danger : Color.ink)
                if let due = task.dueDate {
                    DueText(date: due, hasTime: task.dueHasTime, color: tone, now: now)
                } else if let planned = task.scheduledDate {
                    DueText(date: planned, hasTime: false, color: tone, now: now)
                }
                if let minutes = task.estimateMinutes, minutes > 0, !done {
                    DurationPill(minutes: minutes)
                }
            }
            .fixedSize()
        }
        .padding(.vertical, 6)
    }

    /// "Just added" (and who it waits on) for a task sent from here the Mac doesn't list yet.
    private var extra: [String] {
        guard model.isJustAdded(task.id) else { return [] }
        var parts = ["Just added"]
        if let waiting = (model.voice.debriefTask(task.id) ?? model.sentTask(task.id))?.waitingOn { parts.append("Waiting on \(waiting)") }
        return parts
    }
}
