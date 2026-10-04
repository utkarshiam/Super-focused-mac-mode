import AppKit
import SwiftUI

/// The dropdown under the menu bar icon: today's agenda, quick add and the running focus timer.
struct MenuBarView: View {
    @EnvironmentObject var store: Store
    @EnvironmentObject var app: AppState
    @EnvironmentObject var focus: FocusTimer
    var close: () -> Void
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        let now = app.clock
        let tasks = store.todayTasks(now: now)
        let minutes = tasks.reduce(0) { $0 + $1.remainingMinutes }

        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(Fmt.absoluteDay(now, now: now))
                        .textStyle(.title1)
                        .foregroundStyle(Color.ink)
                    Text(Fmt.plural(tasks.count, "task") + (minutes > 0 ? " · \(Fmt.duration(minutes: minutes))" : ""))
                        .textStyle(.footnote)
                        .foregroundStyle(Color.ink2)
                }
                Spacer()
                Button { close(); app.showMainWindow() } label: { Image(systemName: "arrow.up.left.and.arrow.down.right") }
                    .buttonStyle(IconButtonStyle(size: 30, filled: true))
                    .help("Open Docket")
            }
            .padding(.horizontal, Space.xl)
            .padding(.top, Space.xl)

            HStack(spacing: 10) {
                Image(systemName: "plus")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(focused ? Color.onPrimary : Color.ink2)
                    .frame(width: 22, height: 22)
                    .background(Circle().fill(focused ? Color.primaryFill : Color.fillStrong))
                TextField("Add to today. “Call Sam 3pm 15m”", text: $text)
                    .textFieldStyle(.plain)
                    .font(.system(size: 14, weight: .medium))
                    .focused($focused)
                    .onSubmit(add)
            }
            .padding(.horizontal, 10)
            .frame(height: 42)
            .background(RoundedRectangle(cornerRadius: Radius.md, style: .continuous).fill(Color.fill))
            .padding(.horizontal, Space.lg)
            .padding(.top, Space.lg)
            .padding(.bottom, Space.sm)

            if focus.isActive {
                FocusMiniCard()
                    .padding(.horizontal, Space.lg)
                    .padding(.vertical, Space.sm)
            }

            if tasks.isEmpty {
                VStack(spacing: Space.sm) {
                    Image(systemName: "checkmark")
                        .font(.system(size: 18, weight: .bold))
                        .foregroundStyle(Color.onPrimary)
                        .frame(width: 44, height: 44)
                        .background(Circle().fill(Color.primaryFill))
                    Text("All clear for today").textStyle(.headline).foregroundStyle(Color.ink)
                    Text("\(store.count(for: .inbox)) in your inbox").textStyle(.footnote).foregroundStyle(Color.ink2)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    VStack(spacing: 2) {
                        ForEach(Array(tasks.enumerated()), id: \.element.id) { i, t in
                            row(t, now: now)
                                .enterUp(i)
                        }
                    }
                    .padding(.horizontal, Space.sm)
                    .padding(.vertical, Space.xs)
                }
            }

            Rectangle().fill(Color.hair).frame(height: 1)
            HStack(spacing: Space.sm) {
                Button {
                    close()
                    app.showQuickCapture()
                } label: {
                    Label("Quick Capture", systemImage: "bolt")
                }
                .buttonStyle(SecondaryPill(height: 30))
                KeyCap(text: Prefs.hotkeyPreset.rawValue)
                Spacer()
                Button("Quit") { NSApp.terminate(nil) }
                    .buttonStyle(PressScale())
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color.ink2)
            }
            .padding(.horizontal, Space.lg)
            .frame(height: 54)
        }
        .frame(width: 370, height: 540)
        .floatingPanelChrome()
    }

    private func row(_ t: TaskItem, now: Date) -> some View {
        HStack(spacing: Space.md) {
            CheckCircle(done: t.isCompleted, priority: t.priority, size: 20) { app.toggle(t.id, in: store) }
            VStack(alignment: .leading, spacing: 2) {
                Text(t.title)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Color.ink)
                    .lineLimit(1)
                if let est = t.estimateMinutes {
                    Text(Fmt.duration(minutes: est)).textStyle(.caption).foregroundStyle(Color.ink2)
                }
            }
            Spacer(minLength: Space.sm)
            if let due = t.dueDate {
                if t.dueHasTime {
                    BigTime(date: due, size: 15, color: t.isOverdue(now: now) ? .danger : .ink)
                } else {
                    Text(Fmt.absoluteDay(due, now: now))
                        .font(.system(size: 15, weight: .bold))
                        .tracking(-0.2)
                        .foregroundStyle(t.isOverdue(now: now) ? Color.danger : Color.ink)
                }
            }
            if focus.taskID != t.id {
                Button {
                    focus.start(taskID: t.id, minutes: t.remainingMinutes > 0 ? t.remainingMinutes : Prefs.focusMinutes)
                } label: { Image(systemName: "play.fill") }
                    .buttonStyle(IconButtonStyle(size: 26))
                    .help("Start focus")
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .hoverHighlight(cornerRadius: Radius.md)
        .contentShape(Rectangle())
        .onTapGesture {
            close()
            app.reveal(task: t.id, in: store)
        }
    }

    private func add() {
        let raw = text.trimmingCharacters(in: .whitespaces)
        guard !raw.isEmpty else { return }
        let parser = QuickParser(lists: store.lists, workdayEndMinutes: Prefs.workdayEnd)
        var t = TaskItem(parsed: parser.parse(raw), defaultReminder: Prefs.defaultReminder, defaultIsAlarm: Prefs.defaultReminderIsAlarm)
        if t.dueDate == nil { t.scheduledDate = Calendar.current.startOfDay(for: Date()) }
        withAnimation(Motion.gentle) { _ = store.addTask(t) }
        text = ""
    }
}

/// Spotlight-style capture panel opened by the global shortcut.
struct QuickCaptureView: View {
    @EnvironmentObject var store: Store
    @EnvironmentObject var app: AppState
    var close: () -> Void

    enum Mode: String, CaseIterable { case task = "Task", note = "Note" }
    @State private var mode: Mode = .task
    @State private var text = ""
    @State private var confirmation: String?
    @State private var confirmationDetail = ""
    @State private var monitor: Any?
    @FocusState private var focused: Bool

    var body: some View {
        let parser = QuickParser(lists: store.lists, workdayEndMinutes: Prefs.workdayEnd)
        VStack(alignment: .leading, spacing: Space.md) {
            HStack {
                SegmentedControl(selection: $mode, options: Mode.allCases.map { ($0, $0.rawValue) })
                Spacer()
                Text("↩ save · ⇥ switch · esc close")
                    .textStyle(.caption)
                    .foregroundStyle(Color.ink3)
            }

            TextField(mode == .task ? "What needs doing?" : "Jot a note. The first line becomes the title.", text: $text)
                .textFieldStyle(.plain)
                .font(.system(size: 26, weight: .bold))
                .tracking(-0.6)
                .foregroundStyle(Color.ink)
                .focused($focused)
                .onSubmit(save)

            Group {
                if let confirmation {
                    HStack(spacing: Space.sm) {
                        Image(systemName: "checkmark")
                            .font(.system(size: 10, weight: .heavy))
                            .foregroundStyle(Color.onPrimary)
                            .frame(width: 18, height: 18)
                            .background(Circle().fill(Color.primaryFill))
                        HStack(spacing: 0) {
                            Text(confirmation).lineLimit(1).truncationMode(.middle)
                            if !confirmationDetail.isEmpty {
                                Text(confirmationDetail).lineLimit(1).fixedSize()
                            }
                        }
                        .textStyle(.subheadStrong)
                        .foregroundStyle(Color.ink)
                    }
                    .transition(.opacity.combined(with: .scale(scale: 0.95)))
                } else if mode == .task, !text.trimmingCharacters(in: .whitespaces).isEmpty {
                    ParsedPreview(parsed: parser.parse(text), lists: store.lists)
                } else {
                    Text(mode == .task ? "Try “Send deck to Sequoia fri 10am 30m !!! @alarm15”" : "Saved to Notes.")
                        .textStyle(.subhead)
                        .foregroundStyle(Color.ink3)
                }
            }
            .frame(height: 22, alignment: .leading)
            .animation(Motion.base, value: confirmation)
        }
        .padding(.horizontal, Space.xxl)
        .padding(.vertical, Space.xl)
        .frame(width: 640, height: 172)
        .floatingPanelChrome()
        .onAppear {
            DispatchQueue.main.async { focused = true }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
                guard event.keyCode == 48, event.window is QuickCapturePanel, event.window?.isKeyWindow == true else { return event }
                withAnimation(Motion.snappy) { mode = mode == .task ? .note : .task }
                return nil
            }
        }
        .onDisappear {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
        }
    }

    private func save() {
        let raw = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else {
            close()
            return
        }
        switch mode {
        case .task:
            let parser = QuickParser(lists: store.lists, workdayEndMinutes: Prefs.workdayEnd)
            let t = store.addTask(TaskItem(parsed: parser.parse(raw), defaultReminder: Prefs.defaultReminder, defaultIsAlarm: Prefs.defaultReminderIsAlarm))
            let where_ = t.dueDate.map { "due \(Fmt.due($0, hasTime: t.dueHasTime))" } ?? "in \(store.list(t.listID)?.name ?? "Inbox")"
            confirmationDetail = ", \(where_)"
            confirmation = "Added “\(t.title)”"
        case .note:
            store.addNote(body: raw)
            confirmationDetail = ""
            confirmation = "Note saved"
        }
        Haptics.success()
        text = ""
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) { close() }
    }
}
