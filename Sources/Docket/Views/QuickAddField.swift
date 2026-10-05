import AppKit
import SwiftUI

// MARK: - Quick add

struct QuickAddField: View {
    @EnvironmentObject var store: Store
    @EnvironmentObject var app: AppState
    /// In the calendar: the day new tasks land on when no date is typed or picked.
    var day: Date?
    @State private var text = ""
    /// The Date, Time, List and More dropdowns. They win over the typed text and reset after each add.
    @State private var options = AddOptions()
    @State private var picker: AddPicker?
    @State private var chipFocused = false
    @State private var hoveringOptions = false
    @State private var fieldWidth: CGFloat = 0
    @FocusState private var focused: Bool

    var body: some View {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        let now = Date()
        // The dropdowns show while you're adding: the field has focus or text, something is picked,
        // or the pointer or keyboard is on them.
        let showsOptions = focused || !trimmed.isEmpty || options.hasPicks || picker != nil || chipFocused || hoveringOptions
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
                AIQuickAddButton(text: $text, day: day)
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

            // What the task will get, as dropdowns (they replace the old parse preview).
            if showsOptions {
                AddOptionsBar(options: $options, parsed: parser(now).parse(text), context: context, lists: store.lists, now: now,
                              picker: $picker, onPick: { focused = true }, onFocusChange: { chipFocused = $0 })
                    .onHover { hoveringOptions = $0 }
                    .transition(.opacity.combined(with: .offset(y: -4)))
            }
        }
        .animation(Motion.base, value: trimmed.isEmpty)
        .animation(Motion.base, value: showsOptions)
        .onChange(of: app.focusQuickAdd) { _ in focused = true }
        // The list pages share this field; picks made for one page's defaults don't carry over to the next.
        .onChange(of: app.selection) { _ in
            options.reset()
            picker = nil
        }
    }

    /// What this page gives a new task: the Calendar's day, a list, a tag, or High on Important.
    private var context: AddContext { AddContext(selection: app.selection, day: day) }

    /// The longest hint that fits the field, so it never gets cut off mid-word.
    private var placeholder: String {
        let example = day == nil ? "Board prep fri 3pm 90m !!! @alarm15" : "Call investor fri 3pm 30m !! @alarm10"
        let hints = ["Add a task. Try “\(example)”", "Add a task, e.g. “Call Sam fri 3pm 30m”", "Add a task"]
        let font = NSFont.systemFont(ofSize: 15, weight: .medium)
        return hints.first { fieldWidth == 0 || ($0 as NSString).size(withAttributes: [.font: font]).width + 4 <= fieldWidth }
            ?? hints[hints.count - 1]
    }

    private func parser(_ now: Date) -> QuickParser {
        QuickParser(now: now, lists: store.lists, workdayEndMinutes: Prefs.workdayEnd)
    }

    private func add() {
        guard !text.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        let now = Date()
        let cal = Calendar.current
        let today = cal.startOfDay(for: now)
        // Typed text, then the dropdown picks on top, then this page's defaults: the same merge the chips preview.
        let task = options.makeTask(parsed: parser(now).parse(text), context: context, lists: store.lists, now: now)
        let added = withAnimation(Motion.gentle) { store.addTask(task) }
        text = ""
        // Picks are for one task; the page's own defaults (its list, its day) come back by themselves.
        options.reset()
        focused = true

        // Say where it went when that isn't obvious from the screen.
        if app.selection == .calendar {
            if let d = store.calendarDay(of: added, today: today) {
                if d != cal.startOfDay(for: day ?? today) {
                    app.showToast("Added for \(Fmt.absoluteDay(d))")
                    app.goTo(day: d)
                }
            } else {
                // "No date" was picked, so it isn't on the calendar.
                app.showToast(addedElsewhere(added))
            }
        } else if !store.sections(for: app.selection, keeping: []).contains(where: { $0.tasks.contains { $0.id == added.id } }) {
            app.showToast(addedElsewhere(added))
        }
    }

    /// "Added. Due Mon 5 Oct." or "Added. Inbox."
    private func addedElsewhere(_ t: TaskItem) -> String {
        let destination = t.dueDate.map { "due \(Fmt.absoluteDay($0))" } ?? (store.list(t.listID)?.name ?? "Inbox")
        return "Added. \(destination.prefix(1).uppercased() + destination.dropFirst())."
    }
}
