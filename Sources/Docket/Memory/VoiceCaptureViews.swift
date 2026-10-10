import AppKit
import Combine
import MemoryKit
import SwiftUI

// MARK: - Model

/// A voice note recorded on the Mac, from the mic button to the result: recording (level, time, live words),
/// working (Gemini listening), then what it made ("Added 3 tasks", each with ✕, and Undo all). Lives with the
/// capture panel, so closing the panel mid-way never loses a recording: it's saved, and announced instead.
@MainActor
final class VoiceCaptureModel: ObservableObject {
    enum Phase: Equatable {
        case idle
        case starting
        case recording
        case working
        case result
        /// The message is a sentence; `privacy` is the System Settings page that fixes it, if any.
        case failed(String, privacy: URL?)
    }

    /// What the result card shows.
    struct Result: Equatable {
        var itemID: UUID
        var title: String
        /// The tasks still there (✕ and Undo all take them out).
        var taskIDs: [UUID]
        /// How many tasks the note made.
        var made: Int
        var notice: String?
        var undone = false
    }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var result: Result?
    let recorder = VoiceRecorder()
    let intake: VoiceIntake
    /// The panel is on screen. When it isn't, a finished note is announced (`announce`).
    var isPresented = false
    var announce: ((VoiceOutcome) -> Void)?
    private var cancellables = Set<AnyCancellable>()

    init(intake: VoiceIntake) {
        self.intake = intake
        // The longest recording ended by itself.
        recorder.$isRecording
            .removeDuplicates()
            .sink { [weak self] recording in
                guard let self, !recording, self.phase == .recording else { return }
                DispatchQueue.main.async { self.stop() }
            }
            .store(in: &cancellables)
    }

    var isActive: Bool { phase != .idle }
    /// Recording or working: the panel stays up even when another window takes the focus.
    var isBusy: Bool { phase == .starting || phase == .recording || phase == .working }

    func start() {
        switch phase {
        case .idle, .result, .failed: break
        default: return
        }
        result = nil
        phase = .starting
        Task {
            do {
                try await recorder.start()
                phase = .recording
            } catch {
                let e = error as? VoiceError ?? .couldNotStart(error.localizedDescription)
                phase = .failed(e.errorDescription ?? "Couldn't start recording.",
                                privacy: e == .micDenied ? VoiceError.microphoneSettingsURL : nil)
            }
        }
    }

    /// Stops and turns the recording into tasks and a memory.
    func stop() {
        guard phase == .recording else { return }
        phase = .working
        guard let recording = recorder.stop() else {
            phase = .failed("Nothing was recorded.", privacy: nil)
            return
        }
        let intake = intake
        Task {
            do {
                let outcome = try await intake.processRecording(recording.url, liveTranscript: recording.transcript,
                                                               recordedAt: recording.startedAt)
                show(outcome)
                if !isPresented { announce?(outcome) }
            } catch {
                phase = .failed("Couldn't save the recording: \(error.localizedDescription)", privacy: nil)
            }
        }
    }

    /// Throws the recording away (only while recording).
    func cancel() {
        if phase == .recording || phase == .starting { recorder.cancel() }
        if phase != .working { reset() }
    }

    func show(_ outcome: VoiceOutcome) {
        let title = intake.library.item(outcome.itemID)?.displayTitle ?? outcome.debrief.title
        result = Result(itemID: outcome.itemID, title: title, taskIDs: outcome.taskIDs, made: outcome.taskIDs.count, notice: outcome.notice)
        phase = .result
    }

    /// ✕ on one task.
    func remove(_ taskID: UUID) {
        guard var r = result, r.taskIDs.contains(taskID) else { return }
        intake.deleteTasks([taskID])
        r.taskIDs.removeAll { $0 == taskID }
        if r.taskIDs.isEmpty && r.made > 0 { r.undone = true }
        result = r
    }

    /// Undo all: the tasks go; the recording stays in Memory.
    func undoAll() {
        guard var r = result, !r.taskIDs.isEmpty else { return }
        intake.deleteTasks(r.taskIDs)
        r.taskIDs = []
        r.undone = true
        result = r
    }

    func reset() {
        phase = .idle
        result = nil
    }

    /// The panel's height for what's showing.
    var panelHeight: CGFloat {
        switch phase {
        case .idle: return VoiceCaptureLayout.base
        case .recording: return VoiceCaptureLayout.recording
        case .result: return VoiceCaptureLayout.result(rows: result.map { $0.undone ? 0 : $0.taskIDs.count } ?? 0,
                                                      notice: result?.notice != nil)
        default: return VoiceCaptureLayout.base
        }
    }

    /// Screenshots: a recording in progress without the microphone.
    func debugShowRecording(levels: [Float], elapsed: TimeInterval, transcript: String) {
        recorder.debugShow(levels: levels, elapsed: elapsed, transcript: transcript)
        result = nil
        phase = .recording
    }
}

/// The capture panel's heights.
enum VoiceCaptureLayout {
    static let base: CGFloat = 172
    static let recording: CGFloat = 224
    static let maxRows = 5
    static let rowHeight: CGFloat = 40

    /// Header, the task rows (at most five, then "and 2 more"), an optional notice, and the footer.
    static func result(rows: Int, notice: Bool) -> CGFloat {
        let shown = min(rows, maxRows)
        var h: CGFloat = 40 + 32 + 12 + 36
        if rows > 0 { h += CGFloat(shown) * rowHeight + 12 }
        if rows > maxRows { h += 22 }
        if notice { h += 40 }
        if rows == 0 { h += 26 }
        return max(base, h)
    }
}

// MARK: - The card

/// What the capture panel shows while a voice note is under way (replaces the text field).
struct VoiceCaptureCard: View {
    @EnvironmentObject var store: Store
    @EnvironmentObject var app: AppState
    @ObservedObject var model: VoiceCaptureModel
    @ObservedObject var recorder: VoiceRecorder
    var close: () -> Void

    init(model: VoiceCaptureModel, close: @escaping () -> Void) {
        self.model = model
        self.recorder = model.recorder
        self.close = close
    }

    var body: some View {
        Group {
            switch model.phase {
            case .idle:
                EmptyView()
            case .starting:
                status(spinner: true, title: "Starting the microphone…", detail: "")
            case .recording:
                recording
            case .working:
                status(spinner: true, title: "Listening to your note…",
                       detail: model.intake.ai() == nil ? "Saving it to Memory" : "Finding the tasks and dates in it")
            case .result:
                if let r = model.result { VoiceResultView(model: model, result: r, close: close) }
            case .failed(let message, let privacy):
                failed(message, privacy: privacy)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    // MARK: Recording

    private var recording: some View {
        VStack(alignment: .leading, spacing: Space.md) {
            HStack(alignment: .firstTextBaseline, spacing: Space.sm) {
                RecordingDot()
                Text("Recording")
                    .textStyle(.subheadStrong)
                    .foregroundStyle(Color.ink)
                Spacer()
                Text(Fmt.clock(recorder.elapsed))
                    .font(.system(size: 26, weight: .bold))
                    .monospacedDigit()
                    .tracking(-0.6)
                    .foregroundStyle(Color.ink)
            }
            LevelMeter(levels: recorder.levels)
                .frame(height: 40)
            Text(VoiceCaptureCard.liveLine(recorder.transcript))
                .font(.system(size: 14))
                .foregroundStyle(recorder.transcript.isEmpty ? Color.ink3 : Color.ink2)
                .lineLimit(2)
                .frame(maxWidth: .infinity, minHeight: 38, alignment: .topLeading)
            HStack(spacing: Space.sm) {
                Text("↩ or esc stops and saves")
                    .textStyle(.caption)
                    .foregroundStyle(Color.ink3)
                Spacer()
                Button("Discard") { model.cancel(); close() }
                    .buttonStyle(SecondaryPill(height: 32))
                    .help("Throw this recording away")
                Button { model.stop() } label: { Label("Stop", systemImage: "stop.fill") }
                    .buttonStyle(PrimaryPill(height: 32))
                    .help("Stop and turn it into tasks and a memory")
            }
        }
    }

    static let liveLimit = 150

    /// The end of what was heard, or what to say before anything was.
    static func liveLine(_ transcript: String) -> String {
        let t = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return "Say who you met, what was agreed and what you need to do, with dates." }
        // The last two lines' worth, starting on a word.
        guard t.count > liveLimit else { return t }
        let tail = t.suffix(liveLimit)
        let start = tail.firstIndex(of: " ").map { tail.index(after: $0) } ?? tail.startIndex
        return "…" + tail[start...]
    }

    private func status(spinner: Bool, title: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: Space.md) {
            HStack(spacing: Space.md) {
                if spinner { ProgressView().controlSize(.small) }
                Text(title)
                    .font(.system(size: 22, weight: .bold))
                    .tracking(-0.4)
                    .foregroundStyle(Color.ink)
            }
            if !detail.isEmpty {
                Text(detail).textStyle(.subhead).foregroundStyle(Color.ink2)
            }
        }
        .padding(.top, Space.md)
    }

    private func failed(_ message: String, privacy: URL?) -> some View {
        VStack(alignment: .leading, spacing: Space.md) {
            HStack(alignment: .top, spacing: Space.sm) {
                Image(systemName: "mic.slash")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Color.dangerText)
                Text(message)
                    .textStyle(.subheadStrong)
                    .foregroundStyle(Color.ink)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            HStack(spacing: Space.sm) {
                Spacer()
                if let privacy {
                    Button("Open System Settings") { NSWorkspace.shared.open(privacy) }
                        .buttonStyle(SecondaryPill(height: 32))
                }
                Button("Done") { model.reset(); close() }
                    .buttonStyle(PrimaryPill(height: 32))
            }
        }
    }
}

/// "Added 3 tasks": each with its real date and ✕, Undo all, and the memory it made.
struct VoiceResultView: View {
    @EnvironmentObject var store: Store
    @EnvironmentObject var app: AppState
    @ObservedObject var model: VoiceCaptureModel
    let result: VoiceCaptureModel.Result
    var close: () -> Void

    var body: some View {
        let tasks = result.undone ? [] : result.taskIDs.compactMap(store.task)
        VStack(alignment: .leading, spacing: Space.md) {
            HStack(spacing: Space.sm) {
                Image(systemName: result.undone ? "arrow.uturn.backward" : "checkmark")
                    .font(.system(size: 10, weight: .heavy))
                    .foregroundStyle(Color.onPrimary)
                    .frame(width: 20, height: 20)
                    .background(Circle().fill(Color.primaryFill))
                Text(result.undone ? "Tasks removed" : VoiceText.headline(tasks: tasks.count))
                    .font(.system(size: 22, weight: .bold))
                    .tracking(-0.4)
                    .foregroundStyle(Color.ink)
                Spacer()
                if !tasks.isEmpty {
                    Button("Undo all") { withAnimation(Motion.snappy) { model.undoAll() } }
                        .buttonStyle(SecondaryPill(height: 30))
                        .help("Take these tasks back out (the recording stays in Memory)")
                }
            }
            .frame(height: 32)

            if !tasks.isEmpty {
                VStack(spacing: 0) {
                    ForEach(tasks.prefix(VoiceCaptureLayout.maxRows)) { t in row(t) }
                    if tasks.count > VoiceCaptureLayout.maxRows {
                        Text("and \(tasks.count - VoiceCaptureLayout.maxRows) more in Docket")
                            .textStyle(.caption)
                            .foregroundStyle(Color.ink3)
                            .frame(maxWidth: .infinity, minHeight: 22, alignment: .leading)
                    }
                }
            } else {
                Text(result.undone ? "The recording is still in Memory." : "No tasks in it. The recording is in Memory.")
                    .textStyle(.subhead)
                    .foregroundStyle(Color.ink2)
                    .frame(minHeight: 14)
            }

            if let notice = result.notice {
                MemoryNote(icon: "key", text: notice) { EmptyView() }
            }

            HStack(spacing: Space.sm) {
                Image(systemName: "waveform")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color.ink2)
                Text("“\(result.title)” is in Memory")
                    .textStyle(.subhead)
                    .foregroundStyle(Color.ink2)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Button("Open") {
                    app.reveal(memory: result.itemID)
                    model.reset()
                    close()
                }
                .buttonStyle(PressScale())
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Color.ink)
                .help("Open the voice note in Memory")
                Spacer(minLength: Space.sm)
                Button("Done") { model.reset(); close() }
                    .buttonStyle(PrimaryPill(height: 32))
                    .keyboardShortcut(.defaultAction)
            }
            .frame(height: 36)
        }
    }

    private func row(_ t: TaskItem) -> some View {
        HStack(spacing: Space.md) {
            Button {
                app.reveal(task: t.id, in: store)
                model.reset()
                close()
            } label: {
                HStack(spacing: Space.md) {
                    Text(t.title)
                        .font(.system(size: 14.5, weight: .semibold))
                        .foregroundStyle(Color.ink)
                        .lineLimit(1)
                    Spacer(minLength: Space.sm)
                    Text(VoiceText.when(t, now: app.clock))
                        .font(.system(size: 13, weight: .bold))
                        .monospacedDigit()
                        .foregroundStyle(t.dueDate == nil ? Color.ink3 : Color.ink2)
                        .fixedSize()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(PressScale(scale: 0.99))
            .help("Open it in Docket to change it")
            Button { withAnimation(Motion.snappy) { model.remove(t.id) } } label: { Image(systemName: "xmark") }
                .buttonStyle(IconButtonStyle(size: 24))
                .help("Remove this task")
                .accessibilityLabel("Remove \(t.title)")
        }
        .frame(height: VoiceCaptureLayout.rowHeight)
        .overlay(alignment: .bottom) { Rectangle().fill(Color.hair).frame(height: 1) }
    }
}

// MARK: - Pieces

/// The input level as a row of rounded bars, newest on the right.
struct LevelMeter: View {
    let levels: [Float]

    var body: some View {
        GeometryReader { geo in
            let count = max(1, levels.count)
            let gap: CGFloat = 3
            let width = max(1, (geo.size.width - gap * CGFloat(count - 1)) / CGFloat(count))
            HStack(alignment: .center, spacing: gap) {
                ForEach(Array(levels.enumerated()), id: \.offset) { _, level in
                    Capsule()
                        .fill(level > 0.02 ? Color.ink : Color.hairStrong)
                        .frame(width: width, height: max(3, CGFloat(level) * geo.size.height))
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
        .accessibilityHidden(true)
    }
}

/// A small red dot that breathes while recording.
struct RecordingDot: View {
    @State private var dim = false

    var body: some View {
        Circle()
            .fill(Color.danger)
            .frame(width: 9, height: 9)
            .opacity(dim ? 0.35 : 1)
            .onAppear {
                guard !DebugSnapshot.isActive else { return }
                withAnimation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true)) { dim = true }
            }
            .accessibilityLabel("Recording")
    }
}
