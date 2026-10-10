import MemoryKit
import SwiftUI

// MARK: - The card on Capture

/// "Speak a task" on Capture: listening (live words, level, stop), then what the words became.
struct SpokenCardSlot: View {
    @ObservedObject var spoken: SpokenTaskCenter

    var body: some View {
        Group {
            if spoken.isListening {
                SpokenListeningCard(spoken: spoken)
            } else if let job = spoken.card {
                SpokenResultCard(job: job, spoken: spoken)
            }
        }
        .transition(.move(edge: .top).combined(with: .opacity))
    }
}

private struct SpokenListeningCard: View {
    @ObservedObject var spoken: SpokenTaskCenter
    @State private var stopping = false

    var body: some View {
        VStack(alignment: .leading, spacing: Space.md) {
            HStack(spacing: Space.sm) {
                Circle().fill(Color.danger).frame(width: 8, height: 8)
                Eyebrow("Speak a task · listening", color: .dangerText)
                Spacer(minLength: Space.sm)
                Button("Cancel") { spoken.cancelListening() }
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(Color.ink2)
            }
            Group {
                if spoken.heardText.isEmpty {
                    Text("Say what and when, like “Call Rohan Friday at 3 for half an hour, remind me 15 minutes before.”")
                        .foregroundStyle(Color.ink3)
                } else {
                    Text(spoken.heardText).foregroundStyle(Color.ink)
                }
            }
            .font(.system(size: 19))
            .tracking(-0.2)
            .lineSpacing(3)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .animation(Motion.gentle, value: spoken.heardText)
            HStack(alignment: .center, spacing: Space.md) {
                Text("A pause ends it, or tap stop.")
                    .font(.system(size: 13.5, weight: .medium))
                    .foregroundStyle(Color.ink2)
                Spacer(minLength: Space.sm)
                Button {
                    guard !stopping else { return }
                    stopping = true
                    Task {
                        await spoken.stopListening()
                        stopping = false
                    }
                } label: {
                    ZStack {
                        Circle()
                            .strokeBorder(Color.danger.opacity(0.18 + 0.5 * spoken.level), lineWidth: 3)
                            .frame(width: 62, height: 62)
                            .scaleEffect(1 + 0.08 * spoken.level)
                            .animation(Motion.fast, value: spoken.level)
                        Circle().fill(Color.primaryFill).frame(width: 52, height: 52)
                        RoundedRectangle(cornerRadius: 4, style: .continuous).fill(Color.danger).frame(width: 17, height: 17)
                    }
                }
                .buttonStyle(PressScale(scale: 0.92))
                .accessibilityLabel("Stop and schedule")
            }
        }
        .padding(Space.lg)
        .hairlineCard()
    }
}

/// What the words became: "Added 2 tasks", each with its real date and time bold, length, reminder or alarm,
/// repeat and list. ✕ takes one back, Undo all takes them all back, a tap edits.
private struct SpokenResultCard: View {
    let job: SpokenJob
    @ObservedObject var spoken: SpokenTaskCenter
    @EnvironmentObject private var model: AppModel
    @State private var editing: DebriefTask?

    var body: some View {
        VStack(alignment: .leading, spacing: Space.md) {
            HStack(alignment: .firstTextBaseline) {
                Eyebrow("Spoken · \(PhoneFmt.dayTime(job.spokenAt))").lineLimit(1)
                Spacer(minLength: Space.sm)
                Button {
                    spoken.closeCard()
                } label: {
                    Image(systemName: "xmark")
                }
                .buttonStyle(IconButtonStyle(size: 28))
                .accessibilityLabel("Close")
            }
            content
        }
        .padding(Space.lg)
        .hairlineCard()
        .sheet(item: $editing) { task in
            TaskComposer(draft: task, heading: "Edit task", confirmTitle: "Save", expanded: task.hasExtras, voiceMode: .fillsFields,
                         onRemove: { withAnimation(Motion.snappy) { spoken.remove(task.id, in: job.id) } }) { changed in
                spoken.update(changed, in: job.id)
            }
            .presentationDetents(task.hasExtras ? [.large] : [.medium, .large])
            .presentationBackground(Color.paper)
        }
    }

    @ViewBuilder
    private var content: some View {
        switch job.status {
        case .scheduling:
            HStack(spacing: Space.sm) {
                ProgressView().tint(Color.ink2)
                Text("Scheduling…").textStyle(.headline).foregroundStyle(Color.ink)
            }
            words
        case .offline:
            Label {
                Text(model.voice.isOnline ? "Saved. \(job.message ?? "Gemini couldn't be reached.") Docket tries again shortly."
                     : "Saved. Will schedule when you're back online.")
                    .font(.system(size: 16, weight: .semibold)).foregroundStyle(Color.ink)
                    .fixedSize(horizontal: false, vertical: true)
            } icon: {
                Image(systemName: "icloud.slash").font(.system(size: 15, weight: .semibold)).foregroundStyle(Color.ink2)
            }
            words
            footer
        case .added, .plain:
            result
        }
    }

    @ViewBuilder
    private var words: some View {
        Text("“\(job.words)”")
            .font(.system(size: 14.5))
            .italic()
            .foregroundStyle(Color.ink2)
            .lineLimit(3)
    }

    @ViewBuilder
    private var result: some View {
        let tasks = job.visibleTasks
        HStack {
            Text(tasks.isEmpty ? (job.removedIDs.isEmpty ? "No tasks added" : "Taken back") : "Added \(PhoneFmt.count(tasks.count, "task"))")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(tasks.isEmpty ? Color.ink2 : Tone.success.fg)
            Spacer()
            if !tasks.isEmpty {
                Button("Undo all") {
                    withAnimation(Motion.snappy) { spoken.undoAll(job.id) }
                    Haptics.select()
                }
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Color.ink2)
            }
        }
        if !tasks.isEmpty {
            VStack(spacing: 0) {
                ForEach(Array(tasks.enumerated()), id: \.element.id) { index, task in
                    if index > 0 { Hairline().padding(.leading, 30) }
                    SpokenTaskRow(task: task, edit: { editing = task }) {
                        withAnimation(Motion.snappy) { spoken.remove(task.id, in: job.id) }
                        Haptics.select()
                    }
                }
            }
            .padding(.vertical, Space.xxs)
            .overlay(alignment: .top) { Hairline() }
            .overlay(alignment: .bottom) { Hairline() }
        }
        if job.status == .plain {
            Text(job.message.map { "\($0) Added as said." } ?? "Added as said.")
                .font(.system(size: 13.5))
                .foregroundStyle(Color.ink2)
                .fixedSize(horizontal: false, vertical: true)
        }
        footer
    }

    private var footer: some View {
        HStack {
            Text(job.status == .offline ? "" : "Tap one to change it")
                .font(.system(size: 13.5, weight: .medium))
                .foregroundStyle(Color.ink3)
            Spacer()
            Button("Done") { spoken.closeCard() }
                .buttonStyle(SecondaryPill(height: 34))
        }
        .padding(.top, Space.xxs)
    }
}

private struct SpokenTaskRow: View {
    let task: DebriefTask
    let edit: () -> Void
    let remove: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: Space.sm) {
            Button(action: edit) {
                HStack(alignment: .center, spacing: Space.sm) {
                    Circle()
                        .strokeBorder(task.priority >= 3 ? Color.ink : Color.ink3, lineWidth: 1.5)
                        .frame(width: 18, height: 18)
                        .padding(.trailing, 4)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(task.title)
                            .font(.system(size: 15.5, weight: .medium))
                            .foregroundStyle(Color.ink)
                            .multilineTextAlignment(.leading)
                            .lineLimit(2)
                        if let meta = TaskMeta.text(task.asSnapshot, extra: task.waitingOn.map { ["Waiting on \($0)"] } ?? []) {
                            meta.font(.system(size: 12.5, weight: .medium)).foregroundStyle(Color.ink3).lineLimit(3)
                        }
                    }
                    Spacer(minLength: Space.sm)
                    VStack(alignment: .trailing, spacing: 4) {
                        if let due = task.dueDate {
                            DueText(date: due, hasTime: task.dueHasTime)
                        } else if let day = task.scheduledDate {
                            DueText(date: day, hasTime: false)
                        } else {
                            Text("No date")
                                .font(.system(size: 14, weight: .medium))
                                .foregroundStyle(Color.ink3)
                                .fixedSize()
                        }
                        if let minutes = task.estimateMinutes, minutes > 0 { DurationPill(minutes: minutes) }
                    }
                    .fixedSize()
                }
                .padding(.vertical, 10)
                .contentShape(Rectangle())
            }
            .buttonStyle(PressScale(scale: 0.985))
            .accessibilityHint("Edit")

            Button(action: remove) {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(Color.ink3)
                    .frame(width: 28, height: 36)
                    .contentShape(Rectangle())
            }
            .buttonStyle(PressScale(scale: 0.9))
            .accessibilityLabel("Remove \(task.title)")
        }
    }
}

// MARK: - The small line under a task

/// "↻ every weekday · ⏰ at the time · Do on Mon 12 Oct · Team": repeat, reminder or alarm, the Do on day
/// when it differs from the deadline, and the list. Real dates only.
enum TaskMeta {
    static func text(_ task: TaskSnapshot, extra: [String] = [], now: Date = Date()) -> Text? {
        // Each part keeps together (no-break spaces); lines break only between parts.
        func keep(_ s: String) -> String { s.replacingOccurrences(of: " ", with: "\u{00A0}") }
        var parts: [Text] = extra.map { Text(keep($0)) }
        if let rule = task.repeatRule {
            parts.append(Text("\(Image(systemName: "repeat"))\u{00A0}\(keep(rule.label))"))
        }
        if task.dueDate != nil, let minutes = task.reminderMinutes, minutes >= 0 {
            let icon = Image(systemName: task.isAlarm ? "alarm" : "bell")
            parts.append(Text("\(icon)\u{00A0}\(keep((task.isAlarm ? "alarm " : "") + PhoneFmt.reminderShort(minutes)))"))
        }
        if let doOn = task.scheduledDate, let due = task.dueDate, !Calendar.current.isDate(doOn, inSameDayAs: due) {
            parts.append(Text(keep("Do on \(PhoneFmt.day(doOn, now: now))")))
        }
        if let list = task.listName { parts.append(Text(keep(list))) }
        guard var line = parts.first else { return nil }
        for part in parts.dropFirst() { line = Text("\(line)\u{00A0}· \(part)") }
        return line
    }
}

extension DebriefTask {
    /// Has something the composer keeps behind More.
    var hasExtras: Bool {
        repeatRule != nil || scheduledDate != nil || listName != nil || priority > 0 || reminderMinutes != nil || isAlarm
    }
}
