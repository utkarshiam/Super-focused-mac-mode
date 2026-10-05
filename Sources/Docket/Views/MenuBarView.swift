import AppKit
import SwiftUI

/// The dropdown under the menu bar icon: today's agenda, quick add and the running focus timer.
struct MenuBarView: View {
    @EnvironmentObject var store: Store
    @EnvironmentObject var app: AppState
    @EnvironmentObject var focus: FocusTimer
    var close: () -> Void
    @State private var text = ""
    /// The Date, Time, List and More dropdowns (menus only here: a popover would close the panel).
    @State private var options = AddOptions()
    @State private var chipFocused = false
    @State private var hoveringOptions = false
    /// "Added for Mon 5 Oct" for a moment, when the new task isn't one of today's below.
    @State private var confirmation: String?
    @FocusState private var focused: Bool

    var body: some View {
        let now = app.clock
        let tasks = store.todayTasks(now: now)
        let minutes = tasks.reduce(0) { $0 + $1.remainingMinutes }
        let showsOptions = focused || !text.trimmingCharacters(in: .whitespaces).isEmpty || options.hasPicks || chipFocused || hoveringOptions

        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(Fmt.absoluteDay(now, now: now))
                        .textStyle(.title1)
                        .foregroundStyle(Color.ink)
                    Group {
                        if let confirmation {
                            Label(confirmation, systemImage: "checkmark")
                                .foregroundStyle(Color.ink)
                                .transition(.opacity)
                        } else {
                            Text(Fmt.plural(tasks.count, "task") + (minutes > 0 ? " · \(Fmt.duration(minutes: minutes))" : ""))
                                .foregroundStyle(Color.ink2)
                                .transition(.opacity)
                        }
                    }
                    .textStyle(.footnote)
                    .lineLimit(1)
                    .animation(Motion.base, value: confirmation)
                }
                Spacer()
                Button { close(); app.showMainWindow() } label: { Image(systemName: "arrow.up.left.and.arrow.down.right") }
                    .buttonStyle(IconButtonStyle(size: 30, filled: true))
                    .help("Open Docket")
            }
            .padding(.horizontal, Space.xl)
            .padding(.top, Space.xl)

            VStack(alignment: .leading, spacing: Space.sm) {
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

                if showsOptions {
                    let moment = Date()
                    AddOptionsBar(options: $options, parsed: parser(moment).parse(text), context: AddContext(day: moment), lists: store.lists,
                                  now: moment, usesPopovers: false, onPick: { focused = true }, onFocusChange: { chipFocused = $0 })
                        .onHover { hoveringOptions = $0 }
                        .transition(.opacity.combined(with: .offset(y: -4)))
                }
            }
            .animation(Motion.base, value: showsOptions)
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

    private func parser(_ now: Date) -> QuickParser {
        QuickParser(now: now, lists: store.lists, workdayEndMinutes: Prefs.workdayEnd)
    }

    private func add() {
        let raw = text.trimmingCharacters(in: .whitespaces)
        guard !raw.isEmpty else { return }
        let now = Date()
        // Undated tasks are for today here, as the field says.
        let task = options.makeTask(parsed: parser(now).parse(raw), context: AddContext(day: now), lists: store.lists, now: now)
        let added = withAnimation(Motion.gentle) { store.addTask(task) }
        text = ""
        options.reset()
        focused = true

        // Today's tasks show up in the list below; say where anything else went.
        guard !store.todayTasks(now: now).contains(where: { $0.id == added.id }) else { return }
        let day = store.calendarDay(of: added, today: Calendar.current.startOfDay(for: now))
        let message = day.map { "Added for \(Fmt.absoluteDay($0))" } ?? "Added to \(store.list(added.listID)?.name ?? "Inbox")"
        confirmation = message
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.4) {
            if confirmation == message { confirmation = nil }
        }
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
    /// The Date, Time, List and More dropdowns (menus only: a popover would close the panel).
    @State private var options = AddOptions()
    @State private var confirmation: String?
    @State private var confirmationDetail = ""
    @State private var monitor: Any?
    @FocusState private var focused: Bool

    var body: some View {
        let now = Date()
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
                } else if mode == .task {
                    // One line, as the panel has a fixed size: repeat and tags fold into "+2" and the hint
                    // drops out before anything wraps.
                    AddOptionsBar(options: $options, parsed: parser(now).parse(text), context: AddContext(), lists: store.lists, now: now,
                                  usesPopovers: false, arrangement: .oneLine,
                                  hint: text.trimmingCharacters(in: .whitespaces).isEmpty ? "Or just type “fri 10am 30m”" : nil,
                                  onPick: { focused = true })
                        .transition(.opacity)
                } else {
                    Text("Saved to Notes.")
                        .textStyle(.subhead)
                        .foregroundStyle(Color.ink3)
                        .transition(.opacity)
                }
            }
            .frame(height: 26, alignment: .leading)
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

    private func parser(_ now: Date) -> QuickParser {
        QuickParser(now: now, lists: store.lists, workdayEndMinutes: Prefs.workdayEnd)
    }

    private func save() {
        let raw = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else {
            close()
            return
        }
        switch mode {
        case .task:
            let now = Date()
            let t = store.addTask(options.makeTask(parsed: parser(now).parse(raw), context: AddContext(), lists: store.lists, now: now))
            options.reset()
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
