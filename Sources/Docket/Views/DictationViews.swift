import AppKit
import SwiftUI

// "Dictate a task" in the add fields: the mic, the live level while listening, and what shows under the
// field (listening, scheduling, the tasks it added, or why not). The model is `TaskDictation`.

// MARK: - The mic

/// The mic in an add field: dictates a task (⇧⌘D); while listening it's the stop button.
struct DictateButton: View {
    @ObservedObject var dictation: TaskDictation
    var size: CGFloat = 26
    var filled = false
    let start: () -> Void

    var body: some View {
        let listening = dictation.isListening
        Button {
            listening ? dictation.finish() : start()
        } label: {
            Image(systemName: listening ? "stop.fill" : "mic")
                .font(.system(size: size * 0.48, weight: .semibold))
                .foregroundStyle(listening ? Color.danger : Color.ink2)
        }
        .buttonStyle(IconButtonStyle(size: size, filled: filled || listening))
        .disabled(dictation.phase == .working)
        .help(listening ? "Stop and schedule it (↩). Esc cancels." : "Dictate a task (⇧⌘D): say what, when, how long, a reminder or a repeat")
        .accessibilityLabel(listening ? "Stop dictating" : "Dictate a task")
    }
}

/// The input level as a few bars by the field, newest on the right.
struct DictationLevel: View {
    let levels: [Float]
    var height: CGFloat = 16

    var body: some View {
        HStack(alignment: .center, spacing: 2) {
            ForEach(Array(levels.enumerated()), id: \.offset) { _, level in
                Capsule()
                    .fill(level > 0.02 ? Color.ink : Color.hairStrong)
                    .frame(width: 3, height: max(3, CGFloat(level) * height))
            }
        }
        .frame(height: height)
        .animation(.linear(duration: 0.08), value: levels)
        .accessibilityHidden(true)
    }
}

/// The words heard so far, over the add field while listening: one line ending on the latest word (the field
/// itself would show the start). Before anything is heard, what to say.
struct DictationLiveWords: View {
    let text: String
    let font: Font
    var tracking: CGFloat = 0

    var body: some View {
        let words = text.trimmingCharacters(in: .whitespacesAndNewlines)
        Text(words.isEmpty ? DictationText.sayHint : words)
            .font(font)
            .tracking(tracking)
            .foregroundStyle(words.isEmpty ? Color.ink3 : Color.ink)
            .lineLimit(1)
            .truncationMode(words.isEmpty ? .tail : .head)
            .frame(maxWidth: .infinity, alignment: .leading)
            .allowsHitTesting(false)
            .accessibilityLabel(words.isEmpty ? "Listening" : "Heard: \(words)")
    }
}

extension View {
    /// While dictating, the live words stand in for the field (which keeps the focus, so Return still stops).
    func dictationOverlay(_ dictation: TaskDictation, text: String, font: Font, tracking: CGFloat = 0) -> some View {
        opacity(dictation.isListening ? 0 : 1)
            .overlay(alignment: .leading) {
                if dictation.isListening { DictationLiveWords(text: text, font: font, tracking: tracking) }
            }
    }
}

// MARK: - Under the field

/// The heights dictation takes under a field (Quick Capture's panel has a fixed size, so it grows by these).
enum DictationLayout {
    /// One line: listening, scheduling.
    static let line: CGFloat = 26
    static let rowHeight: CGFloat = 46
    static let header: CGFloat = 32

    /// The result card: header, the rows (then "and 2 more"), padding.
    static func card(rows: Int, maxRows: Int) -> CGFloat {
        var h = header + 12
        h += CGFloat(min(rows, maxRows)) * rowHeight
        if rows > maxRows { h += 20 }
        return h
    }

    /// Quick Capture's height for what dictation shows (its usual height otherwise).
    static func capturePanel(_ phase: TaskDictation.Phase, rows: Int, base: CGFloat, maxRows: Int) -> CGFloat {
        switch phase {
        case .result: return base - line + card(rows: rows, maxRows: maxRows) - 20
        case .failed, .typed: return base + 20
        default: return base
        }
    }
}

/// What dictation shows under an add field: listening (live level, how to stop), scheduling, the tasks it
/// added, or why not. Nothing while idle.
struct DictationStatus: View {
    @EnvironmentObject var store: Store
    @EnvironmentObject var app: AppState
    @ObservedObject var dictation: TaskDictation
    /// The most result rows shown (the panels have less room).
    var maxRows = 4
    /// Narrow (the menu bar): each task's date goes under its title instead of beside it.
    var stacked = false
    /// After a task was opened from the result (the panels close).
    var opened: () -> Void = {}

    var body: some View {
        switch dictation.phase {
        case .idle:
            EmptyView()
        case .starting:
            line {
                ProgressView().controlSize(.small)
                Text("Starting the microphone…").textStyle(.subheadStrong).foregroundStyle(Color.ink2)
            }
        case .listening:
            line {
                RecordingDot()
                Text("Listening").textStyle(.subheadStrong).foregroundStyle(Color.ink)
                DictationLevel(levels: dictation.levels)
                Text(DictationText.listening)
                    .textStyle(.caption)
                    .foregroundStyle(Color.ink3)
                    .lineLimit(1)
                    .padding(.leading, Space.xs)
            }
        case .working:
            line {
                ThinkingDots(size: 5)
                Text(dictation.memoryItemID == nil ? "Scheduling it…" : "Finding the tasks in it…")
                    .textStyle(.subheadStrong).foregroundStyle(Color.ink2)
            }
        case .result:
            if let result = dictation.result {
                DictationResultCard(dictation: dictation, result: result, maxRows: maxRows, stacked: stacked, opened: opened)
            }
        case .typed:
            MemoryNote(icon: "key", text: DictationText.noKeyHint) {
                Button { dictation.dismiss() } label: { Image(systemName: "xmark") }
                    .buttonStyle(IconButtonStyle(size: 22))
                    .help("Dismiss")
            }
        case .failed(let message, let privacy):
            MemoryNote(icon: "mic.slash", warning: true, text: message) {
                if let privacy {
                    Button("Open System Settings") { NSWorkspace.shared.open(privacy) }
                        .buttonStyle(SecondaryPill(height: 26))
                }
                Button { dictation.dismiss() } label: { Image(systemName: "xmark") }
                    .buttonStyle(IconButtonStyle(size: 22))
                    .help("Dismiss")
            }
        }
    }

    private func line<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        HStack(spacing: Space.sm) {
            content()
            Spacer(minLength: 0)
        }
        .frame(height: DictationLayout.line)
        .padding(.leading, 4)
        .transition(.opacity)
    }
}

/// "Added 2 tasks": each with its real date in bold, its length, and a quiet line of reminder, repeat and list;
/// ✕ removes one, Undo all takes them all back, a click opens one to change it.
struct DictationResultCard: View {
    @EnvironmentObject var store: Store
    @EnvironmentObject var app: AppState
    @ObservedObject var dictation: TaskDictation
    let result: TaskDictation.Result
    var maxRows = 4
    var stacked = false
    var opened: () -> Void = {}

    var body: some View {
        let tasks = result.undone ? [] : result.taskIDs.compactMap(store.task)
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: Space.sm) {
                Image(systemName: result.undone ? "arrow.uturn.backward" : "checkmark")
                    .font(.system(size: 9, weight: .heavy))
                    .foregroundStyle(Color.onPrimary)
                    .frame(width: 18, height: 18)
                    .background(Circle().fill(Color.primaryFill))
                Text(result.undone ? (result.made == 1 ? "Task removed" : "Tasks removed") : DictationText.headline(tasks: tasks.count))
                    .textStyle(.subheadStrong)
                    .foregroundStyle(Color.ink)
                Spacer(minLength: Space.sm)
                if !tasks.isEmpty {
                    Button("Undo all") { withAnimation(Motion.snappy) { dictation.undoAll() } }
                        .buttonStyle(SecondaryPill(height: 26))
                        .help("Take what was just added back out")
                }
                Button { withAnimation(Motion.snappy) { dictation.dismiss() } } label: { Image(systemName: "xmark") }
                    .buttonStyle(IconButtonStyle(size: 24))
                    .help("Close (the tasks stay)")
                    .accessibilityLabel("Close")
            }
            .frame(height: DictationLayout.header)

            ForEach(tasks.prefix(maxRows)) { t in row(t) }
            if tasks.count > maxRows {
                Text("and \(tasks.count - maxRows) more")
                    .textStyle(.caption)
                    .foregroundStyle(Color.ink3)
                    .frame(maxWidth: .infinity, minHeight: 20, alignment: .leading)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: Radius.md, style: .continuous).fill(Color.card))
        .overlay(RoundedRectangle(cornerRadius: Radius.md, style: .continuous).strokeBorder(Color.hair, lineWidth: 1))
        .transition(.opacity.combined(with: .offset(y: -4)))
    }

    private func row(_ t: TaskItem) -> some View {
        let details = DictationText.details(t, listName: store.list(t.listID)?.name, now: app.clock)
        return HStack(spacing: Space.sm) {
            Button {
                app.reveal(task: t.id, in: store)
                opened()
            } label: {
                Group {
                    if stacked {
                        VStack(alignment: .leading, spacing: 3) {
                            title(t)
                            HStack(spacing: 10) {
                                when(t, size: 12.5)
                                if let minutes = t.estimateMinutes {
                                    Label(Fmt.duration(minutes: minutes), systemImage: "hourglass")
                                        .labelStyle(TightLabel())
                                        .textStyle(.caption)
                                        .foregroundStyle(Color.ink2)
                                        .fixedSize()
                                }
                                if !details.isEmpty { DictationDetailsLine(items: details) }
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    } else {
                        HStack(spacing: Space.md) {
                            VStack(alignment: .leading, spacing: 3) {
                                title(t)
                                if !details.isEmpty { DictationDetailsLine(items: details) }
                            }
                            Spacer(minLength: Space.sm)
                            when(t, size: 13.5)
                            if let minutes = t.estimateMinutes { DurationPill(minutes: minutes).fixedSize() }
                        }
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(PressScale(scale: 0.99))
            .help("Open it to change it")
            .accessibilityLabel(([t.title, DictationText.when(t, now: app.clock)] + details.map(\.text)).joined(separator: ", "))
            Button { withAnimation(Motion.snappy) { dictation.remove(t.id) } } label: { Image(systemName: "xmark") }
                .buttonStyle(IconButtonStyle(size: 24))
                .help("Remove this task")
                .accessibilityLabel("Remove \(t.title)")
        }
        .frame(height: DictationLayout.rowHeight)
        .overlay(alignment: .top) { Rectangle().fill(Color.hair).frame(height: 1) }
    }
}

extension DictationResultCard {
    fileprivate func title(_ t: TaskItem) -> some View {
        Text(t.title)
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(Color.ink)
            .lineLimit(1)
    }

    /// The real date in bold: "Fri 16 Oct · 15:00".
    fileprivate func when(_ t: TaskItem, size: CGFloat) -> some View {
        Text(DictationText.when(t, now: app.clock))
            .font(.system(size: size, weight: .bold))
            .monospacedDigit()
            .tracking(-0.2)
            .foregroundStyle(t.dueDate == nil && t.scheduledDate == nil ? Color.ink3 : Color.ink)
            .fixedSize()
    }
}

/// Icon and text close together, as in the details line.
private struct TightLabel: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 3) {
            configuration.icon.font(.system(size: 9.5, weight: .bold))
            configuration.title
        }
    }
}

/// Reminder, repeat, list…: as many as fit on one line, the rest left out.
private struct DictationDetailsLine: View {
    let items: [AddExtra]

    var body: some View {
        ViewThatFits(in: .horizontal) {
            ForEach((1...max(1, items.count)).reversed(), id: \.self) { shown in
                HStack(spacing: 10) {
                    ForEach(items.prefix(shown), id: \.self) { item in
                        HStack(spacing: 3) {
                            Image(systemName: item.icon).font(.system(size: 9.5, weight: .bold))
                            Text(item.text).lineLimit(1)
                        }
                        .fixedSize()
                    }
                }
            }
        }
        .textStyle(.caption)
        .foregroundStyle(Color.ink2)
    }
}
