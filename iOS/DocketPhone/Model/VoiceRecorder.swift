import AVFoundation
import Foundation
import UIKit

/// Records a debrief: AAC (ADTS, 16 kHz mono, ~32 kbps ≈ 15 MB an hour) written as it's spoken, so even a
/// crash keeps everything up to the last second; a live transcript and level meter while it runs.
///
/// Keeps going with the screen locked (background audio). A phone call or Siri pauses it and keeps what was
/// recorded; Resume carries on in the same file. Stops by itself at 60 minutes.
@MainActor
final class VoiceRecorder: ObservableObject {
    enum State: Equatable {
        case idle
        case recording
        /// Interrupted (a call) or paused by hand; the text says which.
        case paused(String)
    }

    /// What a finished recording hands over.
    struct Recording {
        var url: URL
        var duration: TimeInterval
        var transcript: String
        var startedAt: Date
    }

    @Published private(set) var state: State = .idle
    @Published private(set) var elapsed: TimeInterval = 0
    /// 0…1 now, and the last few seconds for the meter (oldest first).
    @Published private(set) var level: Double = 0
    @Published private(set) var levels: [Double] = Array(repeating: 0, count: VoiceRecorder.meterBars)
    @Published private(set) var transcript = ""
    /// Set when there's no live transcript (speech recognition off or unavailable for the language).
    @Published private(set) var transcriptNote: String?
    /// A problem worth a sentence (no microphone access, couldn't start).
    @Published var problem: String?
    /// Set when the recorder stopped itself (60 minutes, audio system reset): the owner saves it.
    @Published private(set) var autoStopped = false

    static let maxDuration: TimeInterval = 60 * 60
    static let meterBars = 36
    nonisolated static let sampleRate: Double = 16_000

    var isActive: Bool { state != .idle }
    var isRecording: Bool { state == .recording }
    var isPaused: Bool { if case .paused = state { true } else { false } }

    private let engine = AVAudioEngine()
    private var sink: AudioSink?
    private var transcriber: LiveTranscriber?
    private var timer: Timer?
    private var startedAt = Date()
    private var observers: [NSObjectProtocol] = []
    private var isDemo = false

    // MARK: Start

    /// Asks for the microphone (and speech recognition, once), then records to `url`.
    func start(to url: URL) async -> Bool {
        guard state == .idle else { return true }
        problem = nil
        autoStopped = false
        guard await AVAudioApplication.requestRecordPermission() else {
            problem = "Microphone access is off for Docket. Turn it on in Settings → Privacy → Microphone."
            return false
        }
        let speechAllowed = await LiveTranscriber.requestAuthorization()
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playAndRecord, mode: .default, options: [.allowBluetoothHFP, .defaultToSpeaker])
            try session.setActive(true)
            let sink = try AudioSink(url: url, maxFrames: AVAudioFramePosition(Self.maxDuration * Self.sampleRate))
            self.sink = sink
            transcript = ""
            transcriber = LiveTranscriber { [weak self] text in
                Task { @MainActor in self?.transcript = text }
            }
            transcriptNote = transcriber == nil
                ? (speechAllowed ? "No live transcript for \(SpeechLanguage.name(for: SpeechLanguage.current)) on this iPhone. The recording is what counts."
                                 : "Live transcript is off. The recording is what counts.")
                : nil
            sink.transcriber = transcriber
            transcriber?.start()
            try startEngine()
        } catch {
            sink = nil
            transcriber?.cancel()
            transcriber = nil
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
            problem = "Couldn't start recording: \(error.localizedDescription)"
            return false
        }
        startedAt = Date()
        elapsed = 0
        levels = Array(repeating: 0, count: Self.meterBars)
        state = .recording
        observe()
        UIApplication.shared.isIdleTimerDisabled = true
        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        return true
    }

    /// Installs the tap for the input's current format and starts the engine.
    private func startEngine() throws {
        let input = engine.inputNode
        input.removeTap(onBus: 0)
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            throw NSError(domain: "Docket", code: 1, userInfo: [NSLocalizedDescriptionKey: "No microphone is available."])
        }
        guard let sink else { return }
        try sink.prepare(for: format)
        input.installTap(onBus: 0, bufferSize: 4096, format: format) { buffer, _ in
            sink.process(buffer)
        }
        engine.prepare()
        try engine.start()
    }

    // MARK: Pause, resume, stop

    func pause(_ reason: String = "Paused.") {
        guard state == .recording else { return }
        engine.pause()
        sink?.isPaused = true
        state = .paused(reason)
        level = 0
    }

    func resume() {
        guard isPaused else { return }
        if isDemo { state = .recording; return }
        do {
            try AVAudioSession.sharedInstance().setActive(true)
            sink?.isPaused = false
            try startEngine()
            state = .recording
            problem = nil
        } catch {
            problem = "Couldn't carry on recording: \(error.localizedDescription). Stop to save what you have."
        }
    }

    /// Stops and hands over the file, or nil when nothing usable was recorded (under half a second).
    func stop() async -> Recording? {
        guard state != .idle else { return nil }
        if isDemo {
            state = .idle
            isDemo = false
            return nil
        }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        let words = await transcriber?.finish() ?? transcript
        let sink = self.sink
        let duration = sink?.duration ?? elapsed
        let url = sink?.close()
        tearDown()
        guard let url else { return nil }
        guard duration >= 0.5 else {
            try? FileManager.default.removeItem(at: url)
            return nil
        }
        return Recording(url: url, duration: duration, transcript: words, startedAt: startedAt)
    }

    /// Stops and throws the recording away.
    func discard() {
        guard state != .idle else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        transcriber?.cancel()
        if let url = sink?.close() { try? FileManager.default.removeItem(at: url) }
        tearDown()
    }

    private func tearDown() {
        timer?.invalidate()
        timer = nil
        sink = nil
        transcriber = nil
        observers.forEach(NotificationCenter.default.removeObserver)
        observers = []
        level = 0
        state = .idle
        isDemo = false
        UIApplication.shared.isIdleTimerDisabled = false
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    private func tick() {
        guard let sink else { return }
        elapsed = sink.duration
        guard state == .recording else { return }
        let now = sink.takeLevel()
        level = now
        levels.removeFirst()
        levels.append(now)
        if elapsed >= Self.maxDuration { autoStopped = true }
    }

    // MARK: Interruptions

    private func observe() {
        let center = NotificationCenter.default
        let session = AVAudioSession.sharedInstance()
        observers.append(center.addObserver(forName: AVAudioSession.interruptionNotification, object: session, queue: .main) { [weak self] note in
            let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
            let type = raw.flatMap(AVAudioSession.InterruptionType.init(rawValue:))
            Task { @MainActor in
                guard let self else { return }
                switch type {
                case .began?:
                    // A call, Siri, an alarm: keep what's recorded, wait for the user.
                    if self.state == .recording {
                        self.pause("Paused for a call. Everything up to here is saved.")
                    }
                case .ended?:
                    break
                default:
                    break
                }
            }
        })
        observers.append(center.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main) { [weak self] _ in
            // Headphones plugged in or out: the input format changed, so start again on the new one.
            Task { @MainActor in
                guard let self, self.state == .recording else { return }
                do { try self.startEngine() } catch { self.pause("The microphone changed. Tap Resume to carry on.") }
            }
        })
        observers.append(center.addObserver(forName: AVAudioSession.mediaServicesWereResetNotification, object: session, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.autoStopped = true }
        })
    }

    // MARK: Demo

    /// Screenshots: a recording in progress with words on screen, no microphone.
    func showDemo(elapsed: TimeInterval, transcript: String) {
        isDemo = true
        self.elapsed = elapsed
        self.transcript = transcript
        levels = (0..<Self.meterBars).map { i in
            let x = Double(i)
            return max(0.08, min(1, 0.45 + 0.3 * sin(x * 0.9) + 0.2 * sin(x * 2.3 + 1)))
        }
        level = levels.last ?? 0.5
        state = .recording
    }
}

/// Runs on the audio thread: converts the microphone's buffers to 16 kHz mono, writes them to the file,
/// feeds the live transcript and measures the level.
private final class AudioSink: @unchecked Sendable {
    private let lock = NSLock()
    private var file: AVAudioFile?
    private var converter: AVAudioConverter?
    private let outputFormat: AVAudioFormat
    private let url: URL
    private let maxFrames: AVAudioFramePosition
    private var peak: Float = 0
    var transcriber: LiveTranscriber?
    var isPaused = false

    init(url: URL, maxFrames: AVAudioFramePosition) throws {
        self.url = url
        self.maxFrames = maxFrames
        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
            AVSampleRateKey: VoiceRecorder.sampleRate,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: 32_000,
        ]
        // ".aac" makes this an ADTS stream: every frame stands alone, so a cut-off file still plays.
        let file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        self.file = file
        outputFormat = file.processingFormat
    }

    func prepare(for input: AVAudioFormat) throws {
        lock.lock(); defer { lock.unlock() }
        guard let converter = AVAudioConverter(from: input, to: outputFormat) else {
            throw NSError(domain: "Docket", code: 2, userInfo: [NSLocalizedDescriptionKey: "This microphone's format isn't supported."])
        }
        self.converter = converter
    }

    var duration: TimeInterval {
        lock.lock(); defer { lock.unlock() }
        return Double(file?.length ?? written) / outputFormat.sampleRate
    }

    private var written: AVAudioFramePosition = 0

    /// The loudest moment since the last call, 0…1.
    func takeLevel() -> Double {
        lock.lock(); defer { lock.unlock() }
        let value = peak
        peak = 0
        // -50 dB … 0 dB → 0 … 1
        let db = 20 * log10(max(value, 0.000_01))
        return Double(max(0, min(1, (db + 50) / 50)))
    }

    func process(_ buffer: AVAudioPCMBuffer) {
        lock.lock()
        defer { lock.unlock() }
        guard !isPaused, let file, let converter else { return }
        transcriber?.append(buffer)
        if let data = buffer.floatChannelData, buffer.frameLength > 0 {
            var loudest: Float = 0
            let samples = data[0]
            for i in stride(from: 0, to: Int(buffer.frameLength), by: 4) { loudest = max(loudest, abs(samples[i])) }
            peak = max(peak, loudest)
        }
        guard file.length < maxFrames else { return }
        let ratio = outputFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 64
        guard let out = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity) else { return }
        var supplied = false
        var error: NSError?
        converter.convert(to: out, error: &error) { _, status in
            if supplied {
                status.pointee = .noDataNow
                return nil
            }
            supplied = true
            status.pointee = .haveData
            return buffer
        }
        guard error == nil, out.frameLength > 0 else { return }
        try? file.write(from: out)
        written = file.length
    }

    /// Finishes the file and returns where it is.
    func close() -> URL {
        lock.lock(); defer { lock.unlock() }
        if #available(iOS 18.0, *) { file?.close() }
        written = file?.length ?? written
        file = nil
        converter = nil
        transcriber = nil
        return url
    }
}
