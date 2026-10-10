import Foundation

/// Builds one running transcript from Apple's speech recognition, which isn't one continuous stream:
/// - after a long pause the recognizer may start a new utterance without saying so: its partial results then
///   hold only the new words, so taking them as "the text so far" would wipe what was said before;
/// - a request ends (a pause, a time limit) and the app starts another: the old task can still deliver a late
///   result, which must not be added again.
/// Feed every result to `receive` with the request's `generation`; call `restart(generation:)` when a new request
/// starts. Pure value type so both apps share it and it's tested without a microphone.
public struct TranscriptAccumulator: Sendable, Equatable {
    /// Words from finished utterances and earlier requests.
    public private(set) var committed = ""
    /// The utterance being heard now (revised by every partial result).
    public private(set) var current = ""
    /// The request results are accepted from; older ones are ignored.
    public private(set) var generation = 0

    public init() {}

    /// Everything heard so far.
    public var text: String { Self.join(committed, current) }

    /// Starts over for a new recording.
    public mutating func reset() {
        committed = ""
        current = ""
        generation += 1
    }

    /// A new recognition request takes over: what was heard is kept, and results from older requests are
    /// ignored from now on. Returns the new generation to tag the request's results with.
    @discardableResult
    public mutating func restart() -> Int {
        commit()
        generation += 1
        return generation
    }

    /// One recognition result from request `generation`. `start` is when its first segment begins in the
    /// request's audio (seconds), when the recognizer reports it (partial results often say 0).
    public mutating func receive(_ text: String, generation: Int, start: TimeInterval? = nil, isFinal: Bool) {
        guard generation == self.generation else { return }
        let heard = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !heard.isEmpty {
            if !current.isEmpty, Self.isNewUtterance(heard, after: current, start: start, previousStart: currentStart) {
                commit()
            }
            if current.isEmpty { currentStart = start }
            current = heard
        }
        if isFinal { commit() }
    }

    private var currentStart: TimeInterval?

    /// Moves the current utterance into `committed` (once: a repeat of the words already at the end is dropped).
    public mutating func commit() {
        defer { current = ""; currentStart = nil }
        guard !current.isEmpty else { return }
        if Self.words(committed).suffix(Self.words(current).count) == Self.words(current)[...] { return }
        committed = Self.join(committed, current)
    }

    /// True when `next` isn't a revision of `previous` but the start of a new utterance: the recognizer's
    /// timestamps moved on, or the text shrank to well under what was there and doesn't begin the same way.
    static func isNewUtterance(_ next: String, after previous: String, start: TimeInterval?, previousStart: TimeInterval?) -> Bool {
        if let start, let previousStart, start > 0, start > previousStart + 1 { return true }
        let a = words(previous), b = words(next)
        guard !a.isEmpty, !b.isEmpty else { return false }
        let sameStart = Array(a.prefix(2)) == Array(b.prefix(2)) || a.first == b.first
        return !sameStart && b.count <= max(1, a.count * 3 / 5)
    }

    static func words(_ text: String) -> [String] {
        text.lowercased().split { !$0.isLetter && !$0.isNumber && $0 != "'" }.map(String.init)
    }

    static func join(_ a: String, _ b: String) -> String {
        [a, b].filter { !$0.isEmpty }.joined(separator: " ")
    }
}
