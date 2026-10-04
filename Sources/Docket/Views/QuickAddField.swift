import AppKit
import SwiftUI

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
