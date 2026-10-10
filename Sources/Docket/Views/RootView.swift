import SwiftUI

struct RootView: View {
    @EnvironmentObject var store: Store
    @EnvironmentObject var app: AppState
    @EnvironmentObject var focus: FocusTimer
    @EnvironmentObject var calendar: CalendarService

    var body: some View {
        HStack(spacing: 0) {
            if app.sidebarVisible {
                SidebarView()
                    .frame(width: 240)
                    .transition(.move(edge: .leading).combined(with: .opacity))
                Rectangle().fill(Color.hair).frame(width: 1).ignoresSafeArea()
                    .transition(.opacity)
            }
            content
                .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity, alignment: .topLeading)
        }
        .background(Color.paper.ignoresSafeArea())
        .overlay(alignment: .top) { recoveryBanner }
        .overlay(alignment: .bottom) { toast }
        // Confetti only: it never takes a click meant for the window underneath.
        .overlay { CelebrationOverlay().allowsHitTesting(false) }
        .overlay {
            if app.showPalette {
                CommandPalette()
                    .transition(.opacity)
            }
        }
        .animation(Motion.fast, value: app.showPalette)
        .sheet(item: $app.aiPlanner) { request in
            // Sheets don't always inherit the window's environment objects.
            AIPlanSheet(request: request)
                .environmentObject(store)
                .environmentObject(app)
                .environmentObject(focus)
                .environmentObject(calendar)
        }
        .tint(Color.ink)
        .frame(minWidth: 980, minHeight: 600)
    }

    @ViewBuilder private var content: some View {
        switch app.selection {
        case .notes: NotesView()
        case .memory: MemoryView()
        case .insights: InsightsView()
        case .search: SearchView()
        case .suggestions: SuggestionsView()
        default: TasksView()
        }
    }

    @ViewBuilder private var toast: some View {
        if let text = app.toast {
            HStack(spacing: Space.sm) {
                Image(systemName: "checkmark")
                    .font(.system(size: 11, weight: .heavy))
                    .foregroundStyle(Color.onPrimary)
                    .frame(width: 20, height: 20)
                    .background(Circle().fill(Color.primaryFill))
                Text(text)
                    .textStyle(.subheadStrong)
                    .foregroundStyle(Color.ink)
            }
            .padding(.leading, 10)
            .padding(.trailing, 16)
            .frame(height: 44)
            .background(Capsule().fill(Color.raised))
            .overlay(Capsule().strokeBorder(Color.hair))
            .floatShadow(strong: true)
            .padding(.bottom, Space.xxl)
            .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }

    @ViewBuilder private var recoveryBanner: some View {
        if let message = store.loadMessage {
            HStack(alignment: .top, spacing: Space.md) {
                Image(systemName: "exclamationmark.triangle").foregroundStyle(Color.dangerText)
                Text(message).textStyle(.subhead).foregroundStyle(Color.ink)
                Spacer()
                Button("Got it") { store.loadMessage = nil }
                    .buttonStyle(PrimaryPill(height: 30))
            }
            .padding(Space.lg)
            .background(RoundedRectangle(cornerRadius: Radius.xl, style: .continuous).fill(Color.raised))
            .overlay(RoundedRectangle(cornerRadius: Radius.xl, style: .continuous).strokeBorder(Color.hair))
            .floatShadow(strong: true)
            .padding(.top, 40)
            .padding(.horizontal, 80)
        }
    }
}

/// Sits in the title bar next to the window buttons.
struct SidebarToggle: View {
    @EnvironmentObject var app: AppState

    var body: some View {
        Button { app.toggleSidebar() } label: { Image(systemName: "sidebar.left") }
            .buttonStyle(IconButtonStyle(size: 26))
            .help(app.sidebarVisible ? "Hide sidebar (⌃⌘S)" : "Show sidebar (⌃⌘S)")
            .frame(width: 40, height: 28)
            .tint(Color.ink)
    }
}

// MARK: - Sidebar

struct SidebarView: View {
    @EnvironmentObject var store: Store
    @EnvironmentObject var app: AppState
    @EnvironmentObject var focus: FocusTimer
    @ObservedObject private var integrations = Integrations.shared
    @ObservedObject private var memory = MemoryCenter.shared.library
    @State private var editingList: TaskList?
    @State private var listToDelete: TaskList?
    /// The "More" and "Tags" sections start collapsed; the choice is remembered.
    @AppStorage("sidebarMoreExpanded") private var moreExpanded = false
    @AppStorage("sidebarTagsExpanded") private var tagsExpanded = false
    @Namespace private var ns

    /// Rows that live under "More". While one is selected the section stays open.
    private static let moreItems: Set<SidebarItem> = [.important, .all, .completed, .insights]

    private func isTag(_ item: SidebarItem) -> Bool {
        if case .tag = item { return true }
        return false
    }

    var body: some View {
        let overdue = store.overdueCount(now: app.clock)
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center) {
                Text("Docket")
                    .font(.system(size: 22, weight: .heavy))
                    .tracking(-0.8)
                    .foregroundStyle(Color.ink)
                Spacer()
                Button { app.showQuickCapture() } label: { Image(systemName: "bolt") }
                    .buttonStyle(IconButtonStyle(size: 30))
                    .help("Quick Capture (\(Prefs.hotkeyPreset.rawValue))")
            }
            .padding(.leading, 22)
            .padding(.trailing, 14)
            .padding(.top, 40)
            .padding(.bottom, Space.lg)

            SidebarSearchField()
                .padding(.horizontal, Space.md)
                .padding(.bottom, Space.sm)

            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    navRow(.calendar, "Calendar", "calendar", count: store.count(for: .calendar), alert: overdue > 0)
                    navRow(.inbox, "Inbox", "tray", count: store.count(for: .inbox), dropToList: .some(nil))
                    navRow(.waiting, "Waiting", "hourglass", count: store.count(for: .waiting))
                    if integrations.isAnyConnected || integrations.pendingCount > 0 {
                        navRow(.suggestions, "Messages", "tray.and.arrow.down", count: integrations.pendingCount)
                    }
                    navRow(.notes, "Notes", "doc.text", count: store.notes.count)
                    navRow(.memory, "Memory", "brain", count: memory.count)

                    sectionLabel("Lists") {
                        Button {
                            editingList = TaskList(name: "", icon: "list.bullet", sortOrder: -1)
                        } label: { Image(systemName: "plus") }
                            .buttonStyle(IconButtonStyle(size: 22))
                            .help("New list")
                    }
                    ForEach(store.lists) { list in
                        navRow(.list(list.id), list.name, list.icon, count: store.count(for: .list(list.id)), dropToList: .some(list.id))
                            .contextMenu {
                                Button("Edit List…") { editingList = list }
                                Button("Move Up") { store.moveList(list.id, by: -1) }
                                Button("Move Down") { store.moveList(list.id, by: 1) }
                                Divider()
                                Button("Delete List…", role: .destructive) { listToDelete = list }
                            }
                    }

                    let tags = store.allTags
                    if !tags.isEmpty {
                        let showTags = tagsExpanded || isTag(app.selection)
                        disclosureLabel("Tags", count: tags.count, expanded: showTags) { tagsExpanded = !showTags }
                        if showTags {
                            ForEach(tags, id: \.self) { tag in
                                navRow(.tag(tag), tag, "number", count: store.count(for: .tag(tag)))
                            }
                        }
                    }

                    // The views you visit less often, out of the way until asked for.
                    let showMore = moreExpanded || Self.moreItems.contains(app.selection)
                    disclosureLabel("More", count: nil, expanded: showMore) { moreExpanded = !showMore }
                    if showMore {
                        navRow(.important, "Important", "flag", count: store.count(for: .important))
                        navRow(.all, "All tasks", "square.stack", count: nil)
                        navRow(.completed, "Completed", "checkmark.circle", count: nil)
                        navRow(.insights, "Insights", "chart.bar", count: nil)
                    }
                }
                .padding(.horizontal, Space.md)
                .padding(.bottom, Space.lg)
            }

            if focus.isActive {
                FocusMiniCard()
                    .padding(.horizontal, Space.md)
                    .padding(.bottom, Space.md)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }

            Rectangle().fill(Color.hair).frame(height: 1)
            HStack(spacing: Space.sm) {
                Button { app.showSettings() } label: {
                    Label("Settings", systemImage: "gearshape")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Color.ink2)
                }
                .buttonStyle(PressScale())
                Spacer()
                KeyCap(text: "⌘K")
                    .onTapGesture { app.showPalette = true }
                    .help("Jump to anything")
            }
            .padding(.horizontal, 22)
            .frame(height: 48)
        }
        .background(Color.paper)
        .animation(Motion.gentle, value: focus.isActive)
        .animation(Motion.snappy, value: app.selection)
        .sheet(item: $editingList) { list in
            ListEditor(list: list, isNew: list.sortOrder == -1)
        }
        .alert("Delete “\(listToDelete?.name ?? "")”?", isPresented: Binding(get: { listToDelete != nil }, set: { if !$0 { listToDelete = nil } })) {
            Button("Delete", role: .destructive) {
                if let list = listToDelete {
                    if app.selection == .list(list.id) { app.selection = .inbox }
                    store.deleteList(list.id)
                }
                listToDelete = nil
            }
            Button("Cancel", role: .cancel) { listToDelete = nil }
        } message: {
            Text("Its tasks move to the Inbox. You can undo this with ⌘Z.")
        }
    }

    private func sectionLabel<Accessory: View>(_ title: String, @ViewBuilder accessory: () -> Accessory) -> some View {
        HStack {
            Eyebrow(text: title)
            Spacer()
            accessory()
        }
        .padding(.leading, 10)
        .padding(.trailing, 4)
        .padding(.top, Space.xl)
        .padding(.bottom, Space.xs)
    }

    /// A section label that opens and closes its section: the title, a chevron, and (when given) how many it holds.
    private func disclosureLabel(_ title: String, count: Int?, expanded: Bool, toggle: @escaping () -> Void) -> some View {
        Button {
            withAnimation(Motion.snappy) { toggle() }
        } label: {
            HStack(spacing: 6) {
                Eyebrow(text: title)
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(Color.ink3)
                    .rotationEffect(.degrees(expanded ? 90 : 0))
                Spacer()
                if let count {
                    Text("\(count)")
                        .font(.system(size: 12, weight: .semibold))
                        .monospacedDigit()
                        .foregroundStyle(Color.ink3)
                }
            }
            .padding(.leading, 10)
            .padding(.trailing, 10)
            .padding(.top, Space.xl)
            .padding(.bottom, Space.xs)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(expanded ? "Hide \(title)" : "Show \(title)")
        .accessibilityLabel(title)
        .accessibilityValue(expanded ? "Expanded" : "Collapsed")
    }

    /// `dropToList`: nil = not a drop target; .some(nil) = Inbox; .some(id) = that list.
    private func navRow(_ item: SidebarItem, _ title: String, _ icon: String, count: Int?, alert: Bool = false, dropToList: UUID?? = nil) -> some View {
        SidebarRow(item: item, title: title, icon: icon, count: count, alert: alert, dropToList: dropToList, ns: ns)
    }
}

private struct SidebarRow: View {
    @EnvironmentObject var store: Store
    @EnvironmentObject var app: AppState
    let item: SidebarItem
    let title: String
    let icon: String
    let count: Int?
    let alert: Bool
    let dropToList: UUID??
    let ns: Namespace.ID
    @State private var hovering = false
    @State private var dropTarget = false

    var body: some View {
        let selected = app.selection == item
        Button {
            app.selection = item
        } label: {
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .font(.system(size: 14, weight: .medium))
                    .frame(width: 20)
                Text(title)
                    .font(.system(size: 14, weight: selected ? .semibold : .medium))
                    .tracking(-0.1)
                    .lineLimit(1)
                Spacer(minLength: 4)
                if let count, count > 0 {
                    if alert {
                        Text("\(count)")
                            .font(.system(size: 11, weight: .bold))
                            .monospacedDigit()
                            .foregroundStyle(Color.white)
                            .padding(.horizontal, 7)
                            .frame(height: 18)
                            .background(Capsule().fill(Color.danger))
                    } else {
                        Text("\(count)")
                            .font(.system(size: 12, weight: .semibold))
                            .monospacedDigit()
                            .opacity(selected ? 0.75 : 1)
                            .foregroundStyle(selected ? Color.onPrimary : Color.ink3)
                    }
                }
            }
            .foregroundStyle(selected ? Color.onPrimary : Color.ink)
            .padding(.horizontal, 10)
            .frame(height: 34)
            .background {
                if selected {
                    RoundedRectangle(cornerRadius: Radius.sm, style: .continuous)
                        .fill(Color.primaryFill)
                        .matchedGeometryEffect(id: "nav-selection", in: ns)
                } else if dropTarget {
                    RoundedRectangle(cornerRadius: Radius.sm, style: .continuous).fill(Color.fillStrong)
                } else if hovering {
                    RoundedRectangle(cornerRadius: Radius.sm, style: .continuous).fill(Color.pressedTint)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(PressScale(scale: 0.98))
        .onHover { h in withAnimation(Motion.fast) { hovering = h } }
        .modifier(ListDrop(listID: dropToList, title: title, targeted: $dropTarget))
    }
}

/// Drop target for Inbox (listID .some(nil)) and lists (.some(id)); other rows aren't targets at all.
private struct ListDrop: ViewModifier {
    @EnvironmentObject var store: Store
    @EnvironmentObject var app: AppState
    let listID: UUID??
    let title: String
    @Binding var targeted: Bool

    func body(content: Content) -> some View {
        if case .some(let target) = listID {
            content.dropDestination(for: String.self) { items, _ in
                let ids = items.compactMap(UUID.init(uuidString:)).filter { store.task($0) != nil }
                guard !ids.isEmpty else { return false }
                withAnimation(Motion.gentle) {
                    for id in ids { store.mutateTask(id, undo: "Move") { $0.listID = target } }
                }
                Haptics.success()
                app.showToast("Moved to \(title)")
                return true
            } isTargeted: { t in
                withAnimation(Motion.fast) { targeted = t }
            }
        } else {
            content
        }
    }
}

struct ListEditor: View {
    @EnvironmentObject var store: Store
    @EnvironmentObject var app: AppState
    @Environment(\.dismiss) private var dismiss
    @State var list: TaskList
    var isNew: Bool

    private let icons = ["list.bullet", "briefcase", "house", "person.2", "dollarsign.circle", "chart.line.uptrend.xyaxis",
                         "megaphone", "hammer", "airplane", "heart", "book", "cart", "graduationcap", "lightbulb",
                         "target", "building.2", "scalemass", "paintbrush"]

    var body: some View {
        VStack(alignment: .leading, spacing: Space.lg) {
            Text(isNew ? "New list" : "Edit list")
                .textStyle(.title2)
                .foregroundStyle(Color.ink)
            TextField("Name", text: $list.name)
                .textFieldStyle(.plain)
                .font(.system(size: 15, weight: .medium))
                .padding(.horizontal, 12)
                .frame(height: 44)
                .background(RoundedRectangle(cornerRadius: Radius.md, style: .continuous).fill(Color.fill))
                .onSubmit(save)
            LazyVGrid(columns: Array(repeating: GridItem(.fixed(34), spacing: 5.75), count: 9), spacing: 6) {
                ForEach(icons, id: \.self) { icon in
                    let on = list.icon == icon
                    Image(systemName: icon)
                        .font(.system(size: 14, weight: .medium))
                        .frame(width: 34, height: 34)
                        .foregroundStyle(on ? Color.onPrimary : Color.ink)
                        .background(RoundedRectangle(cornerRadius: Radius.sm, style: .continuous).fill(on ? Color.primaryFill : Color.fill))
                        .onTapGesture { withAnimation(Motion.snappy) { list.icon = icon } }
                }
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .buttonStyle(SecondaryPill())
                    .keyboardShortcut(.cancelAction)
                Button(isNew ? "Create list" : "Save", action: save)
                    .buttonStyle(PrimaryPill())
                    .keyboardShortcut(.defaultAction)
                    .disabled(list.name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(Space.xxl)
        .frame(width: 400)
        .background(Color.raised)
    }

    private func save() {
        let name = list.name.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        if isNew {
            let created = store.addList(name: name, color: .gray, icon: list.icon)
            app.selection = .list(created.id)
        } else {
            list.name = name
            store.updateList(list)
        }
        dismiss()
    }
}

/// The running focus session: the one inverted Panel.
struct FocusMiniCard: View {
    @EnvironmentObject var focus: FocusTimer
    @EnvironmentObject var store: Store
    @EnvironmentObject var app: AppState

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            VStack(alignment: .leading, spacing: Space.sm) {
                HStack {
                    Text(focus.isPaused ? "Paused" : "Focusing")
                        .textStyle(.eyebrow)
                        .foregroundStyle(Color.onDark58)
                    Spacer()
                    Button { focus.togglePause() } label: { Image(systemName: focus.isPaused ? "play.fill" : "pause.fill") }
                        .buttonStyle(PressScale(scale: 0.9))
                        .help(focus.isPaused ? "Resume" : "Pause")
                    Button { focus.stop(markDone: false) } label: { Image(systemName: "stop.fill") }
                        .buttonStyle(PressScale(scale: 0.9))
                        .help("Stop and log time")
                }
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(Color.onDark88)
                Text(focus.clock(at: context.date))
                    .font(.system(size: 30, weight: .bold))
                    .tracking(-0.8)
                    .monospacedDigit()
                    .foregroundStyle(Color.white)
                Text(focus.title)
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(Color.onDark58)
                    .lineLimit(1)
                    .onTapGesture { if let id = focus.taskID { app.reveal(task: id, in: store) } }
                if focus.target != nil {
                    GeometryReader { g in
                        ZStack(alignment: .leading) {
                            Capsule().fill(Color.onDarkHair)
                            Capsule().fill(Color.white).frame(width: max(4, g.size.width * focus.progress(at: context.date)))
                        }
                    }
                    .frame(height: 4)
                    .animation(Motion.slow, value: focus.progress(at: context.date))
                }
            }
            .padding(Space.lg)
            .background(RoundedRectangle(cornerRadius: Radius.xl, style: .continuous).fill(Color.panel))
        }
    }
}
