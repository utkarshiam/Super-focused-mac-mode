import MemoryKit
import SwiftUI

/// A new task for the Mac, or one being edited (from a debrief or a spoken task). Essentials up top (title with
/// a mic, date and time, length); reminder, repeat, Do on, list and priority behind More. "Today" and
/// "Tomorrow" are quick-pick actions; every chosen date shows as a real date. Returns the whole task, so the
/// `.task` envelope carries every field.
struct TaskComposer: View {
    /// What the mic does with the words once you stop.
    enum VoiceMode {
        /// New task: with a Gemini key the words are scheduled and added at once (the composer closes and the
        /// result card shows them); without one they fill the fields here.
        case addsTasks
        /// Editing: the words fill the fields (Gemini reads them when there's a key).
        case fillsFields
    }

    let onAdd: (DebriefTask) -> Void
    var heading: String
    var confirmTitle: String
    var voiceMode: VoiceMode
    /// Shows "Remove task" when set (editing).
    var onRemove: (() -> Void)?

    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss

    /// Keeps what the composer doesn't show (id, notes, people, tags, waiting on).
    @State private var base: DebriefTask
    @State private var title: String
    @State private var due: Date?
    @State private var hasTime: Bool
    @State private var time: Date
    @State private var showCalendar = false
    @State private var minutes: Int?
    @State private var customLength = false
    /// nil = the Mac's default, -1 = none, else minutes before.
    @State private var reminder: Int?
    @State private var isAlarm: Bool
    @State private var repeatRule: TaskRepeat?
    @State private var customRepeat = false
    @State private var doOn: Date?
    @State private var showDoOnCalendar = false
    @State private var listName: String?
    @State private var priority: Int
    @State private var showMore: Bool

    @StateObject private var dictation = Dictation()
    @State private var textBeforeDictation = ""
    @State private var reading = false
    @FocusState private var focused: Bool

    init(draft: DebriefTask = DebriefTask(title: ""), heading: String = "New task", confirmTitle: String = "Add",
         expanded: Bool = false, voiceMode: VoiceMode = .addsTasks, onRemove: (() -> Void)? = nil,
         onAdd: @escaping (DebriefTask) -> Void) {
        self.onAdd = onAdd
        self.heading = heading
        self.confirmTitle = confirmTitle
        self.voiceMode = voiceMode
        self.onRemove = onRemove
        _base = State(initialValue: draft)
        _title = State(initialValue: draft.title)
        _due = State(initialValue: draft.dueDate.map { Calendar.current.startOfDay(for: $0) })
        _hasTime = State(initialValue: draft.dueDate != nil && draft.dueHasTime)
        _time = State(initialValue: Self.defaultTime(for: draft))
        _minutes = State(initialValue: draft.estimateMinutes)
        _customLength = State(initialValue: draft.estimateMinutes.map { ![15, 30, 60].contains($0) } ?? false)
        _reminder = State(initialValue: draft.reminderMinutes)
        _isAlarm = State(initialValue: draft.isAlarm)
        _repeatRule = State(initialValue: draft.repeatRule)
        _customRepeat = State(initialValue: draft.repeatRule.map { Self.isCustom($0, due: draft.dueDate) } ?? false)
        _doOn = State(initialValue: draft.scheduledDate)
        _listName = State(initialValue: draft.listName)
        _priority = State(initialValue: draft.priority)
        _showMore = State(initialValue: expanded)
    }

    /// The task's own time, else the next full hour.
    private static func defaultTime(for draft: DebriefTask) -> Date {
        if draft.dueHasTime, let due = draft.dueDate { return due }
        let cal = Calendar.current
        let next = cal.date(byAdding: .hour, value: 1, to: Date()) ?? Date()
        return cal.date(bySetting: .minute, value: 0, of: next) ?? next
    }

    private var trimmed: String { title.trimmingCharacters(in: .whitespacesAndNewlines) }

    /// The due date with the time applied (midnight without one).
    private var resolvedDue: Date? {
        guard let due else { return nil }
        let cal = Calendar.current
        let day = cal.startOfDay(for: due)
        guard hasTime else { return day }
        let parts = cal.dateComponents([.hour, .minute], from: time)
        return cal.date(bySettingHour: parts.hour ?? 9, minute: parts.minute ?? 0, second: 0, of: day)
    }

    private var result: DebriefTask {
        var task = base
        task.title = trimmed
        task.dueDate = resolvedDue
        task.dueHasTime = due != nil && hasTime
        task.estimateMinutes = minutes
        task.reminderMinutes = due == nil ? nil : reminder
        task.isAlarm = due != nil && (reminder ?? -1) >= 0 && isAlarm
        task.repeatRule = repeatRule
        task.scheduledDate = doOn.map { Calendar.current.startOfDay(for: $0) }
        task.listName = listName
        task.priority = priority
        return task
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Space.lg) {
                    titleField
                    Hairline()
                    dueSection
                    Hairline()
                    lengthSection
                    Hairline()
                    moreSection
                    if let onRemove {
                        Button(role: .destructive) {
                            onRemove()
                            dismiss()
                        } label: {
                            Label("Remove task", systemImage: "trash")
                                .font(.system(size: 15, weight: .semibold))
                                .foregroundStyle(Color.dangerText)
                        }
                        .padding(.top, Space.sm)
                    }
                }
                .padding(.horizontal, Space.gutter)
                .padding(.top, Space.sm)
                .padding(.bottom, Space.x3)
            }
            .scrollDismissesKeyboard(.interactively)
            .paperBackground()
            .navigationTitle(heading)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dictation.cancel()
                        dismiss()
                    }
                    .foregroundStyle(Color.ink2)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(confirmTitle) {
                        onAdd(result)
                        dismiss()
                    }
                    .fontWeight(.semibold)
                    .disabled(trimmed.isEmpty || dictation.isActive || reading)
                }
            }
            .onAppear {
                dictation.silenceStop = SpokenTaskCenter.pauseToStop
                dictation.onAutoStop = { words in heard(words) }
                if onRemove == nil, title.isEmpty, !showMore { focused = true }
            }
            .onDisappear { dictation.cancel() }
            .onChange(of: dictation.text) { _, words in
                guard dictation.isActive else { return }
                title = Self.join(textBeforeDictation, words)
            }
            .onChange(of: due) { _, _ in syncRepeatDay() }
        }
    }

    // MARK: Title + mic

    private var titleField: some View {
        VStack(alignment: .leading, spacing: Space.sm) {
            HStack(alignment: .top, spacing: Space.sm) {
                TextField("", text: $title, prompt: Text("Task").foregroundStyle(Color.ink3), axis: .vertical)
                    .font(.system(size: 21, weight: .semibold))
                    .tracking(-0.3)
                    .foregroundStyle(Color.ink)
                    .lineLimit(1...4)
                    .focused($focused)
                    .submitLabel(.done)
                    .padding(.top, 4)
                Button {
                    toggleDictation()
                } label: {
                    Image(systemName: dictation.isActive ? "stop.fill" : "mic")
                        .foregroundStyle(dictation.isActive ? Color.danger : Color.ink)
                }
                .buttonStyle(IconButtonStyle(size: 36))
                .overlay(Circle().strokeBorder(Color.danger.opacity(dictation.isActive ? 0.25 + 0.5 * dictation.level : 0), lineWidth: 2))
                .disabled(reading)
                .accessibilityLabel(dictation.isActive ? "Stop dictating" : "Say the task")
            }
            if dictation.isActive {
                Text("Listening… say what and when. A pause ends it.")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Color.ink2)
            } else if reading {
                HStack(spacing: Space.sm) {
                    ProgressView().controlSize(.small).tint(Color.ink2)
                    Text("Reading the date and time…").font(.system(size: 13, weight: .medium)).foregroundStyle(Color.ink2)
                }
            }
        }
    }

    private func toggleDictation() {
        if dictation.isActive {
            Task { heard(await dictation.stop()) }
            return
        }
        guard !model.isDemo else {
            model.show("Dictation is off in demo mode.")
            return
        }
        focused = false
        textBeforeDictation = title
        Task {
            if let problem = await dictation.start() { model.show(problem) }
        }
    }

    /// After a stop (tap or pause): schedule it, or read it into the fields.
    private func heard(_ words: String) {
        let spoken = Self.join(textBeforeDictation, words).trimmingCharacters(in: .whitespacesAndNewlines)
        title = spoken
        guard !words.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        guard let ai = model.makeAI() else {
            apply(TaskTextParser.draft(spoken), keepTitleIfEmpty: true)
            return
        }
        switch voiceMode {
        case .addsTasks:
            model.spoken.schedule(spoken)
            dismiss()
        case .fillsFields:
            reading = true
            Task {
                let parser = SpokenTaskParser(ai: ai, listNames: model.snapshot?.listNames ?? [],
                                              knownPeople: model.snapshot?.knownPeople ?? [])
                let parsed = (try? await parser.parse(spoken))?.first ?? TaskTextParser.draft(spoken)
                apply(parsed, keepTitleIfEmpty: true)
                reading = false
            }
        }
    }

    /// Fills the fields from a parsed task (the id stays this composer's).
    private func apply(_ t: DebriefTask, keepTitleIfEmpty: Bool) {
        withAnimation(Motion.snappy) {
            if !t.title.isEmpty || !keepTitleIfEmpty { title = t.title }
            if let date = t.dueDate {
                due = Calendar.current.startOfDay(for: date)
                hasTime = t.dueHasTime
                if t.dueHasTime { time = date }
            }
            if let m = t.estimateMinutes {
                minutes = m
                customLength = ![15, 30, 60].contains(m)
            }
            if t.reminderMinutes != nil { reminder = t.reminderMinutes }
            if t.isAlarm { isAlarm = true }
            if let rule = t.repeatRule {
                repeatRule = rule
                customRepeat = Self.isCustom(rule, due: t.dueDate)
            }
            if let day = t.scheduledDate { doOn = day }
            if let list = t.listName { listName = list }
            if t.priority > 0 { priority = t.priority }
            if !t.notes.isEmpty, base.notes.isEmpty { base.notes = t.notes }
            if let waiting = t.waitingOn { base.waitingOn = waiting }
            if !t.tags.isEmpty { base.tags = t.tags }
            if t.repeatRule != nil || t.scheduledDate != nil || t.listName != nil || t.priority > 0 || t.reminderMinutes != nil {
                showMore = true
            }
        }
    }

    private static func join(_ a: String, _ b: String) -> String {
        let a = a.trimmingCharacters(in: .whitespacesAndNewlines), b = b.trimmingCharacters(in: .whitespacesAndNewlines)
        if a.isEmpty { return b }
        if b.isEmpty { return a }
        return a + " " + b
    }

    // MARK: Date and time

    private var dueSection: some View {
        VStack(alignment: .leading, spacing: Space.md) {
            HStack {
                if let resolvedDue {
                    Text("Due \(PhoneFmt.due(resolvedDue, hasTime: hasTime))")
                        .font(.system(size: 16, weight: .bold))
                        .monospacedDigit()
                        .foregroundStyle(Color.ink)
                    Spacer()
                    Button {
                        withAnimation(Motion.snappy) {
                            due = nil
                            hasTime = false
                            showCalendar = false
                        }
                    } label: {
                        Image(systemName: "xmark")
                    }
                    .buttonStyle(IconButtonStyle(size: 30))
                    .accessibilityLabel("No due date")
                } else {
                    Text("No due date").font(.system(size: 16, weight: .medium)).foregroundStyle(Color.ink2)
                    Spacer()
                }
            }
            HStack(spacing: Space.sm) {
                Button("Today") { pick(0) }.buttonStyle(SecondaryPill(height: 34))
                Button("Tomorrow") { pick(1) }.buttonStyle(SecondaryPill(height: 34))
                Button {
                    withAnimation(Motion.snappy) {
                        showCalendar.toggle()
                        if showCalendar && due == nil { due = Calendar.current.startOfDay(for: Date()) }
                    }
                } label: {
                    Label("Date", systemImage: "calendar")
                }
                .buttonStyle(SecondaryPill(height: 34))
            }
            if showCalendar {
                DatePicker("Due date", selection: Binding(get: { due ?? Date() }, set: { due = $0 }),
                           in: Calendar.current.startOfDay(for: Date())..., displayedComponents: .date)
                    .datePickerStyle(.graphical)
                    .labelsHidden()
                    .tint(.ink)
            }
            if due != nil {
                Toggle(isOn: $hasTime.animation(Motion.snappy)) {
                    Text("At a time").font(.system(size: 16, weight: .medium)).foregroundStyle(Color.ink)
                }
                .tint(Color.toggleOn)
                if hasTime {
                    DatePicker("Time", selection: $time, displayedComponents: .hourAndMinute)
                        .font(.system(size: 16, weight: .medium))
                        .foregroundStyle(Color.ink)
                }
            }
        }
    }

    private func pick(_ daysFromNow: Int) {
        let cal = Calendar.current
        withAnimation(Motion.snappy) {
            due = cal.date(byAdding: .day, value: daysFromNow, to: cal.startOfDay(for: Date()))
            showCalendar = false
        }
        Haptics.select()
    }

    // MARK: Length

    private var lengthSection: some View {
        VStack(alignment: .leading, spacing: Space.md) {
            HStack(spacing: Space.sm) {
                Text("Length").font(.system(size: 16, weight: .medium)).foregroundStyle(Color.ink)
                Spacer(minLength: Space.sm)
                ForEach([15, 30, 60], id: \.self) { m in
                    FilterChip(title: PhoneFmt.duration(minutes: m), selected: minutes == m && !customLength) {
                        withAnimation(Motion.snappy) {
                            customLength = false
                            minutes = minutes == m ? nil : m
                        }
                        Haptics.select()
                    }
                }
                FilterChip(title: "Custom", selected: customLength) {
                    withAnimation(Motion.snappy) {
                        customLength.toggle()
                        if customLength, minutes == nil || [15, 30, 60].contains(minutes!) { minutes = 90 }
                        if !customLength { minutes = nil }
                    }
                    Haptics.select()
                }
            }
            if customLength {
                Stepper(value: Binding(get: { minutes ?? 90 }, set: { minutes = $0 }), in: 5...(12 * 60), step: 15) {
                    Text(PhoneFmt.duration(minutes: minutes ?? 90))
                        .font(.system(size: 16, weight: .bold))
                        .monospacedDigit()
                        .foregroundStyle(Color.ink)
                }
            }
        }
    }

    // MARK: More

    private var moreSummary: String? {
        var parts: [String] = []
        if due != nil, let reminder { parts.append(reminder < 0 ? "No reminder" : (isAlarm ? "Alarm " : "") + PhoneFmt.reminderShort(reminder)) }
        if let repeatRule { parts.append(repeatRule.label) }
        if let doOn { parts.append("Do on \(PhoneFmt.day(doOn))") }
        if let listName { parts.append(listName) }
        if priority > 0 { parts.append(Self.priorityName(priority)) }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private var moreSection: some View {
        VStack(alignment: .leading, spacing: Space.xs) {
            Button {
                withAnimation(Motion.snappy) { showMore.toggle() }
            } label: {
                HStack(spacing: Space.sm) {
                    Text("More").font(.system(size: 16, weight: .semibold)).foregroundStyle(Color.ink)
                    if !showMore, let moreSummary {
                        Text(moreSummary)
                            .font(.system(size: 14, weight: .medium))
                            .foregroundStyle(Color.ink2)
                            .lineLimit(1)
                    }
                    Spacer(minLength: Space.sm)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Color.ink3)
                        .rotationEffect(.degrees(showMore ? 180 : 0))
                }
                .frame(minHeight: 36)
                .contentShape(Rectangle())
            }
            .buttonStyle(PressScale(scale: 0.99))
            .accessibilityHint("Reminder, repeat, Do on, list and priority")

            if showMore {
                VStack(spacing: 0) {
                    if due != nil {
                        reminderRow
                        if let reminder, reminder >= 0 {
                            row("Alarm") {
                                Toggle("Alarm", isOn: $isAlarm).labelsHidden().tint(Color.toggleOn)
                            }
                        }
                    }
                    repeatRow
                    if customRepeat { weekdayChips.padding(.bottom, Space.sm) }
                    doOnRow
                    if showDoOnCalendar {
                        DatePicker("Do on", selection: Binding(get: { doOn ?? Date() }, set: { doOn = Calendar.current.startOfDay(for: $0) }),
                                   in: Calendar.current.startOfDay(for: Date())..., displayedComponents: .date)
                            .datePickerStyle(.graphical)
                            .labelsHidden()
                            .tint(.ink)
                    }
                    listRow
                    priorityRow
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
    }

    private func row<Trailing: View>(_ label: String, @ViewBuilder trailing: () -> Trailing) -> some View {
        HStack(spacing: Space.md) {
            Text(label).font(.system(size: 16, weight: .medium)).foregroundStyle(Color.ink)
            Spacer(minLength: Space.sm)
            trailing()
        }
        .frame(minHeight: 46)
    }

    private func menuLabel(_ text: String) -> some View {
        HStack(spacing: 5) {
            Text(text).font(.system(size: 15, weight: .semibold)).foregroundStyle(Color.ink).lineLimit(1)
            Image(systemName: "chevron.up.chevron.down").font(.system(size: 11, weight: .semibold)).foregroundStyle(Color.ink3)
        }
        .padding(.horizontal, 12)
        .frame(height: 34)
        .background(Capsule().fill(Color.fill))
    }

    private var reminderRow: some View {
        row("Reminder") {
            Menu {
                Button("Mac's default") { reminder = nil }
                Button("None") { reminder = -1 }
                Divider()
                ForEach([0, 5, 15, 30, 60], id: \.self) { m in
                    Button(PhoneFmt.reminder(m)) { withAnimation(Motion.snappy) { reminder = m } }
                }
            } label: {
                menuLabel(reminder.map { $0 < 0 ? "None" : PhoneFmt.reminder($0) } ?? "Mac's default")
            }
        }
    }

    // MARK: Repeat

    private var anchorWeekday: Int { Calendar.current.component(.weekday, from: due ?? Date()) }
    private var anchorDayName: String { Calendar(identifier: .gregorian).shortWeekdaySymbols[anchorWeekday - 1] }

    private var repeatRow: some View {
        row("Repeat") {
            Menu {
                Button("Never") { setRepeat(nil) }
                Button("Every day") { setRepeat(TaskRepeat(frequency: .daily)) }
                Button("Every weekday") { setRepeat(TaskRepeat(frequency: .weekly, weekdays: [2, 3, 4, 5, 6])) }
                Button("Every week on \(anchorDayName)") { setRepeat(TaskRepeat(frequency: .weekly, weekdays: [anchorWeekday])) }
                Button("Every 2 weeks on \(anchorDayName)") { setRepeat(TaskRepeat(frequency: .weekly, interval: 2, weekdays: [anchorWeekday])) }
                Button("Every month") { setRepeat(TaskRepeat(frequency: .monthly)) }
                Divider()
                Button("Custom days…") { setRepeat(TaskRepeat(frequency: .weekly, weekdays: repeatRule?.weekdays.isEmpty == false ? repeatRule!.weekdays : [anchorWeekday]), custom: true) }
            } label: {
                menuLabel(repeatRule.map(PhoneFmt.repeatLabel) ?? "Never")
            }
        }
    }

    private func setRepeat(_ rule: TaskRepeat?, custom: Bool = false) {
        withAnimation(Motion.snappy) {
            repeatRule = rule
            customRepeat = custom
            // A repeat starts somewhere: today when there's no date yet.
            if rule != nil, due == nil { due = Calendar.current.startOfDay(for: Date()) }
        }
    }

    /// "Every week on Fri" follows the due date's weekday.
    private func syncRepeatDay() {
        guard !customRepeat, let rule = repeatRule, rule.frequency == .weekly, rule.weekdays.count == 1 else { return }
        repeatRule = TaskRepeat(frequency: .weekly, interval: rule.interval, weekdays: [anchorWeekday])
    }

    private static func isCustom(_ rule: TaskRepeat, due: Date?) -> Bool {
        guard rule.frequency == .weekly, rule.interval == 1 else { return false }
        if rule.weekdays == [2, 3, 4, 5, 6] { return false }
        let weekday = Calendar.current.component(.weekday, from: due ?? Date())
        return !(rule.weekdays.isEmpty || rule.weekdays == [weekday])
    }

    private var weekdayChips: some View {
        let symbols = Calendar(identifier: .gregorian).veryShortWeekdaySymbols
        let order = Array(1...7)
        return HStack(spacing: 6) {
            ForEach(order, id: \.self) { day in
                let on = repeatRule?.weekdays.contains(day) ?? false
                Button {
                    var days = Set(repeatRule?.weekdays ?? [])
                    if on { days.remove(day) } else { days.insert(day) }
                    if days.isEmpty { days.insert(day) }
                    repeatRule = TaskRepeat(frequency: .weekly, weekdays: Array(days))
                    Haptics.select()
                } label: {
                    Text(symbols[day - 1])
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(on ? Color.onPrimary : Color.ink)
                        .frame(maxWidth: .infinity)
                        .frame(height: 36)
                        .background(Circle().fill(on ? Color.primaryFill : Color.fill))
                }
                .buttonStyle(PressScale(scale: 0.92))
                .accessibilityLabel(Calendar(identifier: .gregorian).weekdaySymbols[day - 1])
                .accessibilityAddTraits(on ? .isSelected : [])
            }
        }
    }

    // MARK: Do on, list, priority

    private var doOnRow: some View {
        row("Do on") {
            if let doOn {
                HStack(spacing: Space.sm) {
                    Button {
                        withAnimation(Motion.snappy) { showDoOnCalendar.toggle() }
                    } label: {
                        Text(PhoneFmt.day(doOn))
                            .font(.system(size: 15, weight: .bold))
                            .monospacedDigit()
                            .foregroundStyle(Color.ink)
                            .padding(.horizontal, 12)
                            .frame(height: 34)
                            .background(Capsule().fill(Color.fill))
                    }
                    .buttonStyle(PressScale(scale: 0.95))
                    Button {
                        withAnimation(Motion.snappy) {
                            self.doOn = nil
                            showDoOnCalendar = false
                        }
                    } label: {
                        Image(systemName: "xmark")
                    }
                    .buttonStyle(IconButtonStyle(size: 30))
                    .accessibilityLabel("No Do on day")
                }
            } else {
                Button("Pick a day") {
                    withAnimation(Motion.snappy) {
                        doOn = Calendar.current.startOfDay(for: Date())
                        showDoOnCalendar = true
                    }
                }
                .buttonStyle(SecondaryPill(height: 34))
            }
        }
    }

    private var listChoices: [String] {
        var names = model.snapshot?.listNames ?? []
        if let listName, !names.contains(listName) { names.insert(listName, at: 0) }
        return names
    }

    private var listRow: some View {
        row("List") {
            Menu {
                Button("Inbox") { listName = nil }
                if !listChoices.isEmpty { Divider() }
                ForEach(listChoices, id: \.self) { name in
                    Button(name) { listName = name }
                }
            } label: {
                menuLabel(listName ?? "Inbox")
            }
        }
    }

    static func priorityName(_ value: Int) -> String {
        ["No priority", "Low", "Medium", "High", "Urgent"][max(0, min(4, value))]
    }

    private var priorityRow: some View {
        row("Priority") {
            Menu {
                ForEach((0...4).reversed(), id: \.self) { value in
                    Button(Self.priorityName(value)) { priority = value }
                }
            } label: {
                menuLabel(priority == 0 ? "None" : Self.priorityName(priority))
            }
        }
    }
}
