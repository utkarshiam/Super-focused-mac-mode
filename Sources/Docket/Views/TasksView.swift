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

            // Several tasks selected: edit them together. One task: its details.
            let bulk = showsBulkPanel
            let detailID = app.selectedTaskID.flatMap { store.task($0) != nil ? $0 : nil }
            if bulk || detailID != nil {
                Rectangle().fill(Color.hair).frame(width: 1).ignoresSafeArea()
                if bulk {
                    BulkEditPanel()
                        .frame(width: 370)
                        .transition(.asymmetric(insertion: .opacity.combined(with: .offset(x: 16)), removal: .opacity))
                } else if let detailID {
                    TaskDetailView(taskID: detailID)
                        .frame(width: 370)
                        .id(detailID)
                        .transition(.asymmetric(insertion: .opacity.combined(with: .offset(x: 16)), removal: .opacity))
                }
            }
        }
    }

    /// At least two of the selected tasks still exist.
    private var showsBulkPanel: Bool {
        app.isMultiSelecting && store.tasks.lazy.filter { app.selectedTaskIDs.contains($0.id) }.prefix(2).count == 2
    }
}

/// The header's one "⋯" menu: page options first (`extra`), then Compact Rows (same as View ▸ Compact Rows, ⌥⌘C).
struct ViewOptionsMenu<Extra: View>: View {
    @EnvironmentObject var app: AppState
    @ViewBuilder var extra: Extra

    var body: some View {
        Menu {
            extra
            Toggle("Compact Rows", isOn: Binding(
                get: { app.compactRows },
                set: { on in withAnimation(Motion.snappy) { app.compactRows = on } }
            ))
            .keyboardShortcut("c", modifiers: [.command, .option])
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Color.ink)
                .frame(width: 32, height: 32)
        }
        .menuChrome(Circle())
        .help("View options")
        .accessibilityLabel("View options")
    }
}

extension ViewOptionsMenu where Extra == EmptyView {
    init() { self.init { EmptyView() } }
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
                    ViewOptionsMenu {
                        if case .list = app.selection {
                            Toggle("Show Completed Tasks", isOn: Binding(
                                get: { showCompleted },
                                set: { on in withAnimation(Motion.base) { showCompleted = on } }
                            ))
                            Divider()
                        }
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
                    LazyVStack(alignment: .leading, spacing: app.compactRows ? 1 : 2) {
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
                                .padding(.top, app.compactRows ? Space.md : Space.xl)
                                .padding(.bottom, app.compactRows ? Space.xs : Space.sm)
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
        case .waiting: "Waiting"
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
        case .waiting:
            EmptyState(icon: "hourglass", title: "Nothing to chase",
                       message: "When someone else is doing a task, set “Waiting on” in its details and it shows up here.")
        default:
            EmptyState(icon: "checklist", title: "No tasks", message: "Add one with the field above.")
        }
    }
}
