import AppKit
import SwiftUI

struct TasksView: View {
    @EnvironmentObject var store: Store
    @EnvironmentObject var app: AppState

    var body: some View {
        HStack(spacing: 0) {
            Group {
                if app.selection == .calendar {
                    CalendarView()
                } else {
                    TaskListPane()
                }
            }
            .frame(minWidth: 368, maxWidth: .infinity, alignment: .leading)

            if let id = app.selectedTaskID, store.task(id) != nil {
                Rectangle().fill(Color.hair).frame(width: 1).ignoresSafeArea()
                TaskDetailView(taskID: id)
                    .frame(width: 370)
                    .id(id)
                    .transition(.asymmetric(insertion: .opacity.combined(with: .offset(x: 16)), removal: .opacity))
            }
        }
    }
}

/// Large title (34pt, tight tracking) with an optional two-tone completion, subtitle and trailing controls.
struct PageHeader<Trailing: View>: View {
    var title: String
    var titleSecondary: String?
    var subtitle: String?
    @ViewBuilder var trailing: Trailing

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .center, spacing: Space.md) {
                titleBlock
                Spacer(minLength: Space.md)
                trailing
            }
            VStack(alignment: .leading, spacing: Space.md) {
                titleBlock
                trailing
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, Space.gutter)
        .padding(.top, Space.lg)
        .padding(.bottom, Space.lg)
    }

    private var titleBlock: some View {
        VStack(alignment: .leading, spacing: 4) {
            (Text(title).foregroundColor(.ink) + Text(titleSecondary.map { " " + $0 } ?? "").foregroundColor(.ink3))
                .textStyle(.largeTitle)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            if let subtitle {
                Text(subtitle)
                    .textStyle(.callout)
                    .foregroundStyle(Color.ink2)
                    .lineLimit(1)
            }
        }
    }
}

extension PageHeader where Trailing == EmptyView {
    init(title: String, titleSecondary: String? = nil, subtitle: String? = nil) {
        self.init(title: title, titleSecondary: titleSecondary, subtitle: subtitle) { EmptyView() }
    }
}

// MARK: - List views (Inbox, Important, All, Completed, lists, tags)

struct TaskListPane: View {
    @EnvironmentObject var store: Store
    @EnvironmentObject var app: AppState
    @AppStorage(Prefs.Key.sortMode) private var sortRaw = SortMode.smart.rawValue
    @AppStorage(Prefs.Key.showCompletedInLists) private var showCompleted = false

    var body: some View {
        let sort = SortMode(rawValue: sortRaw) ?? .smart
        let sections = store.sections(for: app.selection, keeping: app.recentlyCompleted, sort: sort, showCompleted: showCompleted, now: app.clock)

        VStack(alignment: .leading, spacing: 0) {
            PageHeader(title: title, subtitle: subtitle(sections)) {
                HStack(spacing: Space.sm) {
                    if case .list = app.selection {
                        Button(showCompleted ? "Hide done" : "Show done") {
                            withAnimation(Motion.base) { showCompleted.toggle() }
                        }
                        .buttonStyle(SecondaryPill(height: 32))
                    }
                    Menu {
                        Picker("Sort by", selection: $sortRaw) {
                            ForEach(SortMode.allCases) { Text($0.label).tag($0.rawValue) }
                        }
                        .pickerStyle(.inline)
                    } label: {
                        Image(systemName: "arrow.up.arrow.down")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(Color.ink)
                            .frame(width: 32, height: 32)
                    }
                    .menuChrome(Circle())
                    .help("Sort")
                }
            }

            if app.selection != .completed {
                QuickAddField()
                    .padding(.horizontal, Space.gutter)
                    .padding(.bottom, Space.md)
            }

            if sections.isEmpty {
                emptyState
            } else {
                ScrollViewReader { proxy in
                ScrollView {
                    EnterUpWindow {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(sections) { section in
                            if sections.count > 1 || section.style != .normal {
                                HStack(alignment: .firstTextBaseline) {
                                    Eyebrow(text: section.title, color: section.style == .overdue ? .dangerText : .ink3)
                                    Spacer()
                                    if section.style != .done {
                                        Text(section.subtitle).textStyle(.caption).foregroundStyle(Color.ink3)
                                    }
                                }
                                .padding(.horizontal, 14)
                                .padding(.top, Space.xl)
                                .padding(.bottom, Space.sm)
                            }
                            ForEach(Array(section.tasks.enumerated()), id: \.element.id) { i, task in
                                TaskRow(task: task, context: app.selection, index: i)
                            }
                        }
                    }
                    }
                    .padding(.horizontal, Space.gutter - 14)
                    .padding(.bottom, Space.x6)
                }
                .onChange(of: app.selectedTaskID) { id in
                    if let id { withAnimation(Motion.snappy) { proxy.scrollTo(id) } }
                }
                .onAppear {
                    if let id = app.selectedTaskID { proxy.scrollTo(id) }
                }
                }
                .id(app.selection)
            }
        }
        .background(Color.paper)
    }

    private var title: String {
        switch app.selection {
        case .inbox: "Inbox"
        case .important: "Important"
        case .all: "All tasks"
        case .completed: "Completed"
        case .list(let id): store.list(id)?.name ?? "List"
        case .tag(let tag): "#\(tag)"
        default: ""
        }
    }

    private func subtitle(_ sections: [TaskSection]) -> String {
        if app.selection == .completed {
            return "\(sections.reduce(0) { $0 + $1.tasks.count }) finished"
        }
        let open = sections.filter { $0.style != .done }
        let count = open.reduce(0) { $0 + $1.tasks.filter { !$0.isCompleted }.count }
        let minutes = open.reduce(0) { $0 + $1.totalMinutes }
        return Fmt.plural(count, "task") + (minutes > 0 ? " · \(Fmt.duration(minutes: minutes)) of work" : "")
    }

    @ViewBuilder
    private var emptyState: some View {
        switch app.selection {
        case .inbox:
            EmptyState(icon: "tray", title: "Inbox zero", message: "Anything you capture without a list lands here.")
        case .important:
            EmptyState(icon: "flag", title: "Nothing urgent", message: "Mark a task High (!!!) or Urgent (!!!!) to see it here.")
        case .completed:
            EmptyState(icon: "checkmark", title: "Nothing finished yet", message: "Done tasks are kept here as your log.")
        default:
            EmptyState(icon: "checklist", title: "No tasks", message: "Add one with the field above.")
        }
    }
}

// MARK: - Quick add

struct QuickAddField: View {
    @EnvironmentObject var store: Store
    @EnvironmentObject var app: AppState
    /// In the calendar: the day new tasks land on when no date is typed.
    var day: Date?
    @State private var text = ""
    @State private var fieldWidth: CGFloat = 0
    @FocusState private var focused: Bool

    var body: some View {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        VStack(alignment: .leading, spacing: Space.sm) {
            HStack(spacing: 10) {
                Image(systemName: "plus")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(focused ? Color.onPrimary : Color.ink2)
                    .frame(width: 24, height: 24)
                    .background(Circle().fill(focused ? Color.primaryFill : Color.fillStrong))
                    .animation(Motion.fast, value: focused)
                TextField(placeholder, text: $text)
                    .textFieldStyle(.plain)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(Color.ink)
                    .focused($focused)
                    .onSubmit(add)
                    .background(GeometryReader { g in
                        Color.clear
                            .onAppear { fieldWidth = g.size.width }
                            .onChange(of: g.size.width) { fieldWidth = $0 }
                    })
                if !trimmed.isEmpty {
                    KeyCap(text: "↩")
                        .transition(.opacity.combined(with: .scale(scale: 0.8)))
                }
            }
            .padding(.horizontal, 12)
            .frame(height: 46)
            .background(RoundedRectangle(cornerRadius: Radius.md, style: .continuous).fill(Color.fill))
            .overlay(
                RoundedRectangle(cornerRadius: Radius.md, style: .continuous)
                    .strokeBorder(focused ? Color.ink.opacity(0.35) : Color.clear, lineWidth: 1.5)
            )
            .animation(Motion.fast, value: focused)

            if !trimmed.isEmpty {
                ParsedPreview(parsed: parser.parse(text), lists: store.lists)
                    .padding(.leading, 4)
            }
        }
        .animation(Motion.base, value: trimmed.isEmpty)
        .onChange(of: app.focusQuickAdd) { _ in focused = true }
    }

    /// The longest hint that fits the field, so it never gets cut off mid-word.
    private var placeholder: String {
        let example = day == nil ? "Board prep fri 3pm 90m !!! @alarm15" : "Call investor fri 3pm 30m !! @alarm10"
        let options = ["Add a task. Try “\(example)”", "Add a task, e.g. “Call Sam fri 3pm 30m”", "Add a task"]
        let font = NSFont.systemFont(ofSize: 15, weight: .medium)
        return options.first { fieldWidth == 0 || ($0 as NSString).size(withAttributes: [.font: font]).width + 4 <= fieldWidth }
            ?? options[options.count - 1]
    }

    private var parser: QuickParser {
        QuickParser(now: Date(), lists: store.lists, workdayEndMinutes: Prefs.workdayEnd)
    }

    private func add() {
        guard !text.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        var t = TaskItem(parsed: parser.parse(text), defaultReminder: Prefs.defaultReminder, defaultIsAlarm: Prefs.defaultReminderIsAlarm)
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        switch app.selection {
        case .calendar:
            if t.dueDate == nil { t.scheduledDate = max(day ?? today, today) }
        case .list(let id):
            if t.listID == nil { t.listID = id }
        case .tag(let tag):
            if !t.tags.contains(where: { $0.caseInsensitiveCompare(tag) == .orderedSame }) { t.tags.append(tag) }
        case .important:
            if t.priority < .high { t.priority = .high }
        default:
            break
        }
        let added = withAnimation(Motion.gentle) { store.addTask(t) }
        text = ""
        focused = true

        // Say where it went when that isn't obvious from the screen.
        if app.selection == .calendar {
            if let d = store.calendarDay(of: added, today: today), d != cal.startOfDay(for: day ?? today) {
                app.showToast("Added for \(Fmt.absoluteDay(d))")
                app.goTo(day: d)
            }
        } else if !store.sections(for: app.selection, keeping: []).contains(where: { $0.tasks.contains { $0.id == added.id } }) {
            let destination = added.dueDate.map { "due \(Fmt.absoluteDay($0))" } ?? (store.list(added.listID)?.name ?? "Inbox")
            app.showToast("Added. \(destination.prefix(1).uppercased() + destination.dropFirst()).")
        }
    }
}
