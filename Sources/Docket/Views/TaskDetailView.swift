import SwiftUI

struct TaskDetailView: View {
    @EnvironmentObject var store: Store
    @EnvironmentObject var app: AppState
    @EnvironmentObject var focus: FocusTimer
    let taskID: UUID

    @State private var newSubtask = ""
    @State private var newTag = ""
    @State private var showCustomRepeat = false
    @State private var showCustomReminder = false
    @State private var showDuePicker = false
    @State private var customReminderDate: Date?
    @State private var customReminderAlarm = false

    var body: some View {
        let binding = store.binding(forTask: taskID)
        let task = binding.wrappedValue

        ScrollView {
            VStack(alignment: .leading, spacing: Space.xl) {
                HStack(alignment: .top, spacing: Space.md) {
                    CheckCircle(done: task.isCompleted, priority: task.priority, size: 26) {
                        app.toggle(taskID, in: store)
                    }
                    .padding(.top, 2)
                    TextField("Title", text: binding.title, axis: .vertical)
                        .textFieldStyle(.plain)
                        .font(.system(size: 22, weight: .bold))
                        .tracking(-0.4)
                        .foregroundStyle(Color.ink)
                        .lineLimit(1...5)
                    Button { withAnimation(Motion.sheet) { app.selectedTaskID = nil } } label: { Image(systemName: "xmark") }
                        .buttonStyle(IconButtonStyle(size: 28, filled: true))
                        .help("Close")
                }

                whenHero(task, binding)
                SlipNudge(taskID: taskID)

                TextField("Add notes", text: binding.notes, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(.system(size: 14))
                    .foregroundStyle(Color.bodyText)
                    .lineLimit(2...14)
                    .padding(Space.md)
                    .background(RoundedRectangle(cornerRadius: Radius.md, style: .continuous).fill(Color.fill))

                timeSection(task, binding)
                scheduleSection(task, binding)
                remindersSection(task, binding)
                detailsSection(task, binding)
                checklistSection(task, binding)

                SourceLinkButton(taskID: taskID)
                if let noteID = task.linkedNoteID, let note = store.note(noteID) {
                    Button { app.reveal(note: noteID) } label: {
                        Label("Open note: \(note.title)", systemImage: "doc.text")
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    .buttonStyle(SecondaryPill(truncates: true))
                    .help(note.title)
                }

                footer(task)
            }
            .padding(Space.xl)
        }
        .background(Color.paper)
    }

    // MARK: When (the one Panel)

    @ViewBuilder
    private func whenHero(_ task: TaskItem, _ binding: Binding<TaskItem>) -> some View {
        let now = app.clock
        Button { showDuePicker = true } label: {
            Panel {
                HStack(alignment: .center) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(task.dueDate == nil ? "No deadline" : (task.isOverdue(now: now) ? "Overdue" : "Due"))
                            .textStyle(.eyebrow)
                            .foregroundStyle(task.isOverdue(now: now) ? Color(nsColor: Palette.dangerFg) : Color.onDark58)
                        if let due = task.dueDate {
                            if task.dueHasTime {
                                BigTime(date: due, size: 34, color: .white)
                            } else {
                                Text(Fmt.absoluteDay(due, now: now))
                                    .font(.system(size: 34, weight: .bold))
                                    .tracking(-0.8)
                                    .foregroundStyle(Color.white)
                            }
                            Group {
                                if task.dueHasTime {
                                    ViewThatFits(in: .horizontal) {
                                        Text("\(Fmt.longDay(due)) · \(relative(due, now: now))").lineLimit(1)
                                        VStack(alignment: .leading, spacing: 1) {
                                            Text(Fmt.longDay(due))
                                            Text(relative(due, now: now))
                                        }
                                    }
                                } else {
                                    Text(Fmt.longDay(due))
                                }
                            }
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(Color.onDark58)
                        } else {
                            Text("Set a date")
                                .font(.system(size: 26, weight: .bold))
                                .tracking(-0.6)
                                .foregroundStyle(Color.white)
                        }
                    }
                    .layoutPriority(1)
                    Spacer()
                    if let est = task.estimateMinutes {
                        VStack(alignment: .trailing, spacing: 4) {
                            Text("Takes").textStyle(.eyebrow).foregroundStyle(Color.onDark58)
                            Text(Fmt.duration(minutes: est))
                                .font(.system(size: 22, weight: .bold))
                                .tracking(-0.4)
                                .monospacedDigit()
                                .foregroundStyle(Color.white)
                        }
                    }
                }
            }
        }
        .buttonStyle(PressScale(scale: 0.985))
        .popover(isPresented: $showDuePicker, arrowEdge: .bottom) {
            DatePopover(date: binding.dueDate, hasTime: binding.dueHasTime, allowsTime: true, title: "Deadline", close: { showDuePicker = false })
        }
        .help("Change the deadline")
    }

    private func relative(_ date: Date, now: Date) -> String {
        let minutes = Int(date.timeIntervalSince(now) / 60)
        if abs(minutes) < 60 { return minutes >= 0 ? "in \(minutes)m" : "\(-minutes)m ago" }
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .full
        return f.localizedString(for: date, relativeTo: now)
    }

    // MARK: Time & focus

    @ViewBuilder
    private func timeSection(_ task: TaskItem, _ binding: Binding<TaskItem>) -> some View {
        DetailSection("Time") {
            DetailRow(icon: "hourglass", label: "Estimate") {
                Menu {
                    Button("No estimate") { binding.wrappedValue.estimateMinutes = nil }
                    Divider()
                    ForEach([5, 10, 15, 20, 30, 45, 60, 90, 120, 180, 240, 360, 480], id: \.self) { m in
                        Button(Fmt.duration(minutes: m)) { binding.wrappedValue.estimateMinutes = m }
                    }
                } label: {
                    ValueLabel(task.estimateMinutes.map { Fmt.duration(minutes: $0) } ?? "None", muted: task.estimateMinutes == nil)
                        .padding(.horizontal, 6)
                        .frame(height: 26)
                }
                .menuChrome(RoundedRectangle(cornerRadius: Radius.xs, style: .continuous), fill: .clear, hoverFill: .pressedTint)
                .padding(.trailing, -6)
                if let est = task.estimateMinutes {
                    Button { withAnimation(Motion.snappy) { binding.wrappedValue.estimateMinutes = max(5, est - 5) } } label: { Image(systemName: "minus") }
                        .buttonStyle(IconButtonStyle(size: 24, filled: true))
                        .disabled(est <= 5)
                        .help("5 minutes less")
                    Button { withAnimation(Motion.snappy) { binding.wrappedValue.estimateMinutes = est + 5 } } label: { Image(systemName: "plus") }
                        .buttonStyle(IconButtonStyle(size: 24, filled: true))
                        .help("5 minutes more")
                }
            }
            if task.trackedSeconds >= 60 {
                DetailRow(icon: "timer", label: "Spent") {
                    ValueLabel(Fmt.duration(seconds: task.trackedSeconds))
                }
            }
            if focus.taskID == taskID {
                TimelineView(.periodic(from: .now, by: 1)) { ctx in
                    HStack(spacing: Space.md) {
                        Text(focus.clock(at: ctx.date))
                            .font(.system(size: 22, weight: .bold))
                            .tracking(-0.4)
                            .monospacedDigit()
                            .foregroundStyle(Color.ink)
                        Spacer()
                        Button { focus.togglePause() } label: { Image(systemName: focus.isPaused ? "play.fill" : "pause.fill") }
                            .buttonStyle(IconButtonStyle(filled: true))
                        Button("Done") { focus.stop(markDone: true) }
                            .buttonStyle(PrimaryPill(height: 32))
                        Button { focus.stop(markDone: false) } label: { Image(systemName: "stop.fill") }
                            .buttonStyle(IconButtonStyle(filled: true))
                            .help("Stop and log time")
                    }
                    .padding(.horizontal, Space.md)
                    .padding(.vertical, 10)
                }
            } else if !task.isCompleted {
                HStack(spacing: Space.sm) {
                    let minutes = task.remainingMinutes > 0 ? task.remainingMinutes : Prefs.focusMinutes
                    Button { focus.start(taskID: taskID, minutes: minutes) } label: {
                        Label("Focus \(Fmt.duration(minutes: minutes))", systemImage: "play.fill")
                    }
                    .buttonStyle(PrimaryPill(height: 32))
                    Button("25m") { focus.start(taskID: taskID, minutes: 25) }
                        .buttonStyle(SecondaryPill(height: 32))
                    Button { focus.start(taskID: taskID, minutes: nil) } label: { Image(systemName: "stopwatch") }
                        .buttonStyle(IconButtonStyle(filled: true))
                        .help("Stopwatch: count up with no time limit")
                }
                .padding(.horizontal, Space.md)
                .padding(.vertical, 10)
            }
        }
    }

    // MARK: Schedule

    @ViewBuilder
    private func scheduleSection(_ task: TaskItem, _ binding: Binding<TaskItem>) -> some View {
        DetailSection("Schedule") {
            DetailRow(icon: "flag.checkered", label: "Deadline") {
                DateChooser(date: binding.dueDate, hasTime: binding.dueHasTime, allowsTime: true, placeholder: "None", title: "Deadline")
            }
            DetailRow(icon: "sun.max", label: "Do on") {
                DateChooser(date: binding.scheduledDate, hasTime: .constant(false), allowsTime: false, placeholder: "Anytime", title: "Do on")
            }
            DetailRow(icon: "repeat", label: "Repeat") {
                Menu {
                    Button("Never") { setRecurrence(nil, binding) }
                    Divider()
                    Button("Every day") { setRecurrence(.daily, binding) }
                    Button("Every weekday") { setRecurrence(.weekdaysOnly, binding) }
                    Button("Every week") { setRecurrence(weeklyOnDueDay(task), binding) }
                    Button("Every 2 weeks") { setRecurrence(Recurrence(frequency: .weekly, interval: 2), binding) }
                    Button("Every month") { setRecurrence(.monthly, binding) }
                    Button("Every year") { setRecurrence(.yearly, binding) }
                    Divider()
                    Button("Custom…") { showCustomRepeat = true }
                } label: {
                    ValueLabel(task.recurrence?.summary ?? "Never", muted: task.recurrence == nil)
                        .padding(.horizontal, 6)
                        .frame(height: 26)
                }
                .menuChrome(RoundedRectangle(cornerRadius: Radius.xs, style: .continuous), fill: .clear, hoverFill: .pressedTint, truncates: true)
                .padding(.trailing, -6)
                .help(task.recurrence?.summary ?? "Doesn't repeat")
                .popover(isPresented: $showCustomRepeat) {
                    CustomRepeatEditor(initial: task.recurrence ?? .weekly) { setRecurrence($0, binding) }
                }
            }
        }
    }

    private func weeklyOnDueDay(_ task: TaskItem) -> Recurrence {
        let day = Calendar.current.component(.weekday, from: task.dueDate ?? Date())
        return Recurrence(frequency: .weekly, weekdays: [day])
    }

    private func setRecurrence(_ r: Recurrence?, _ binding: Binding<TaskItem>) {
        var t = binding.wrappedValue
        t.recurrence = r
        if let r, t.dueDate == nil {
            t.dueDate = r.firstOccurrence(onOrAfter: Date())
            t.dueHasTime = false
        }
        binding.wrappedValue = t
    }

    // MARK: Reminders

    @ViewBuilder
    private func remindersSection(_ task: TaskItem, _ binding: Binding<TaskItem>) -> some View {
        DetailSection("Reminders and alarms") {
            ForEach(task.reminders) { r in
                let fire = r.fireDate(for: task, allDayHour: Prefs.allDayHour)
                HStack(spacing: Space.md) {
                    Button {
                        if let i = binding.wrappedValue.reminders.firstIndex(where: { $0.id == r.id }) {
                            withAnimation(Motion.snappy) { binding.wrappedValue.reminders[i].isAlarm.toggle() }
                        }
                    } label: {
                        Image(systemName: r.isAlarm ? "alarm.fill" : "bell.fill")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(r.isAlarm ? Color.onPrimary : Color.ink)
                            .frame(width: 28, height: 28)
                            .background(Circle().fill(r.isAlarm ? Color.primaryFill : Color.fill))
                    }
                    .buttonStyle(PressScale(scale: 0.9))
                    .help(r.isAlarm ? "Alarm. Click to make it a quiet notification" : "Notification. Click to make it a loud alarm")
                    VStack(alignment: .leading, spacing: 2) {
                        let kind = r.isAlarm ? "Alarm" : "Reminder"
                        Text((r.isSnooze ? "snoozed" : r.describe(for: task)).map { "\(kind) · \($0)" } ?? kind)
                            .textStyle(.subheadStrong)
                            .foregroundStyle(Color.ink)
                        if let fire {
                            Text(Fmt.dateTime(fire))
                                .textStyle(.caption)
                                .foregroundStyle(fire < Date() ? Color.dangerText : Color.ink2)
                        } else {
                            Text("Needs a deadline").textStyle(.caption).foregroundStyle(Color.dangerText)
                        }
                    }
                    Spacer()
                    Button {
                        withAnimation(Motion.base) { binding.wrappedValue.reminders.removeAll { $0.id == r.id } }
                    } label: { Image(systemName: "xmark") }
                        .buttonStyle(IconButtonStyle(size: 24))
                }
                .padding(.horizontal, Space.md)
                .padding(.vertical, 8)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }

            HStack(spacing: Space.sm) {
                addReminderMenu(task, binding, alarm: false)
                addReminderMenu(task, binding, alarm: true)
                Spacer()
            }
            .padding(.horizontal, Space.md)
            .padding(.vertical, 10)
            .popover(isPresented: $showCustomReminder, arrowEdge: .bottom) {
                DatePopover(date: $customReminderDate, hasTime: .constant(true), allowsTime: true,
                            title: customReminderAlarm ? "Alarm at" : "Remind me at", timeRequired: true,
                            confirmLabel: customReminderAlarm ? "Add alarm" : "Add reminder",
                            close: { showCustomReminder = false }) {
                    guard let when = customReminderDate else { return }
                    withAnimation(Motion.base) {
                        binding.wrappedValue.reminders.append(Reminder(trigger: .absolute(when), isAlarm: customReminderAlarm))
                    }
                }
            }
        }
    }

    private func addReminderMenu(_ task: TaskItem, _ binding: Binding<TaskItem>, alarm: Bool) -> some View {
        Menu {
            if task.dueDate != nil {
                Section("Before the deadline") {
                    ForEach([0, 5, 10, 15, 30, 60, 120, 1440], id: \.self) { m in
                        Button(m == 0 ? (task.dueHasTime ? "At the deadline" : "On the day (\(Prefs.allDayHour):00)") : "\(Fmt.duration(minutes: m)) before") {
                            withAnimation(Motion.base) {
                                binding.wrappedValue.reminders.append(Reminder(trigger: .beforeDue(minutes: m), isAlarm: alarm))
                            }
                        }
                    }
                }
            }
            Section("At a time") {
                Button("In 10 minutes") { addAbsolute(Date().addingTimeInterval(600), alarm, binding) }
                Button("In 1 hour") { addAbsolute(Date().addingTimeInterval(3600), alarm, binding) }
                Button("This evening, 18:00") { addAbsolute(todayAt(18), alarm, binding) }
                Button("Tomorrow morning, 9:00") { addAbsolute(todayAt(9, plusDays: 1), alarm, binding) }
                Button("Custom…") {
                    customReminderAlarm = alarm
                    // Start at the next whole hour.
                    let cal = Calendar.current
                    let next = cal.date(byAdding: .hour, value: 1, to: Date())!
                    customReminderDate = cal.date(bySettingHour: cal.component(.hour, from: next), minute: 0, second: 0, of: next)
                    showCustomReminder = true
                }
            }
        } label: {
            Label(alarm ? "Alarm" : "Reminder", systemImage: "plus")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Color.ink)
                .padding(.horizontal, 12)
                .frame(height: 30)
        }
        .menuChrome(Capsule())
    }

    private func todayAt(_ hour: Int, plusDays: Int = 0) -> Date {
        let cal = Calendar.current
        let day = cal.date(byAdding: .day, value: plusDays, to: Date())!
        var d = cal.date(bySettingHour: hour, minute: 0, second: 0, of: day)!
        if d < Date() { d = cal.date(byAdding: .day, value: 1, to: d)! }
        return d
    }

    private func addAbsolute(_ date: Date, _ alarm: Bool, _ binding: Binding<TaskItem>) {
        withAnimation(Motion.base) {
            binding.wrappedValue.reminders.append(Reminder(trigger: .absolute(date), isAlarm: alarm))
        }
    }

    // MARK: Details

    @ViewBuilder
    private func detailsSection(_ task: TaskItem, _ binding: Binding<TaskItem>) -> some View {
        DetailSection("Details") {
            DetailRow(icon: "flag", label: "Priority") {
                Menu {
                    ForEach(Priority.allCases.reversed()) { p in
                        Button(p.label) { binding.wrappedValue.priority = p }
                    }
                } label: {
                    Text(task.priority.label)
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundStyle(task.priority.tone?.fg ?? (task.priority == .none ? Color.ink3 : Color.ink))
                        .padding(.horizontal, task.priority.tone == nil ? 0 : 9)
                        .frame(height: 24)
                }
                .menuChrome(Capsule(), fill: task.priority.tone?.bg ?? .clear, hoverFill: task.priority.tone?.border ?? .pressedTint)
            }
            DetailRow(icon: store.list(task.listID)?.icon ?? "tray", label: "List") {
                Menu {
                    Button("Inbox") { binding.wrappedValue.listID = nil }
                    ForEach(store.lists) { list in
                        Button(list.name) { binding.wrappedValue.listID = list.id }
                    }
                } label: {
                    ValueLabel(store.list(task.listID)?.name ?? "Inbox")
                        .padding(.horizontal, 6)
                        .frame(height: 26)
                }
                .menuChrome(RoundedRectangle(cornerRadius: Radius.xs, style: .continuous), fill: .clear, hoverFill: .pressedTint, truncates: true)
                .padding(.trailing, -6)
                .help(store.list(task.listID)?.name ?? "Inbox")
            }
            DelegateRow(taskID: taskID)
            VStack(alignment: .leading, spacing: Space.sm) {
                HStack(alignment: .firstTextBaseline, spacing: Space.md) {
                    Image(systemName: "number")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Color.ink2)
                        .frame(width: 18)
                    Text("Tags").textStyle(.subhead).foregroundStyle(Color.ink2).lineLimit(1).fixedSize()
                    TextField("Add tag", text: $newTag)
                        .textFieldStyle(.plain)
                        .font(.system(size: 13, weight: .medium))
                        .multilineTextAlignment(.trailing)
                        .onSubmit {
                            let tag = newTag.trimmingCharacters(in: CharacterSet(charactersIn: "# ")).replacingOccurrences(of: " ", with: "-")
                            if !tag.isEmpty, !binding.wrappedValue.tags.contains(tag) {
                                withAnimation(Motion.base) { binding.wrappedValue.tags.append(tag) }
                            }
                            newTag = ""
                        }
                }
                // Chips get the row's full width under the label and wrap as needed.
                if !task.tags.isEmpty {
                    FlowLayout(spacing: 4, lineSpacing: 6) {
                        ForEach(task.tags, id: \.self) { tag in
                            HStack(spacing: 4) {
                                Text("#\(tag)").lineLimit(1).truncationMode(.middle)
                                Button { withAnimation(Motion.base) { binding.wrappedValue.tags.removeAll { $0 == tag } } } label: {
                                    Image(systemName: "xmark").font(.system(size: 8, weight: .bold))
                                        .padding(6).contentShape(Rectangle()).padding(-6)
                                }
                                .buttonStyle(.plain)
                                .help("Remove #\(tag)")
                            }
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(Color.ink)
                            .padding(.horizontal, 9)
                            .frame(height: 24)
                            .background(Capsule().fill(Color.fill))
                        }
                    }
                    .padding(.leading, 18 + Space.md)
                }
            }
            .padding(.horizontal, Space.md)
            .padding(.vertical, 12)
        }
    }

    // MARK: Checklist

    @ViewBuilder
    private func checklistSection(_ task: TaskItem, _ binding: Binding<TaskItem>) -> some View {
        DetailSection(task.subtasks.isEmpty ? "Checklist" : "Checklist · \(task.subtaskProgress.done) of \(task.subtasks.count)") {
            ForEach(binding.subtasks) { $sub in
                HStack(spacing: Space.md) {
                    CheckCircle(done: sub.done, priority: .none, size: 18) {
                        withAnimation(Motion.snappy) { sub.done.toggle() }
                    }
                    TextField("", text: $sub.title)
                        .textFieldStyle(.plain)
                        .font(.system(size: 14, weight: .medium))
                        .strikethrough(sub.done, color: .ink3)
                        .foregroundStyle(sub.done ? Color.ink3 : Color.ink)
                    Button {
                        withAnimation(Motion.base) { binding.wrappedValue.subtasks.removeAll { $0.id == sub.id } }
                    } label: { Image(systemName: "minus") }
                        .buttonStyle(IconButtonStyle(size: 22))
                }
                .padding(.horizontal, Space.md)
                .padding(.vertical, 8)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
            HStack(spacing: Space.md) {
                Image(systemName: "plus")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(Color.ink2)
                    .frame(width: 18)
                TextField("Add a step", text: $newSubtask)
                    .textFieldStyle(.plain)
                    .font(.system(size: 14, weight: .medium))
                    .onSubmit {
                        let title = newSubtask.trimmingCharacters(in: .whitespaces)
                        guard !title.isEmpty else { return }
                        withAnimation(Motion.base) { binding.wrappedValue.subtasks.append(Subtask(title: title)) }
                        newSubtask = ""
                    }
            }
            .padding(.horizontal, Space.md)
            .padding(.vertical, 12)
            AIBreakdownRow(taskID: taskID)
        }
    }

    // MARK: Footer

    private func footer(_ task: TaskItem) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("Created \(Fmt.dateTime(task.createdAt))")
                if let done = task.completedAt { Text("Completed \(Fmt.dateTime(done))") }
            }
            .textStyle(.caption)
            .foregroundStyle(Color.ink3)
            Spacer()
            Button(role: .destructive) {
                app.selectedTaskID = nil
                store.deleteTasks([taskID])
            } label: {
                Label("Delete", systemImage: "trash")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color.dangerText)
            }
            .buttonStyle(PressScale())
        }
    }
}

// MARK: - Building blocks

/// Eyebrow over a hairline card of rows.
struct DetailSection<Content: View>: View {
    var title: String
    @ViewBuilder var content: Content

    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Space.sm) {
            Eyebrow(text: title)
                .padding(.leading, 4)
            VStack(alignment: .leading, spacing: 0) {
                content
            }
            .hairlineCard(radius: Radius.lg)
        }
    }
}

/// Label on the left, value on the right, inside a DetailSection.
struct DetailRow<Value: View>: View {
    var icon: String
    var label: String
    @ViewBuilder var value: Value

    var body: some View {
        HStack(spacing: Space.md) {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Color.ink2)
                .frame(width: 18)
            Text(label)
                .textStyle(.subhead)
                .foregroundStyle(Color.ink2)
                .lineLimit(1)
                .fixedSize()
            Spacer(minLength: Space.sm)
            value
        }
        .padding(.horizontal, Space.md)
        .frame(minHeight: 44)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Color.hair).frame(height: 1).padding(.leading, 42)
        }
    }
}

/// A row's value: semibold ink (or ink3 when empty).
struct ValueLabel: View {
    var text: String
    var muted = false

    init(_ text: String, muted: Bool = false) {
        self.text = text
        self.muted = muted
    }

    var body: some View {
        Text(text)
            .font(.system(size: 13.5, weight: .semibold))
            .foregroundStyle(muted ? Color.ink3 : Color.ink)
            .lineLimit(1)
    }
}

/// Shows a date; opens a calendar popover with quick picks.
struct DateChooser: View {
    @Binding var date: Date?
    @Binding var hasTime: Bool
    var allowsTime: Bool
    var placeholder: String
    var title: String?
    @State private var open = false

    init(date: Binding<Date?>, hasTime: Binding<Bool>, allowsTime: Bool, placeholder: String, title: String? = nil) {
        _date = date
        _hasTime = hasTime
        self.allowsTime = allowsTime
        self.placeholder = placeholder
        self.title = title
    }

    var body: some View {
        Button {
            open = true
        } label: {
            Text(date.map { Fmt.absoluteDay($0) + (hasTime && allowsTime ? " · \(Fmt.time($0))" : "") } ?? placeholder)
                .font(.system(size: 13.5, weight: .semibold))
                .foregroundStyle(date == nil ? Color.ink3 : (isOverdue ? Color.dangerText : Color.ink))
                .padding(.horizontal, 6)
                .frame(height: 26)
                .hoverHighlight(cornerRadius: Radius.xs)
        }
        .buttonStyle(PressScale())
        .padding(.trailing, -6)
        .popover(isPresented: $open, arrowEdge: .bottom) {
            DatePopover(date: $date, hasTime: $hasTime, allowsTime: allowsTime, title: title, close: { open = false })
        }
    }

    private var isOverdue: Bool {
        guard let date else { return false }
        return hasTime && allowsTime ? date < Date() : Calendar.current.startOfDay(for: date) < Calendar.current.startOfDay(for: Date())
    }
}

/// Lays chips out left to right at their natural width and starts a new line when the next one
/// doesn't fit. A chip wider than the whole row is squeezed to the row so it truncates.
struct FlowLayout: Layout {
    var spacing: CGFloat = 4
    var lineSpacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        arrange(width: proposal.width, subviews).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for (view, frame) in zip(subviews, arrange(width: bounds.width, subviews).frames) {
            view.place(at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY), proposal: ProposedViewSize(frame.size))
        }
    }

    private func arrange(width: CGFloat?, _ subviews: Subviews) -> (frames: [CGRect], size: CGSize) {
        let maxWidth = width ?? .infinity
        var frames: [CGRect] = []
        var x: CGFloat = 0, y: CGFloat = 0, lineHeight: CGFloat = 0, widest: CGFloat = 0
        for view in subviews {
            var size = view.sizeThatFits(.unspecified)
            if size.width > maxWidth {
                size = view.sizeThatFits(ProposedViewSize(width: maxWidth, height: size.height))
                size.width = min(size.width, maxWidth)
            }
            if x > 0, x + size.width > maxWidth {
                x = 0
                y += lineHeight + lineSpacing
                lineHeight = 0
            }
            frames.append(CGRect(origin: CGPoint(x: x, y: y), size: size))
            widest = max(widest, x + size.width)
            x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
        }
        return (frames, CGSize(width: widest, height: frames.isEmpty ? 0 : y + lineHeight))
    }
}
