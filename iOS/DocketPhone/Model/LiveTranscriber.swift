import AVFoundation
import Foundation
import Speech

/// The language on-device speech recognition listens for. Only a hint: Gemini writes the real transcript
/// in whatever language was spoken (Hindi, English or a mix).
enum SpeechLanguage {
    static let defaultsKey = "speechLanguage"

    /// "" is the device's own language.
    static let choices: [(id: String, name: String)] = [
        ("", "Device default"),
        ("en-IN", "English (India)"),
        ("hi-IN", "Hindi"),
        ("en-US", "English (US)"),
        ("en-GB", "English (UK)"),
        ("es-ES", "Spanish"),
        ("fr-FR", "French"),
        ("de-DE", "German"),
        ("pt-BR", "Portuguese (Brazil)"),
        ("ja-JP", "Japanese"),
    ]

    static var current: String {
        get { UserDefaults.standard.string(forKey: defaultsKey) ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: defaultsKey) }
    }

    static func name(for id: String) -> String {
        choices.first { $0.id == id }?.name ?? Locale.current.localizedString(forIdentifier: id) ?? id
    }

    /// The locale to recognise: the chosen one, else the device's.
    static var locale: Locale { current.isEmpty ? Locale.current : Locale(identifier: current) }
}

/// Speech-to-text while audio is coming in, shown as words appear. On-device when the language supports it.
/// Recognition tasks end on their own now and then (long pauses, the server's one-minute limit), so a new
/// one starts and the text so far is kept. Fed from the audio thread; reports on the main queue.
final class LiveTranscriber: @unchecked Sendable {
    private let recognizer: SFSpeechRecognizer
    private let lock = NSLock()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    /// Text from finished tasks.
    private var committed = ""
    /// The running task's best guess.
    private var partial = ""
    private var finishing = false
    private var finalWaiters: [CheckedContinuation<Void, Never>] = []
    private let onText: @Sendable (String) -> Void

    /// Nil when there's no recognizer for the language (or speech recognition is off).
    init?(locale: Locale = SpeechLanguage.locale, onText: @escaping @Sendable (String) -> Void) {
        guard SFSpeechRecognizer.authorizationStatus() == .authorized,
              let recognizer = SFSpeechRecognizer(locale: locale) ?? SFSpeechRecognizer(), recognizer.isAvailable else { return nil }
        self.recognizer = recognizer
        self.onText = onText
        recognizer.defaultTaskHint = .dictation
    }

    /// Asks once; recording works without it (just no live words).
    static func requestAuthorization() async -> Bool {
        switch SFSpeechRecognizer.authorizationStatus() {
        case .authorized: return true
        case .denied, .restricted: return false
        default:
            return await withCheckedContinuation { continuation in
                SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0 == .authorized) }
            }
        }
    }

    var text: String {
        lock.lock(); defer { lock.unlock() }
        return Self.join(committed, partial)
    }

    func start() {
        lock.lock(); defer { lock.unlock() }
        startTaskLocked()
    }

    private func startTaskLocked() {
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.taskHint = .dictation
        if recognizer.supportsOnDeviceRecognition { request.requiresOnDeviceRecognition = true }
        request.addsPunctuation = true
        self.request = request
        partial = ""
        task = recognizer.recognitionTask(with: request) { [weak self] result, error in
            self?.handle(result: result, error: error, for: request)
        }
    }

    private func handle(result: SFSpeechRecognitionResult?, error: Error?, for request: SFSpeechAudioBufferRecognitionRequest) {
        lock.lock()
        guard request === self.request else { lock.unlock(); return }
        if let result { partial = result.bestTranscription.formattedString }
        let ended = (result?.isFinal ?? false) || error != nil
        if ended {
            committed = Self.join(committed, partial)
            partial = ""
            if finishing {
                self.request = nil
                task = nil
                let waiters = finalWaiters
                finalWaiters = []
                lock.unlock()
                waiters.forEach { $0.resume() }
                report()
                return
            }
            // Ended by itself while still listening: carry on with a fresh task.
            startTaskLocked()
        }
        lock.unlock()
        report()
    }

    private func report() {
        let text = self.text
        let onText = self.onText
        DispatchQueue.main.async { onText(text) }
    }

    /// Audio thread.
    func append(_ buffer: AVAudioPCMBuffer) {
        lock.lock()
        let request = self.request
        lock.unlock()
        request?.append(buffer)
    }

    /// Stops listening and returns everything heard, waiting briefly for the last words.
    func finish(timeout: TimeInterval = 1.2) async -> String {
        guard let request = beginFinishing() else { return text }
        request.endAudio()
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            if addWaiter(continuation) {
                DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { [weak self] in self?.resumeWaiters() }
            } else {
                continuation.resume()
            }
        }
        cancel()
        return text
    }

    private func beginFinishing() -> SFSpeechAudioBufferRecognitionRequest? {
        lock.lock(); defer { lock.unlock() }
        finishing = true
        return request
    }

    /// False when the last result already came in.
    private func addWaiter(_ continuation: CheckedContinuation<Void, Never>) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard request != nil else { return false }
        finalWaiters.append(continuation)
        return true
    }

    private func resumeWaiters() {
        lock.lock()
        let waiters = finalWaiters
        finalWaiters = []
        lock.unlock()
        waiters.forEach { $0.resume() }
    }

    /// Stops at once (the text so far stays readable).
    func cancel() {
        lock.lock()
        finishing = true
        committed = Self.join(committed, partial)
        partial = ""
        let task = self.task
        self.task = nil
        request = nil
        let waiters = finalWaiters
        finalWaiters = []
        lock.unlock()
        task?.cancel()
        waiters.forEach { $0.resume() }
    }

    private static func join(_ a: String, _ b: String) -> String {
        let a = a.trimmingCharacters(in: .whitespaces), b = b.trimmingCharacters(in: .whitespaces)
        if a.isEmpty { return b }
        if b.isEmpty { return a }
        return a + " " + b
    }
}
