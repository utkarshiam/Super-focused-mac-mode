import AppKit
import SwiftUI

/// ⌘K: jump to any task, note or view, or create a task from what you typed.
struct CommandPalette: View {
    @EnvironmentObject var store: Store
    @EnvironmentObject var app: AppState
    @State private var query = ""
    @State private var index = 0
    @State private var monitor: Any?
    @State private var shown = false
    @FocusState private var focused: Bool

    struct Item: Identifiable {
        var id: String
        var icon: String
        var title: String
        var subtitle: String?
        var action: () -> Void
    }

    var body: some View {
        let items = results
        ZStack(alignment: .top) {
            Color.scrim
                .ignoresSafeArea()
                .onTapGesture { close() }

            VStack(spacing: 0) {
                HStack(spacing: Space.md) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(Color.ink2)
                    TextField("Search, jump anywhere, or type a new task", text: $query)
                        .textFieldStyle(.plain)
                        .font(.system(size: 19, weight: .semibold))
                        .tracking(-0.3)
                        .foregroundStyle(Color.ink)
                        .focused($focused)
                        .onSubmit { run(items) }
                    KeyCap(text: "esc")
                }
                .padding(.horizontal, Space.xl)
                .frame(height: 60)
                Rectangle().fill(Color.hair).frame(height: 1)
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 2) {
                            ForEach(Array(items.enumerated()), id: \.element.id) { i, item in
                                row(item, selected: i == index)
                                    .id(i)
                                    .onTapGesture {
                                        index = i
                                        run(items)
                                    }
                            }
                        }
                        .padding(Space.sm)
                    }
                    .frame(maxHeight: 400)
                    .onChange(of: index) { i in withAnimation(Motion.fast) { proxy.scrollTo(i) } }
                }
            }
            .frame(width: 640)
            .background(RoundedRectangle(cornerRadius: Radius.xl, style: .continuous).fill(Color.raised))
            .overlay(RoundedRectangle(cornerRadius: Radius.xl, style: .continuous).strokeBorder(Color.hair))
            .floatShadow(strong: true)
            .padding(.top, 90)
            .scaleEffect(shown ? 1 : 0.97)
            .opacity(shown ? 1 : 0)
        }
        .onAppear {
            focused = true
            withAnimation(Motion.gentle) { shown = true }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
                switch event.keyCode {
                case 125: index = min(index + 1, max(0, results.count - 1)); return nil  // down
                case 126: index = max(index - 1, 0); return nil                          // up
                case 53: close(); return nil                                               // esc
                default: return event
                }
            }
        }
        .onDisappear {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
        }
        .onChange(of: query) { _ in index = 0 }
    }

    private func row(_ item: Item, selected: Bool) -> some View {
        HStack(spacing: Space.md) {
            Image(systemName: item.icon)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(selected ? Color.onPrimary : Color.ink)
                .frame(width: 30, height: 30)
                .background(RoundedRectangle(cornerRadius: Radius.sm, style: .continuous).fill(selected ? Color.primaryFill : Color.fill))
            VStack(alignment: .leading, spacing: 1) {
                Text(item.title)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Color.ink)
                    .lineLimit(1)
                if let s = item.subtitle {
                    Text(s).textStyle(.caption).foregroundStyle(Color.ink2).lineLimit(1)
                }
            }
            Spacer()
            if selected { KeyCap(text: "↩") }
        }
        .padding(.horizontal, 10)
        .frame(height: 48)
        .background(RoundedRectangle(cornerRadius: Radius.md, style: .continuous).fill(selected ? Color.fill : Color.clear))
        .hoverHighlight(cornerRadius: Radius.md)
        .contentShape(Rectangle())
    }

    private var results: [Item] {
        let q = query.trimmingCharacters(in: .whitespaces)
        var items: [Item] = []

        let commands: [Item] = [
            Item(id: "c-calendar", icon: "calendar", title: "Go to Calendar", subtitle: "⌘1") {
                app.selection = .calendar
                app.goTo(day: Date())
            },
            Item(id: "c-inbox", icon: "tray", title: "Go to Inbox", subtitle: "⌘2") { app.selection = .inbox },
            Item(id: "c-notes", icon: "doc.text", title: "Go to Notes", subtitle: "⌘3") { app.selection = .notes },
            Item(id: "c-important", icon: "flag", title: "Go to Important", subtitle: "⌘4") { app.selection = .important },
            Item(id: "c-completed", icon: "checkmark.circle", title: "Go to Completed", subtitle: "⌘6") { app.selection = .completed },
            Item(id: "c-insights", icon: "chart.bar", title: "Go to Insights", subtitle: "⌘7") { app.selection = .insights },
            Item(id: "c-month", icon: "calendar.badge.clock", title: "Show the month", subtitle: "Calendar") {
                app.selection = .calendar
                app.calendarMode = .month
            },
            Item(id: "c-daily", icon: "sun.max", title: "Open today's daily note", subtitle: "⌘D") { app.reveal(note: store.dailyNote().id) },
            Item(id: "c-note", icon: "square.and.pencil", title: "New note", subtitle: "⇧⌘N") { app.reveal(note: store.addNote(body: "").id) },
            Item(id: "c-clip", icon: "doc.on.clipboard", title: "New note from clipboard", subtitle: "⌥⌘V · shows Markdown formatted") { app.newNoteFromClipboard(store) },
            Item(id: "c-settings", icon: "gearshape", title: "Settings", subtitle: "⌘,") { app.showSettings() },
        ] + store.lists.map { list in
            Item(id: "l-\(list.id)", icon: list.icon, title: "Go to \(list.name)", subtitle: "List") { app.selection = .list(list.id) }
        }

        guard !q.isEmpty else { return commands }

        let parsed = QuickParser(lists: store.lists, workdayEndMinutes: Prefs.workdayEnd).parse(q)
        var detail: [String] = []
        if let d = parsed.dueDate { detail.append(Fmt.due(d, hasTime: parsed.dueHasTime)) }
        if let e = parsed.estimateMinutes { detail.append(Fmt.duration(minutes: e)) }
        if let l = store.list(parsed.listID) { detail.append(l.name) }

        items += commands.filter { $0.title.localizedCaseInsensitiveContains(q) }
        items += store.searchTasks(q, limit: 15).map { t in
            let when = t.dueDate.map { Fmt.due($0, hasTime: t.dueHasTime) }
            return Item(id: "t-\(t.id)", icon: t.isCompleted ? "checkmark.circle.fill" : "circle", title: t.title,
                        subtitle: [when, store.list(t.listID)?.name ?? "Inbox"].compactMap { $0 }.joined(separator: " · ")) {
                app.reveal(task: t.id, in: store)
            }
        }
        items += store.searchNotes(q, limit: 10).map { n in
            Item(id: "n-\(n.id)", icon: "doc.text", title: n.title, subtitle: n.preview.isEmpty ? "Note" : n.preview) {
                app.reveal(note: n.id)
            }
        }
        items.append(Item(id: "create", icon: "plus", title: "Create task “\(parsed.title)”",
                          subtitle: detail.isEmpty ? "Inbox" : detail.joined(separator: " · ")) {
            let t = store.addTask(TaskItem(parsed: parsed, defaultReminder: Prefs.defaultReminder, defaultIsAlarm: Prefs.defaultReminderIsAlarm))
            app.reveal(task: t.id, in: store)
        })
        return items
    }

    private func run(_ items: [Item]) {
        guard items.indices.contains(index) else { return }
        let action = items[index].action
        close()
        action()
    }

    private func close() {
        app.showPalette = false
    }
}
