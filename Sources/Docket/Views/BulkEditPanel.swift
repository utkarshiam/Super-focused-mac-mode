import AppKit
import SwiftUI

/// The right-hand panel when two or more tasks are selected: change them all at once. Every change is a
/// single undo step and says what it did in a toast; keys that do the same from the list show as keycaps.
struct BulkEditPanel: View {
    @EnvironmentObject var store: Store
    @EnvironmentObject var app: AppState
    @State private var pickingFromHero = false
    @State private var pickingFromTile = false
    @State private var pickedDay: Date?
    @State private var newTag = ""
    @State private var waitingOn = ""

    init() {}

    var body: some View {
        let tasks = selectedTasks
        let ids = tasks.map(\.id)
        Group {
            if tasks.isEmpty {
                EmptyState(icon: "checklist", title: "Nothing selected",
                           message: "⌘-click or ⇧-click tasks in the list to change several at once.")
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: Space.xl) {
                        titleRow(tasks)
                        whenHero(tasks)
                        doneRow(tasks, ids)
                        moveSection(tasks, ids)
                        detailsSection(tasks, ids)
                        shareSection(ids)
                        footer(tasks, ids)
                    }
                    .padding(Space.xl)
                }
            }
        }
        .background(Color.paper)
        // A day picked in either date popover applies when the popover closes.
        .onChange(of: pickingFromHero) { open in if !open { applyPickedDay() } }
        .onChange(of: pickingFromTile) { open in if !open { applyPickedDay() } }
    }

    /// The selected tasks, in list order.
    private var selectedTasks: [TaskItem] {
        let byID = Dictionary(store.tasks.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return app.inVisibleOrder(app.selectedTaskIDs, in: store).compactMap { byID[$0] }
    }

    // MARK: Title

    private func titleRow(_ tasks: [TaskItem]) -> some View {
        HStack(alignment: .center, spacing: Space.md) {
            Text("\(Fmt.plural(tasks.count, "task")) selected")
                .font(.system(size: 22, weight: .bold))
                .tracking(-0.4)
                .foregroundStyle(Color.ink)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            Spacer(minLength: Space.sm)
            Button { app.deselectAll() } label: { Image(systemName: "xmark") }
                .buttonStyle(IconButtonStyle(size: 28, filled: true))
                .help("Deselect all")
        }
    }

    // MARK: When (the one Panel)

    /// When the selected tasks are (the days the Calendar lists them on) and how long they take.
    /// Click it to move them all to a date.
    private func whenHero(_ tasks: [TaskItem]) -> some View {
        let now = app.clock
        let today = store.calendar.startOfDay(for: now)
        let open = tasks.filter { !$0.isCompleted }
        let days = open.compactMap { calendarDay(of: $0, today: today) }
        let overdue = open.filter { $0.isOverdue(now: now) }.count
        let minutes = open.reduce(0) { $0 + $1.remainingMinutes }

        return Button { pickingFromHero = true } label: {
            Panel {
                HStack(alignment: .center) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(overdue > 0 ? "\(overdue) overdue" : "When")
                            .textStyle(.eyebrow)
                            .foregroundStyle(overdue > 0 ? Color(nsColor: Palette.dangerFg) : Color.onDark58)
                        Group {
                            if let first = days.min(), let last = days.max() {
                                if first == last {
                                    Text(Fmt.absoluteDay(first, now: now))
                                        .font(.system(size: 34, weight: .bold))
                                        .tracking(-0.8)
                                } else {
                                    Text("\(Fmt.absoluteDay(first, now: now)) – \(Fmt.absoluteDay(last, now: now))")
                                        .font(.system(size: 22, weight: .bold))
                                        .tracking(-0.4)
                                }
                            } else {
                                Text(open.isEmpty ? "All done" : "No dates yet")
                                    .font(.system(size: 26, weight: .bold))
                                    .tracking(-0.6)
                            }
                        }
                        .foregroundStyle(Color.white)
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                        Text(statusLine(tasks, open: open.count, undated: days.isEmpty ? 0 : open.count - days.count))
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(Color.onDark58)
                            .lineLimit(1)
                    }
                    .layoutPriority(1)
                    Spacer(minLength: Space.sm)
                    if minutes > 0 {
                        VStack(alignment: .trailing, spacing: 4) {
                            Text("Takes").textStyle(.eyebrow).foregroundStyle(Color.onDark58)
                            Text(Fmt.duration(minutes: minutes))
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
        .popover(isPresented: $pickingFromHero, arrowEdge: .bottom) {
            datePicker(count: tasks.count) { pickingFromHero = false }
        }
        .help("Move them all to a date")
    }

    /// The day an open task sits on in the Calendar: an overdue deadline's own day, otherwise the day it's
    /// listed on (a missed plan date rolls forward to today). Nil when it has no date at all.
    private func calendarDay(of t: TaskItem, today: Date) -> Date? {
        if store.isOverdueByDay(t, today: today) { return t.dueDate.map { store.calendar.startOfDay(for: $0) } }
        return store.calendarDay(of: t, today: today)
    }

    /// "3 open · 1 done · 2 without a date".
    private func statusLine(_ tasks: [TaskItem], open: Int, undated: Int) -> String {
        var parts: [String] = []
        if open > 0 { parts.append("\(open) open") }
        if tasks.count > open { parts.append("\(tasks.count - open) done") }
        if undated > 0 { parts.append("\(undated) without a date") }
        return parts.joined(separator: " · ")
    }

    // MARK: Done (the one primary button)

    private func doneRow(_ tasks: [TaskItem], _ ids: [UUID]) -> some View {
        // Ticks off the open ones; when they're all done it reopens them all.
        let open = tasks.filter { !$0.isCompleted }.count
        let anyOpen = open > 0
        return HStack(spacing: Space.sm) {
            Button {
                app.toggleDone(ids, in: store)
                app.deselectAll()
            } label: {
                Label(anyOpen ? "Mark \(open) as done" : "Mark \(tasks.count) as not done",
                      systemImage: anyOpen ? "checkmark" : "arrow.uturn.backward")
            }
            .buttonStyle(PrimaryPill())
            .help(anyOpen ? "Tick them all off (X in the list)" : "Reopen them all (X in the list)")
            KeyCap(text: "X")
            Spacer(minLength: 0)
        }
    }

    // MARK: Move to

    /// Moves and clearing apply to the open tasks; finished ones keep their dates.
    private func moveSection(_ tasks: [TaskItem], _ ids: [UUID]) -> some View {
        let now = app.clock
        let open = tasks.filter { !$0.isCompleted }
        let hasDates = open.contains { $0.dueDate != nil || $0.scheduledDate != nil }

        return VStack(alignment: .leading, spacing: Space.sm) {
            Eyebrow(text: "Move to")
                .padding(.leading, 4)
            LazyVGrid(columns: [GridItem(.flexible(), spacing: Space.sm), GridItem(.flexible(), spacing: Space.sm)], spacing: Space.sm) {
                ForEach(QuickDay.allCases, id: \.self) { quick in
                    let day = quick.date(now: now)
                    // Lit when they're all on that day already, so pressing it would change nothing.
                    let current = !open.isEmpty && open.allSatisfy { store.isPlaced($0, on: day) }
                    MoveTile(title: quick.label, detail: Fmt.absoluteDay(day, now: now), key: quick.key, selected: current) {
                        app.move(ids, toDay: quick.date(), in: store)
                    }
                    .help("Move them all to \(Fmt.absoluteDay(day, now: now)) (\(quick.key) in the list)")
                }
                MoveTile(title: "Pick a date…", detail: "Any day", icon: "calendar") { pickingFromTile = true }
                    .popover(isPresented: $pickingFromTile, arrowEdge: .bottom) {
                        datePicker(count: tasks.count) { pickingFromTile = false }
                    }
                    .help("Choose a day for all of them")
            }
            Button { app.clearDates(ids, in: store) } label: {
                Label("Clear dates", systemImage: "calendar.badge.minus")
            }
            .buttonStyle(SecondaryPill(height: 32))
            .disabled(!hasDates)
            .help("Take the plan dates and deadlines off them (done tasks keep theirs)")
        }
    }

    private func datePicker(count: Int, close: @escaping () -> Void) -> some View {
        DatePopover(date: $pickedDay, hasTime: .constant(false), allowsTime: false,
                    title: "Move \(Fmt.plural(count, "task")) to", close: close)
    }

    private func applyPickedDay() {
        guard let day = pickedDay else { return }
        pickedDay = nil
        app.move(app.actionTargets(in: store), toDay: day, in: store)
    }

    // MARK: Details

    private func detailsSection(_ tasks: [TaskItem], _ ids: [UUID]) -> some View {
        let priorities = Set(tasks.map(\.priority))
        let priority: Priority? = priorities.count == 1 ? priorities.first : nil
        let lists = Set(tasks.map { store.list($0.listID)?.id })
        let listName: String? = lists.count == 1 ? (store.list(lists.first.flatMap { $0 })?.name ?? "Inbox") : nil
        let estimates = Set(tasks.map(\.estimateMinutes))
        let estimate: String? = estimates.count == 1 ? (estimates.first.flatMap { $0 }.map { Fmt.duration(minutes: $0) } ?? "None") : nil

        return DetailSection("Details") {
            DetailRow(icon: "flag", label: "Priority") {
                Menu {
                    ForEach(Priority.allCases.reversed()) { p in
                        Button { app.setPriority(p, for: ids, in: store) } label: {
                            if priority == p { Label(p.label, systemImage: "checkmark") } else { Text(p.label) }
                        }
                    }
                } label: {
                    Text(priority?.label ?? "Mixed")
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundStyle(priority?.tone?.fg ?? (priority == nil || priority == Priority.none ? Color.ink3 : Color.ink))
                        .padding(.horizontal, priority?.tone == nil ? 0 : 9)
                        .frame(height: 24)
                }
                .menuChrome(Capsule(), fill: priority?.tone?.bg ?? .clear, hoverFill: priority?.tone?.border ?? .pressedTint)
                .help("Set the priority of all of them")
            }
            DetailRow(icon: "tray", label: "List") {
                Menu {
                    Button("Inbox") { app.setList(nil, for: ids, in: store) }
                    ForEach(store.lists) { list in
                        Button(list.name) { app.setList(list.id, for: ids, in: store) }
                    }
                } label: {
                    ValueLabel(listName ?? "Mixed", muted: listName == nil)
                        .padding(.horizontal, 6)
                        .frame(height: 26)
                }
                .menuChrome(RoundedRectangle(cornerRadius: Radius.xs, style: .continuous), fill: .clear, hoverFill: .pressedTint, truncates: true)
                .padding(.trailing, -6)
                .help("Move them all to a list")
            }
            DetailRow(icon: "hourglass", label: "Estimate") {
                Menu {
                    Button("No estimate") { app.setEstimate(nil, for: ids, in: store) }
                    Divider()
                    ForEach([5, 10, 15, 20, 30, 45, 60, 90, 120, 180, 240, 360, 480], id: \.self) { m in
                        Button(Fmt.duration(minutes: m)) { app.setEstimate(m, for: ids, in: store) }
                    }
                } label: {
                    ValueLabel(estimate ?? "Mixed", muted: estimate == nil || estimate == "None")
                        .padding(.horizontal, 6)
                        .frame(height: 26)
                }
                .menuChrome(RoundedRectangle(cornerRadius: Radius.xs, style: .continuous), fill: .clear, hoverFill: .pressedTint)
                .padding(.trailing, -6)
                .help("Set how long each of them takes")
            }
            DetailRow(icon: "person", label: "Waiting on") {
                waitingField(tasks, ids)
            }
            tagsBlock(tasks, ids)
        }
    }

    @ViewBuilder
    private func waitingField(_ tasks: [TaskItem], _ ids: [UUID]) -> some View {
        let names = Set(tasks.map { Store.personName($0.waitingOn) })
        let people = knownPeople
        TextField(names.count > 1 ? "Mixed" : (names.first.flatMap { $0 } ?? "Nobody"), text: $waitingOn)
            .textFieldStyle(.plain)
            .font(.system(size: 13.5, weight: .semibold))
            .multilineTextAlignment(.trailing)
            .onSubmit {
                guard Store.personName(waitingOn) != nil else { return }
                app.setWaitingOn(waitingOn, for: ids, in: store)
                waitingOn = ""
            }
            .help("Type a name and press Return to set it on all of them")
        if !people.isEmpty {
            Menu {
                ForEach(people, id: \.self) { name in
                    Button(name) { app.setWaitingOn(name, for: ids, in: store) }
                }
            } label: {
                chevron
            }
            .menuChrome(Circle(), fill: .clear, hoverFill: .pressedTint)
            .help("Someone you've waited on before")
        }
        if names.contains(where: { $0 != nil }) {
            Button { app.setWaitingOn(nil, for: ids, in: store) } label: { Image(systemName: "xmark") }
                .buttonStyle(IconButtonStyle(size: 22))
                .help("Stop waiting on anyone for all of them")
        }
    }

    /// People tasks have waited on, for the quick menu.
    private var knownPeople: [String] {
        var seen = Set<String>()
        let names = store.tasks.compactMap { Store.personName($0.waitingOn) }.filter { seen.insert($0.lowercased()).inserted }
        return Array(names.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }.prefix(12))
    }

    private func tagsBlock(_ tasks: [TaskItem], _ ids: [UUID]) -> some View {
        let counts = tagCounts(tasks)
        let known = store.allTags
        return VStack(alignment: .leading, spacing: Space.sm) {
            HStack(alignment: .center, spacing: Space.md) {
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
                        app.addTag(newTag, to: ids, in: store)
                        newTag = ""
                    }
                    .help("Type a tag and press Return to add it to all of them")
                if !known.isEmpty {
                    Menu {
                        ForEach(known, id: \.self) { tag in
                            Button("#\(tag)") { app.addTag(tag, to: ids, in: store) }
                        }
                    } label: {
                        chevron
                    }
                    .menuChrome(Circle(), fill: .clear, hoverFill: .pressedTint)
                    .help("Add a tag you've used before")
                }
            }
            // Every tag on the selection; "· 2" when only some of them have it.
            if !counts.isEmpty {
                FlowLayout(spacing: 4, lineSpacing: 6) {
                    ForEach(counts, id: \.tag) { item in
                        let onAll = item.count == tasks.count
                        HStack(spacing: 4) {
                            Text(onAll ? "#\(item.tag)" : "#\(item.tag) · \(item.count)")
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Button { app.removeTag(item.tag, from: ids, in: store) } label: {
                                Image(systemName: "xmark").font(.system(size: 8, weight: .bold))
                                    .padding(6).contentShape(Rectangle()).padding(-6)
                            }
                            .buttonStyle(.plain)
                            .help(onAll ? "Remove #\(item.tag) from all of them" : "Remove #\(item.tag) from the \(item.count) that have it")
                        }
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(onAll ? Color.ink : Color.ink2)
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

    /// Each tag on the selected tasks (any capitalisation counts as one) and how many have it, most common first.
    private func tagCounts(_ tasks: [TaskItem]) -> [(tag: String, count: Int)] {
        var firstSeen: [String: Int] = [:]
        var counts: [String: (tag: String, count: Int)] = [:]
        for t in tasks {
            for key in Set(t.tags.map { $0.lowercased() }) {
                let tag = t.tags.first { $0.lowercased() == key } ?? key
                if firstSeen[key] == nil { firstSeen[key] = firstSeen.count }
                counts[key, default: (tag: tag, count: 0)].count += 1
            }
        }
        return counts.sorted { a, b in
            a.value.count != b.value.count ? a.value.count > b.value.count : firstSeen[a.key, default: 0] < firstSeen[b.key, default: 0]
        }
        .map(\.value)
    }

    private var chevron: some View {
        Image(systemName: "chevron.down")
            .font(.system(size: 10, weight: .bold))
            .foregroundStyle(Color.ink2)
            .frame(width: 22, height: 22)
    }

    // MARK: Share

    private func shareSection(_ ids: [UUID]) -> some View {
        VStack(alignment: .leading, spacing: Space.sm) {
            Eyebrow(text: "Share")
                .padding(.leading, 4)
            // Side by side when both fit the panel; with Slack connected they usually don't, so they stack.
            ViewThatFits(in: .horizontal) {
                HStack(spacing: Space.sm) { shareButtons(ids) }
                VStack(alignment: .leading, spacing: Space.sm) { shareButtons(ids) }
            }
        }
    }

    @ViewBuilder
    private func shareButtons(_ ids: [UUID]) -> some View {
        Button { app.copyChecklist(ids, in: store) } label: {
            Label("Copy as checklist", systemImage: "checklist")
        }
        // The same height as the Slack button beside it.
        .buttonStyle(SecondaryPill())
        .help("Copy them as a Markdown checklist with dates and estimates")
        ShareToSlackButton(taskIDs: ids)
    }

    // MARK: Footer

    private func footer(_ tasks: [TaskItem], _ ids: [UUID]) -> some View {
        VStack(alignment: .leading, spacing: Space.lg) {
            Rectangle().fill(Color.hair).frame(height: 1)
            shortcuts
            HStack(spacing: Space.sm) {
                Button(role: .destructive) {
                    app.delete(ids, in: store) { app.deselectAll() }
                } label: {
                    Label("Delete \(Fmt.plural(tasks.count, "task"))", systemImage: "trash")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Color.dangerText)
                }
                .buttonStyle(PressScale())
                .help(tasks.count > 5 ? "Delete all of them (asks first, and ⌘Z brings them back)" : "Delete all of them (⌘Z brings them back)")
                KeyCap(text: "⌫")
                Spacer(minLength: 0)
            }
        }
    }

    /// How to change the selection itself, from the mouse or the keyboard.
    private var shortcuts: some View {
        Grid(alignment: .leading, horizontalSpacing: Space.sm, verticalSpacing: 6) {
            GridRow {
                KeyCap(text: "⌘ click")
                hint("Add or remove a task")
            }
            GridRow {
                HStack(spacing: 3) {
                    KeyCap(text: "⇧ click")
                    KeyCap(text: "⇧↑")
                    KeyCap(text: "⇧↓")
                }
                hint("Select a range")
            }
            GridRow {
                KeyCap(text: "⌘A")
                hint("Select every open task")
            }
            GridRow {
                KeyCap(text: "esc")
                hint("Back to one task")
            }
        }
    }

    private func hint(_ text: String) -> some View {
        Text(text)
            .textStyle(.caption)
            .foregroundStyle(Color.ink2)
            .lineLimit(1)
    }
}

/// A big "move to" button: the action, its real date, and its key.
private struct MoveTile: View {
    let title: String
    let detail: String
    var key: String?
    var icon: String?
    var selected = false
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: Space.sm) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(1)
                    Text(detail)
                        .font(.system(size: 11.5, weight: .medium))
                        .opacity(0.65)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                if let key {
                    KeyCap(text: key)
                } else if let icon {
                    Image(systemName: icon)
                        .font(.system(size: 13, weight: .semibold))
                }
            }
            .foregroundStyle(selected ? Color.onPrimary : Color.ink)
            .padding(.horizontal, 12)
            .frame(maxWidth: .infinity, minHeight: 48)
            .background(
                RoundedRectangle(cornerRadius: Radius.md, style: .continuous)
                    .fill(selected ? Color.primaryFill : (hovering ? Color.fillStrong : Color.fill))
            )
            .contentShape(RoundedRectangle(cornerRadius: Radius.md, style: .continuous))
        }
        .buttonStyle(PressScale(scale: 0.97))
        .onHover { h in withAnimation(Motion.fast) { hovering = h } }
    }
}
