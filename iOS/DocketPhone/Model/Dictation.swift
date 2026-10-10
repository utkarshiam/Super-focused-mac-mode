import AVFoundation
import Foundation
import NaturalLanguage
import UIKit

/// Talk instead of typing in a text field (Ask, the Capture note): words appear as you speak; stop to keep
/// them. Uses on-device speech recognition in the Speech language from Settings. Nothing is recorded.
@MainActor
final class Dictation: ObservableObject {
    @Published private(set) var isActive = false
    /// What's been heard so far in this go.
    @Published private(set) var text = ""
    /// 0…1, for a small level ring.
    @Published private(set) var level: Double = 0

    /// Stops by itself after this long, in case it's forgotten.
    static let maxDuration: TimeInterval = 120

    private let engine = AVAudioEngine()
    private var transcriber: LiveTranscriber?
    private var levelBox = LevelBox()
    private var timer: Timer?
    private var startedAt = Date()

    /// Starts listening. Returns a sentence when it can't.
    func start() async -> String? {
        guard !isActive else { return nil }
        guard await AVAudioApplication.requestRecordPermission() else {
            return "Microphone access is off for Docket. Turn it on in Settings → Privacy → Microphone."
        }
        guard await LiveTranscriber.requestAuthorization() else {
            return "Speech recognition is off for Docket. Turn it on in Settings → Privacy → Speech Recognition."
        }
        Speaker.shared.stop()
        let transcriber = LiveTranscriber { [weak self] words in
            Task { @MainActor in
                guard let self, self.isActive else { return }
                self.text = words
            }
        }
        guard let transcriber else {
            return "Dictation isn't available for \(SpeechLanguage.name(for: SpeechLanguage.current)) right now. Try another Speech language in Settings."
        }
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playAndRecord, mode: .default, options: [.allowBluetoothHFP, .defaultToSpeaker])
            try session.setActive(true)
            let input = engine.inputNode
            input.removeTap(onBus: 0)
            let format = input.outputFormat(forBus: 0)
            guard format.sampleRate > 0 else { return "No microphone is available." }
            let box = LevelBox()
            levelBox = box
            input.installTap(onBus: 0, bufferSize: 2048, format: format) { buffer, _ in
                transcriber.append(buffer)
                box.measure(buffer)
            }
            transcriber.start()
            engine.prepare()
            try engine.start()
        } catch {
            transcriber.cancel()
            engine.inputNode.removeTap(onBus: 0)
            return "Couldn't start listening: \(error.localizedDescription)"
        }
        self.transcriber = transcriber
        text = ""
        startedAt = Date()
        isActive = true
        Haptics.tap()
        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.isActive else { return }
                self.level = self.levelBox.take()
                if Date().timeIntervalSince(self.startedAt) > Self.maxDuration { _ = await self.stop() }
            }
        }
        return nil
    }

    /// Stops and returns everything heard.
    func stop() async -> String {
        guard isActive else { return text }
        isActive = false
        timer?.invalidate()
        timer = nil
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        let words = await transcriber?.finish() ?? text
        transcriber = nil
        level = 0
        text = words
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        return words.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func cancel() {
        guard isActive else { return }
        isActive = false
        timer?.invalidate()
        timer = nil
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        transcriber?.cancel()
        transcriber = nil
        text = ""
        level = 0
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }
}

/// Peak level from the audio thread.
private final class LevelBox: @unchecked Sendable {
    private let lock = NSLock()
    private var peak: Float = 0

    func measure(_ buffer: AVAudioPCMBuffer) {
        guard let data = buffer.floatChannelData, buffer.frameLength > 0 else { return }
        var loudest: Float = 0
        for i in stride(from: 0, to: Int(buffer.frameLength), by: 4) { loudest = max(loudest, abs(data[0][i])) }
        lock.lock(); peak = max(peak, loudest); lock.unlock()
    }

    func take() -> Double {
        lock.lock(); defer { lock.unlock() }
        let value = peak
        peak = 0
        let db = 20 * log10(max(value, 0.000_01))
        return Double(max(0, min(1, (db + 50) / 50)))
    }
}

/// Reads answers aloud. One at a time; [n] citation markers are skipped.
@MainActor
final class Speaker: NSObject, ObservableObject, AVSpeechSynthesizerDelegate {
    static let shared = Speaker()

    /// Which text is being read (an id the caller chose), or nil.
    @Published private(set) var speakingID: UUID?

    private let synthesizer = AVSpeechSynthesizer()

    override init() {
        super.init()
        synthesizer.delegate = self
    }

    func toggle(_ text: String, id: UUID) {
        if speakingID == id {
            stop()
        } else {
            speak(text, id: id)
        }
    }

    func speak(_ text: String, id: UUID) {
        synthesizer.stopSpeaking(at: .immediate)
        let clean = Self.speakable(text)
        guard !clean.isEmpty else { return }
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio, options: [.duckOthers])
        try? AVAudioSession.sharedInstance().setActive(true)
        let utterance = AVSpeechUtterance(string: clean)
        utterance.voice = Self.voice(for: clean)
        speakingID = id
        synthesizer.speak(utterance)
    }

    func stop() {
        synthesizer.stopSpeaking(at: .immediate)
        speakingID = nil
    }

    /// "Harbor pushed back [1]." → "Harbor pushed back."
    static func speakable(_ text: String) -> String {
        text.replacingOccurrences(of: #"\s*\[\d+(?:\s*,\s*\d+)*\]"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// A voice for the text's language, preferring the Speech language's region ("en-IN").
    static func voice(for text: String) -> AVSpeechSynthesisVoice? {
        let chosen = SpeechLanguage.current
        let language = NLLanguageRecognizer.dominantLanguage(for: text)?.rawValue ?? "en"
        if !chosen.isEmpty, chosen.hasPrefix(language), let voice = AVSpeechSynthesisVoice(language: chosen) { return voice }
        let region = Locale.current.region?.identifier ?? "US"
        return AVSpeechSynthesisVoice(language: "\(language)-\(region)") ?? AVSpeechSynthesisVoice(language: language)
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor in
            self.speakingID = nil
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        Task { @MainActor in self.speakingID = nil }
    }
}
