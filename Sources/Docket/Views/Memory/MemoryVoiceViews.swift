import AVFoundation
import AppKit
import MemoryKit
import SwiftUI

// MARK: - Asking by voice

/// Dictation into Memory's Ask field: what's said appears in the field as it's heard; stopping asks.
@MainActor
final class AskDictation: ObservableObject {
    @Published private(set) var isListening = false
    /// Why it couldn't listen, in a sentence (nil when fine).
    @Published private(set) var problem: VoiceError?
    private var transcriber: LiveTranscriber?

    func start(into ask: MemoryAskModel) {
        guard !isListening else { return }
        problem = nil
        Task {
            do {
                try await VoicePermissions.microphone()
                guard await VoicePermissions.speech() else { throw VoiceError.speechDenied }
                let live = LiveTranscriber()
                let typed = ask.query.trimmingCharacters(in: .whitespacesAndNewlines)
                live.onText = { [weak ask] text in
                    ask?.query = typed.isEmpty ? text : typed + " " + text
                }
                try live.start()
                transcriber = live
                isListening = true
            } catch {
                problem = error as? VoiceError ?? .couldNotStart(error.localizedDescription)
            }
        }
    }

    func stop() {
        transcriber?.stop()
        transcriber = nil
        isListening = false
    }

    func clearProblem() { problem = nil }
}

/// The mic in the Ask field: listens, and asks when stopped.
struct AskMicButton: View {
    @ObservedObject var dictation: AskDictation
    @ObservedObject var ask: MemoryAskModel
    let submit: (String) -> Void

    var body: some View {
        Button {
            if dictation.isListening {
                dictation.stop()
                submit(ask.query)
            } else {
                dictation.start(into: ask)
            }
        } label: {
            Image(systemName: dictation.isListening ? "stop.fill" : "mic")
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(dictation.isListening ? Color.danger : Color.ink2)
                .frame(width: 32, height: 32)
        }
        .buttonStyle(IconButtonStyle(size: 32, filled: dictation.isListening))
        .help(dictation.isListening ? "Stop and ask (Return)" : "Ask by voice")
        .accessibilityLabel(dictation.isListening ? "Stop and ask" : "Ask by voice")
    }
}

/// Reads an answer aloud (without its [n] markers), or stops it.
struct SpeakAnswerButton: View {
    @ObservedObject private var reader = SpeechReader.shared
    let text: String
    let id: String

    var body: some View {
        let speaking = reader.speakingID == id
        Button {
            speaking ? reader.stop() : reader.speak(text, id: id)
        } label: {
            Label(speaking ? "Stop" : "Read aloud", systemImage: speaking ? "stop.fill" : "speaker.wave.2")
        }
        .buttonStyle(SecondaryPill(height: 30))
        .help(speaking ? "Stop reading" : "Read the answer aloud")
        .onDisappear { if reader.speakingID == id { reader.stop() } }
    }
}

// MARK: - Voice memories

/// Plays a voice memory's recording: play/pause, where it is, how long it is.
@MainActor
final class VoicePlayer: NSObject, ObservableObject, AVAudioPlayerDelegate {
    @Published private(set) var duration: TimeInterval = 0
    @Published private(set) var current: TimeInterval = 0
    @Published private(set) var isPlaying = false
    @Published private(set) var isLoaded = false
    private var player: AVAudioPlayer?
    private var timer: Timer?
    private var loadedURL: URL?

    func load(_ url: URL) {
        guard loadedURL != url else { return }
        stop()
        loadedURL = url
        player = try? AVAudioPlayer(contentsOf: url)
        player?.delegate = self
        player?.prepareToPlay()
        duration = player?.duration ?? 0
        current = 0
        isLoaded = player != nil
    }

    func toggle() {
        guard let player else { return }
        if player.isPlaying {
            player.pause()
            isPlaying = false
            timer?.invalidate()
            timer = nil
        } else {
            if player.currentTime >= player.duration - 0.05 { player.currentTime = 0 }
            player.play()
            isPlaying = true
            let t = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.current = self?.player?.currentTime ?? 0 }
            }
            RunLoop.main.add(t, forMode: .common)
            timer = t
        }
    }

    /// Moves to `fraction` (0…1) of the recording.
    func seek(to fraction: Double) {
        guard let player, duration > 0 else { return }
        player.currentTime = max(0, min(1, fraction)) * duration
        current = player.currentTime
    }

    func stop() {
        player?.stop()
        timer?.invalidate()
        timer = nil
        isPlaying = false
    }

    /// Screenshots: partway through without playing.
    func debugShow(at time: TimeInterval) {
        current = min(time, duration)
    }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in
            self.isPlaying = false
            self.timer?.invalidate()
            self.timer = nil
            self.current = self.duration
        }
    }
}

/// The compact player at the top of a voice memory.
struct VoiceMemoryPlayer: View {
    let url: URL
    @StateObject private var player = VoicePlayer()
    @State private var dragging: Double?

    /// Screenshots: where the player shows itself to be.
    static var debugPosition: TimeInterval?

    var body: some View {
        HStack(spacing: Space.md) {
            Button { player.toggle() } label: {
                Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(Color.onPrimary)
                    .frame(width: 36, height: 36)
                    .background(Circle().fill(Color.primaryFill))
            }
            .buttonStyle(PressScale(scale: 0.92))
            .disabled(!player.isLoaded)
            .help(player.isPlaying ? "Pause" : "Play the recording")
            .accessibilityLabel(player.isPlaying ? "Pause" : "Play")

            VStack(spacing: 6) {
                scrubber
                HStack {
                    Text(Fmt.clock(shownTime)).monospacedDigit()
                    Spacer()
                    Text(Fmt.clock(player.duration)).monospacedDigit()
                }
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(Color.ink2)
            }
        }
        .padding(.horizontal, Space.md)
        .padding(.vertical, 10)
        .hairlineCard(radius: Radius.lg)
        .onAppear {
            player.load(url)
            if let at = Self.debugPosition { player.debugShow(at: at) }
        }
        .onDisappear { player.stop() }
    }

    private var fraction: Double {
        if let dragging { return dragging }
        return player.duration > 0 ? min(1, player.current / player.duration) : 0
    }

    private var shownTime: TimeInterval { dragging.map { $0 * player.duration } ?? player.current }

    private var scrubber: some View {
        GeometryReader { geo in
            let w = geo.size.width
            ZStack(alignment: .leading) {
                Capsule().fill(Color.fillStrong).frame(height: 4)
                Capsule().fill(Color.ink).frame(width: max(4, w * fraction), height: 4)
                Circle().fill(Color.ink).frame(width: 12, height: 12)
                    .offset(x: max(0, min(w - 12, w * fraction - 6)))
            }
            .frame(height: 14)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { v in dragging = max(0, min(1, v.location.x / max(1, w))) }
                .onEnded { v in
                    player.seek(to: max(0, min(1, v.location.x / max(1, w))))
                    dragging = nil
                })
        }
        .frame(height: 14)
        .accessibilityElement()
        .accessibilityLabel("Position")
        .accessibilityValue("\(Fmt.clock(shownTime)) of \(Fmt.clock(player.duration))")
    }
}

/// A voice memory's transcript, a few lines until opened.
struct VoiceTranscriptSection: View {
    let text: String
    @State private var expanded = VoiceTranscriptSection.startsExpanded
    /// Screenshots: open.
    static var startsExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: Space.sm) {
            HStack {
                Eyebrow(text: "Transcript")
                Spacer()
                Button(expanded ? "Show less" : "Show all") { withAnimation(Motion.snappy) { expanded.toggle() } }
                    .buttonStyle(PressScale())
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color.ink2)
            }
            .padding(.horizontal, 4)
            Text(text)
                .font(.system(size: 13.5))
                .lineSpacing(3)
                .foregroundStyle(Color.bodyText)
                .lineLimit(expanded ? nil : 4)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
                .padding(.horizontal, Space.md)
                .padding(.vertical, 10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .hairlineCard(radius: Radius.lg)
        }
    }
}

/// The tasks a voice note made: tick them off, or open one.
struct VoiceTasksSection: View {
    @EnvironmentObject var store: Store
    @EnvironmentObject var app: AppState
    let tasks: [TaskItem]

    var body: some View {
        DetailSection("Tasks from this note") {
            ForEach(tasks) { t in
                HStack(alignment: .center, spacing: Space.md) {
                    CheckCircle(done: t.isCompleted, priority: t.priority, size: 18) { app.toggle(t.id, in: store) }
                    VStack(alignment: .leading, spacing: 2) {
                        Text(t.title)
                            .font(.system(size: 13.5, weight: .semibold))
                            .strikethrough(t.isCompleted, color: .ink3)
                            .foregroundStyle(t.isCompleted ? Color.ink3 : Color.ink)
                            .lineLimit(2)
                        Text(VoiceText.when(t, now: app.clock))
                            .font(.system(size: 12, weight: .bold))
                            .monospacedDigit()
                            .foregroundStyle(t.isOverdue(now: app.clock) ? Color.dangerText : Color.ink2)
                    }
                    Spacer(minLength: Space.sm)
                    Button("Open task") { app.reveal(task: t.id, in: store) }
                        .buttonStyle(PressScale())
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundStyle(Color.ink2)
                        .fixedSize()
                        .help("Open it in your tasks")
                }
                .padding(.horizontal, Space.md)
                .padding(.vertical, 9)
                .overlay(alignment: .bottom) {
                    if t.id != tasks.last?.id {
                        Rectangle().fill(Color.hair).frame(height: 1).padding(.leading, 42)
                    }
                }
            }
        }
    }
}
