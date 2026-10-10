import AVFoundation
import Foundation
import Speech

/// Why recording or dictation couldn't start, in a sentence.
enum VoiceError: LocalizedError, Equatable {
    /// Unit tests and screenshot mode never touch the microphone.
    case notAllowed
    /// The binary isn't inside Docket.app, so macOS would refuse (and quit it) without the usage text.
    case notInApp
    case micDenied
    case speechDenied
    case speechUnavailable
    case couldNotStart(String)

    var errorDescription: String? {
        switch self {
        case .notAllowed: "Recording is off here."
        case .notInApp: "Recording works in Docket.app (build it with scripts/build.sh)."
        case .micDenied: "Docket can't use the microphone. Allow it in System Settings → Privacy & Security → Microphone."
        case .speechDenied: "Docket can't use speech recognition. Allow it in System Settings → Privacy & Security → Speech Recognition."
        case .speechUnavailable: "Speech recognition isn't available right now."
        case .couldNotStart(let detail): "Couldn't start recording. \(detail)"
        }
    }

    /// The fix is in System Settings.
    var opensPrivacySettings: Bool { self == .micDenied || self == .speechDenied }

    static let microphoneSettingsURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")!
    static let speechSettingsURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_SpeechRecognition")!
}

/// Access to the microphone and speech recognition, asked for the first time they're needed. Never in unit
/// tests or screenshot mode, and never from a bare binary (macOS ends an app that asks without saying why).
@MainActor
enum VoicePermissions {
    static var isAllowed: Bool { !GeminiClient.isUnitTesting && !DebugSnapshot.isActive }

    static func has(_ key: String) -> Bool { Bundle.main.object(forInfoDictionaryKey: key) != nil }

    static func microphone() async throws {
        guard isAllowed else { throw VoiceError.notAllowed }
        guard has("NSMicrophoneUsageDescription") else { throw VoiceError.notInApp }
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return
        case .notDetermined:
            guard await AVCaptureDevice.requestAccess(for: .audio) else { throw VoiceError.micDenied }
        default: throw VoiceError.micDenied
        }
    }

    /// True when live transcription may run (asking the first time).
    static func speech() async -> Bool {
        guard isAllowed, has("NSSpeechRecognitionUsageDescription") else { return false }
        switch SFSpeechRecognizer.authorizationStatus() {
        case .authorized: return true
        case .notDetermined:
            return await withCheckedContinuation { done in
                SFSpeechRecognizer.requestAuthorization { done.resume(returning: $0 == .authorized) }
            }
        default: return false
        }
    }
}

// MARK: - Live transcript

/// On-device speech recognition from the microphone (Apple's, no network when the language supports it), as
/// rough text while someone speaks. Server recognition stops after about a minute, so a new request picks up
/// where the last one ended.
@MainActor
final class LiveTranscriber {
    /// The text so far (called on the main actor).
    var onText: ((String) -> Void)?
    /// The input level, 0…1 (dictation shows it; the recorder has its own meter).
    var onLevel: ((Float) -> Void)?

    private let engine = AVAudioEngine()
    private var recognizer: SFSpeechRecognizer?
    private let box = RequestBox()
    private var task: SFSpeechRecognitionTask?
    private var committed = ""
    private var current = ""
    private var emptyRestarts = 0
    private(set) var isRunning = false

    var text: String { [committed, current].filter { !$0.isEmpty }.joined(separator: " ") }

    /// Starts listening. Throws when speech recognition isn't available or the input won't start.
    func start(locale: Locale = .current) throws {
        guard !isRunning else { return }
        guard let recognizer = SFSpeechRecognizer(locale: locale) ?? SFSpeechRecognizer(), recognizer.isAvailable else {
            throw VoiceError.speechUnavailable
        }
        self.recognizer = recognizer
        committed = ""
        current = ""
        emptyRestarts = 0
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { throw VoiceError.couldNotStart("No microphone input.") }
        input.installTap(onBus: 0, bufferSize: 2048, format: format, block: Self.tap(box: box) { [weak self] level in
            DispatchQueue.main.async { self?.onLevel?(level) }
        })
        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            throw VoiceError.couldNotStart(error.localizedDescription)
        }
        isRunning = true
        beginRequest()
    }

    func stop() {
        guard isRunning else { return }
        isRunning = false
        engine.stop()
        engine.inputNode.removeTap(onBus: 0)
        box.request?.endAudio()
        box.request = nil
        task?.cancel()
        task = nil
    }

    private func beginRequest() {
        guard isRunning, let recognizer else { return }
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        if recognizer.supportsOnDeviceRecognition { request.requiresOnDeviceRecognition = true }
        request.addsPunctuation = true
        box.request = request
        task = recognizer.recognitionTask(with: request, resultHandler: Self.handler { [weak self] text, isFinal in
            DispatchQueue.main.async { self?.received(text, isFinal: isFinal) }
        })
    }

    private func received(_ text: String?, isFinal: Bool) {
        guard isRunning else { return }
        if let text { current = text }
        if isFinal {
            // The recognizer stopped (a server time limit, a long pause): keep what it heard, listen on. One
            // that keeps ending without hearing anything (an error) is left alone.
            if current.isEmpty {
                emptyRestarts += 1
            } else {
                committed = committed.isEmpty ? current : committed + " " + current
                emptyRestarts = 0
            }
            current = ""
            if emptyRestarts < 3 { beginRequest() }
        }
        onText?(self.text)
    }

    // Built outside the main actor: these run on audio and recognition threads.
    private nonisolated static func tap(box: RequestBox, level: @escaping @Sendable (Float) -> Void) -> AVAudioNodeTapBlock {
        { buffer, _ in
            box.request?.append(buffer)
            level(VoiceRecorder.level(of: buffer))
        }
    }

    private nonisolated static func handler(_ send: @escaping @Sendable (String?, Bool) -> Void) -> (SFSpeechRecognitionResult?, Error?) -> Void {
        { result, error in
            send(result?.bestTranscription.formattedString, result?.isFinal ?? (error != nil))
        }
    }
}

/// The request the tap feeds, swapped when recognition restarts.
private final class RequestBox: @unchecked Sendable {
    private let lock = NSLock()
    private var _request: SFSpeechAudioBufferRecognitionRequest?
    var request: SFSpeechAudioBufferRecognitionRequest? {
        get { lock.lock(); defer { lock.unlock() }; return _request }
        set { lock.lock(); _request = newValue; lock.unlock() }
    }
}

// MARK: - Recorder

/// Records a voice note: AAC in an .m4a file (small enough to send to Gemini as is), a level meter, the
/// time so far, and a live transcript when speech recognition is allowed. The file lands in a temporary
/// folder; `VoiceIntake` moves it into the library.
@MainActor
final class VoiceRecorder: ObservableObject {
    /// Recent input levels, 0…1, oldest first (the meter's bars).
    @Published private(set) var levels: [Float] = Array(repeating: 0, count: VoiceRecorder.levelCount)
    @Published private(set) var elapsed: TimeInterval = 0
    /// What on-device recognition heard so far ("" when it's off).
    @Published private(set) var transcript = ""
    @Published private(set) var isRecording = false

    struct Recording: Equatable {
        var url: URL
        var startedAt: Date
        var duration: TimeInterval
        var transcript: String
    }

    static let levelCount = 56
    /// Recordings stop by themselves after this long.
    static let maxDuration: TimeInterval = 30 * 60

    private var recorder: AVAudioRecorder?
    private var timer: Timer?
    private var transcriber: LiveTranscriber?
    private var startedAt: Date?

    /// Asks for the microphone (and speech recognition) the first time, then records.
    func start() async throws {
        guard !isRecording else { return }
        try await VoicePermissions.microphone()
        let speech = await VoicePermissions.speech()
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("Docket-voice-\(UUID().uuidString).m4a")
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 44_100,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: 64_000,
            AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue,
        ]
        let recorder: AVAudioRecorder
        do {
            recorder = try AVAudioRecorder(url: url, settings: settings)
        } catch {
            throw VoiceError.couldNotStart(error.localizedDescription)
        }
        recorder.isMeteringEnabled = true
        guard recorder.record(forDuration: Self.maxDuration) else { throw VoiceError.couldNotStart("The microphone didn't start.") }
        self.recorder = recorder
        startedAt = Date()
        levels = Array(repeating: 0, count: Self.levelCount)
        elapsed = 0
        transcript = ""
        isRecording = true
        let t = Timer(timeInterval: 0.05, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
        if speech {
            let live = LiveTranscriber()
            live.onText = { [weak self] text in self?.transcript = text }
            // Live words are a bonus: the recording goes on without them.
            if (try? live.start()) != nil { transcriber = live }
        }
    }

    private func tick() {
        guard let recorder else { return }
        guard recorder.isRecording else {
            // Reached the longest recording: the model notices `isRecording` and stops.
            isRecording = false
            return
        }
        recorder.updateMeters()
        elapsed = recorder.currentTime
        push(Self.normalized(decibels: recorder.averagePower(forChannel: 0)))
    }

    private func push(_ level: Float) {
        levels.removeFirst()
        levels.append(level)
    }

    /// Stops and returns the recording (nil when nothing was recorded).
    func stop() -> Recording? {
        guard let recorder, let startedAt else { return nil }
        let duration = recorder.currentTime > 0 ? recorder.currentTime : elapsed
        recorder.stop()
        finish()
        let words = transcript
        guard FileManager.default.fileExists(atPath: recorder.url.path) else { return nil }
        return Recording(url: recorder.url, startedAt: startedAt, duration: duration, transcript: words)
    }

    /// Stops and throws the recording away.
    func cancel() {
        guard let recorder else { return }
        recorder.stop()
        recorder.deleteRecording()
        finish()
    }

    private func finish() {
        timer?.invalidate()
        timer = nil
        transcriber?.stop()
        transcriber = nil
        recorder = nil
        startedAt = nil
        isRecording = false
    }

    /// Screenshots: a recording in progress without the microphone.
    func debugShow(levels: [Float], elapsed: TimeInterval, transcript: String) {
        self.levels = Array((Array(repeating: 0, count: Self.levelCount) + levels).suffix(Self.levelCount))
        self.elapsed = elapsed
        self.transcript = transcript
    }

    // MARK: Levels

    /// -50 dB (quiet room) … 0 dB as 0…1, eased so speech fills the meter.
    nonisolated static func normalized(decibels db: Float) -> Float {
        guard db.isFinite else { return 0 }
        let linear = max(0, min(1, (db + 50) / 50))
        return powf(linear, 1.6)
    }

    /// The level of an input buffer, 0…1.
    nonisolated static func level(of buffer: AVAudioPCMBuffer) -> Float {
        guard let data = buffer.floatChannelData, buffer.frameLength > 0 else { return 0 }
        let samples = data[0]
        var sum: Float = 0
        for i in 0..<Int(buffer.frameLength) { sum += samples[i] * samples[i] }
        let rms = (sum / Float(buffer.frameLength)).squareRoot()
        return normalized(decibels: 20 * log10(max(rms, 1e-7)))
    }
}

// MARK: - Reading answers aloud

/// Reads text aloud with the system voice (Memory's answers). One at a time; `stop` ends it.
@MainActor
final class SpeechReader: NSObject, ObservableObject, AVSpeechSynthesizerDelegate {
    static let shared = SpeechReader()

    /// What's being read (an id the caller chose), nil when quiet.
    @Published private(set) var speakingID: String?
    private let synthesizer = AVSpeechSynthesizer()

    override init() {
        super.init()
        synthesizer.delegate = self
    }

    func speak(_ text: String, id: String) {
        stop()
        let words = VoiceText.speakable(text)
        guard !words.isEmpty, VoicePermissions.isAllowed else { return }
        speakingID = id
        synthesizer.speak(AVSpeechUtterance(string: words))
    }

    func stop() {
        if synthesizer.isSpeaking { synthesizer.stopSpeaking(at: .immediate) }
        speakingID = nil
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor in self.speakingID = nil }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        Task { @MainActor in if !self.synthesizer.isSpeaking { self.speakingID = nil } }
    }
}
