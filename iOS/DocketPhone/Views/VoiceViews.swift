import MemoryKit
import SwiftUI

// MARK: - Recording

/// Full screen while recording: the time, a level meter, the words as they're heard, and one big Stop.
struct RecordingView: View {
    @ObservedObject var voice: VoiceCenter
    @ObservedObject var recorder: VoiceRecorder
    @State private var confirmDiscard = false
    @State private var stopping = false

    var body: some View {
        VStack(spacing: 0) {
            header
                .padding(.top, Space.sm)
            Text(PhoneFmt.clock(recorder.elapsed))
                .font(.system(size: 64, weight: .bold))
                .tracking(-1.5)
                .monospacedDigit()
                .foregroundStyle(recorder.isPaused ? Color.ink3 : Color.ink)
                .contentTransition(.numericText())
                .padding(.top, Space.x3)
            Text(recorder.isPaused ? "Paused" : "Keeps recording with the screen locked · up to 60 min")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Color.ink3)
                .padding(.top, Space.xxs)
            LevelMeter(levels: recorder.levels, active: recorder.isRecording)
                .frame(height: 56)
                .padding(.top, Space.xxl)
            transcriptBox
                .padding(.top, Space.xxl)
            if case .paused(let reason) = recorder.state {
                Text(reason)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Tone.warning.fg)
                    .multilineTextAlignment(.center)
                    .padding(.top, Space.md)
            }
            if let problem = recorder.problem {
                Text(problem)
                    .font(.system(size: 14))
                    .foregroundStyle(Color.dangerText)
                    .multilineTextAlignment(.center)
                    .padding(.top, Space.sm)
            }
            controls
                .padding(.top, Space.xl)
            Text("Stop when you're done. Docket turns it into tasks.")
                .font(.system(size: 14))
                .foregroundStyle(Color.ink2)
                .padding(.top, Space.md)
                .padding(.bottom, Space.lg)
        }
        .padding(.horizontal, Space.gutter)
        .paperBackground()
        .confirmationDialog("Discard this recording?", isPresented: $confirmDiscard, titleVisibility: .visible) {
            Button("Discard recording", role: .destructive) { voice.discardRecording() }
            Button("Keep recording", role: .cancel) {}
        } message: {
            Text("It won't be saved anywhere.")
        }
    }

    private var header: some View {
        HStack(spacing: Space.sm) {
            Circle()
                .fill(recorder.isPaused ? Color.ink3 : Color.danger)
                .frame(width: 9, height: 9)
            Text(recorder.isPaused ? "Paused" : "Recording")
                .textStyle(.eyebrow)
                .foregroundStyle(recorder.isPaused ? Color.ink3 : Color.dangerText)
            Spacer()
            Button("Discard") { confirmDiscard = true }
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(Color.ink2)
        }
    }

    private var transcriptBox: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: Space.sm) {
                    if recorder.transcript.isEmpty {
                        Text("Start talking. Your words show up here as you speak, in any language.")
                            .font(.system(size: 18))
                            .foregroundStyle(Color.ink3)
                    } else {
                        Text(recorder.transcript)
                            .font(.system(size: 19))
                            .lineSpacing(4)
                            .foregroundStyle(Color.ink)
                    }
                    if let note = recorder.transcriptNote {
                        Text(note).font(.system(size: 13)).foregroundStyle(Color.ink3)
                    }
                    Color.clear.frame(height: 1).id("end")
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(Space.lg)
            }
            .scrollIndicators(.hidden)
            .frame(maxHeight: .infinity)
            .hairlineCard()
            .onChange(of: recorder.transcript) { _, _ in
                withAnimation(Motion.gentle) { proxy.scrollTo("end", anchor: .bottom) }
            }
        }
    }

    private var controls: some View {
        HStack(spacing: 40) {
            Button {
                if recorder.isPaused { recorder.resume() } else { recorder.pause() }
                Haptics.select()
            } label: {
                Image(systemName: recorder.isPaused ? "play.fill" : "pause.fill")
            }
            .buttonStyle(IconButtonStyle(size: 58))
            .accessibilityLabel(recorder.isPaused ? "Resume" : "Pause")

            Button {
                guard !stopping else { return }
                stopping = true
                Task {
                    await voice.stopRecording()
                    stopping = false
                }
            } label: {
                ZStack {
                    Circle().fill(Color.primaryFill).frame(width: 92, height: 92)
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(Color.danger)
                        .frame(width: 30, height: 30)
                }
            }
            .buttonStyle(PressScale(scale: 0.93))
            .accessibilityLabel("Stop and save")

            Color.clear.frame(width: 58, height: 58)
        }
    }
}

/// Bars for the last few seconds of loudness, newest on the right.
struct LevelMeter: View {
    var levels: [Double]
    var active: Bool

    var body: some View {
        GeometryReader { geo in
            let count = max(levels.count, 1)
            let gap: CGFloat = 4
            let width = max(2, (geo.size.width - gap * CGFloat(count - 1)) / CGFloat(count))
            HStack(alignment: .center, spacing: gap) {
                ForEach(Array(levels.enumerated()), id: \.offset) { _, level in
                    Capsule()
                        .fill(active ? Color.ink : Color.ink3.opacity(0.5))
                        .frame(width: width, height: max(4, geo.size.height * CGFloat(level)))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .animation(Motion.fast, value: levels)
        }
        .accessibilityHidden(true)
    }
}

/// A task's real date, bold, right-aligned: "Mon 12 Oct" with the time ("11:00") on a second line so long
/// titles keep their room.
struct DueText: View {
    var date: Date
    var hasTime: Bool
    var color: Color = .ink
    var now = Date()

    var body: some View {
        VStack(alignment: .trailing, spacing: 1) {
            Text(PhoneFmt.day(date, now: now))
            if hasTime { Text(PhoneFmt.time(date)) }
        }
        .font(.system(size: 14, weight: .bold))
        .tracking(-0.2)
        .monospacedDigit()
        .foregroundStyle(color)
        .lineLimit(1)
        .fixedSize()
    }
}

// MARK: - The big mic on Capture

struct RecordButtonCard: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        Button {
            Task { await model.voice.startRecording() }
        } label: {
            HStack(spacing: Space.lg) {
                ZStack {
                    Circle().fill(Color.primaryFill).frame(width: 72, height: 72)
                    Image(systemName: "mic.fill")
                        .font(.system(size: 28, weight: .semibold))
                        .foregroundStyle(Color.onPrimary)
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text("Record a debrief")
                        .font(.system(size: 20, weight: .semibold))
                        .tracking(-0.3)
                        .foregroundStyle(Color.ink)
                    Text("Talk it through after a meeting. Docket turns it into tasks with dates.")
                        .font(.system(size: 14))
                        .foregroundStyle(Color.ink2)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            .padding(Space.lg)
            .hairlineCard()
        }
        .buttonStyle(PressScale(scale: 0.98))
        .accessibilityLabel("Record a debrief")
    }
}

// MARK: - Result card

/// What a recording turned into: "Added 3 tasks" with their real dates. ✕ removes a task, a tap edits it,
/// Undo all drops them. Edits are free while the card is open (the capture is held until it closes).
struct DebriefCardView: View {
    let job: VoiceJob
    @EnvironmentObject private var model: AppModel
    @State private var editing: DebriefTask?

    var body: some View {
        VStack(alignment: .leading, spacing: Space.md) {
            HStack(alignment: .firstTextBaseline) {
                Eyebrow("Voice note · \(PhoneFmt.dayTime(job.recordedAt)) · \(PhoneFmt.clock(job.duration))")
                    .lineLimit(1)
                Spacer(minLength: Space.sm)
                Button {
                    model.voice.closeCard()
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
            TaskComposer(initialTitle: task.title, initialDue: task.dueDate, initialHasTime: task.dueHasTime,
                         heading: "Edit task", confirmTitle: "Save",
                         onRemove: { model.voice.removeTask(task.id) }) { title, due, hasTime in
                var changed = task
                changed.title = title
                changed.dueDate = due
                changed.dueHasTime = hasTime
                model.voice.updateTask(changed)
            }
            .presentationDetents([.medium, .large])
            .presentationBackground(Color.paper)
        }
    }

    @ViewBuilder
    private var content: some View {
        switch job.status {
        case .recording, .processing:
            HStack(spacing: Space.sm) {
                ProgressView().tint(Color.ink2)
                Text("Turning it into tasks…").textStyle(.headline).foregroundStyle(Color.ink)
            }
            transcriptPreview
        case .offline:
            statusLine(icon: "icloud.slash", text: model.voice.isOnline
                       ? "Saved. \(job.message ?? "Gemini couldn't be reached.") Docket tries again shortly."
                       : "Saved. Will turn into tasks when you're back online.")
            transcriptPreview
            footer(saved: false)
        case .handedToMac where job.debrief == nil || job.message != nil:
            if let message = job.message {
                Text(message).font(.system(size: 15)).foregroundStyle(Color.ink2).fixedSize(horizontal: false, vertical: true)
            }
            statusLine(icon: "desktopcomputer", text: "Saved. Your Mac will turn it into tasks.")
            transcriptPreview
            footer(saved: false)
        default:
            result
        }
    }

    @ViewBuilder
    private var result: some View {
        let tasks = job.tasks
        VStack(alignment: .leading, spacing: 4) {
            Text(job.debrief?.title.isEmpty == false ? job.debrief!.title : "Voice note")
                .textStyle(.title3)
                .foregroundStyle(Color.ink)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Text(tasks.isEmpty ? "No tasks added" : "Added \(PhoneFmt.count(tasks.count, "task"))")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(tasks.isEmpty ? Color.ink2 : Tone.success.fg)
                Spacer()
                if !tasks.isEmpty {
                    Button("Undo all") {
                        withAnimation(Motion.snappy) { model.voice.undoAll(job.id) }
                        Haptics.select()
                    }
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Color.ink2)
                }
            }
        }
        if !tasks.isEmpty {
            VStack(spacing: 0) {
                ForEach(Array(tasks.enumerated()), id: \.element.id) { index, task in
                    if index > 0 { Hairline().padding(.leading, 30) }
                    DebriefTaskRow(task: task, edit: { editing = task }) {
                        withAnimation(Motion.snappy) { model.voice.removeTask(task.id) }
                        Haptics.select()
                    }
                }
            }
            .padding(.vertical, Space.xxs)
            .overlay(alignment: .top) { Hairline() }
            .overlay(alignment: .bottom) { Hairline() }
        }
        if let summary = job.debrief?.summary, !summary.isEmpty {
            Text(summary)
                .font(.system(size: 14.5))
                .foregroundStyle(Color.ink2)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
        }
        footer(saved: true)
    }

    private func statusLine(icon: String, text: String) -> some View {
        Label {
            Text(text).font(.system(size: 16, weight: .semibold)).foregroundStyle(Color.ink)
                .fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: icon).font(.system(size: 15, weight: .semibold)).foregroundStyle(Color.ink2)
        }
    }

    @ViewBuilder
    private var transcriptPreview: some View {
        let words = (job.debrief?.transcript).flatMap { $0.isEmpty ? nil : $0 } ?? job.transcript
        if !words.isEmpty {
            Text("“\(words)”")
                .font(.system(size: 14.5))
                .italic()
                .foregroundStyle(Color.ink2)
                .lineLimit(3)
        }
    }

    private func footer(saved: Bool) -> some View {
        HStack {
            if saved {
                Label("Saved to Memory", systemImage: "checkmark.circle")
                    .font(.system(size: 13.5, weight: .semibold))
                    .foregroundStyle(Color.ink2)
            }
            Spacer()
            Button("Done") { model.voice.closeCard() }
                .buttonStyle(SecondaryPill(height: 34))
        }
        .padding(.top, Space.xxs)
    }
}

private struct DebriefTaskRow: View {
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
                    VStack(alignment: .leading, spacing: 2) {
                        Text(task.title)
                            .font(.system(size: 15.5, weight: .medium))
                            .foregroundStyle(Color.ink)
                            .multilineTextAlignment(.leading)
                            .lineLimit(2)
                        if let sub = subtitle {
                            Text(sub).font(.system(size: 12.5, weight: .medium)).foregroundStyle(Color.ink3).lineLimit(2)
                        }
                    }
                    Spacer(minLength: Space.sm)
                    if let due = task.dueDate {
                        DueText(date: due, hasTime: task.dueHasTime)
                    } else {
                        Text("No date")
                            .font(.system(size: 14, weight: .medium))
                            .foregroundStyle(Color.ink3)
                            .fixedSize()
                    }
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

    private var subtitle: String? {
        var parts: [String] = []
        if let waiting = task.waitingOn { parts.append("Waiting on \(waiting)") }
        if let list = task.listName { parts.append(list) }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}
