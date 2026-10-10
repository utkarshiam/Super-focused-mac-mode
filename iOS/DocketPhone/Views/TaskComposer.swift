import SwiftUI

/// A new task for the Mac (or one from a debrief being edited): a title and an optional due date and time.
/// "Today" and "Tomorrow" are quick-pick actions; the chosen date always shows as a real date.
struct TaskComposer: View {
    let onAdd: (String, Date?, Bool) -> Void
    var heading = "New task"
    var confirmTitle = "Add"
    /// Shows "Remove task" when set (editing).
    var onRemove: (() -> Void)?

    @Environment(\.dismiss) private var dismiss
    @State private var title: String
    @State private var due: Date?
    @State private var hasTime = false
    @State private var time: Date
    @State private var showCalendar = false
    @FocusState private var focused: Bool

    init(initialTitle: String = "", initialDue: Date? = nil, initialHasTime: Bool = false, heading: String = "New task",
         confirmTitle: String = "Add", onRemove: (() -> Void)? = nil, onAdd: @escaping (String, Date?, Bool) -> Void) {
        self.onAdd = onAdd
        self.heading = heading
        self.confirmTitle = confirmTitle
        self.onRemove = onRemove
        _title = State(initialValue: initialTitle)
        _due = State(initialValue: initialDue)
        _hasTime = State(initialValue: initialDue != nil && initialHasTime)
        // Default time: the task's own, else the next full hour.
        let cal = Calendar.current
        let next = cal.date(byAdding: .hour, value: 1, to: Date()) ?? Date()
        _time = State(initialValue: initialHasTime ? (initialDue ?? next) : (cal.date(bySetting: .minute, value: 0, of: next) ?? next))
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

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Space.xl) {
                    TextField("", text: $title, prompt: Text("Task").foregroundStyle(Color.ink3), axis: .vertical)
                        .font(.system(size: 21, weight: .semibold))
                        .tracking(-0.3)
                        .foregroundStyle(Color.ink)
                        .lineLimit(1...4)
                        .focused($focused)
                        .submitLabel(.done)
                    Hairline()
                    dueSection
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
            .paperBackground()
            .navigationTitle(heading)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }.foregroundStyle(Color.ink2)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(confirmTitle) {
                        onAdd(trimmed, resolvedDue, due != nil && hasTime)
                        dismiss()
                    }
                    .fontWeight(.semibold)
                    .disabled(trimmed.isEmpty)
                }
            }
            .onAppear { if onRemove == nil { focused = true } }
        }
    }

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
                .tint(Color.primaryFill)
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
}
