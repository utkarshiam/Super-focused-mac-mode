import Foundation
import MemoryKit

/// The Ask field at the top of Memory: what's typed, the answer, and the search behind it. Typing filters
/// the library as you go; Return searches it properly (by meaning too, with a key) and, with a key, asks
/// Gemini, which answers only from what's saved and cites it. Without a key Return just searches.
@MainActor
final class MemoryAskModel: ObservableObject {
    enum Phase: Equatable {
        case idle
        case asking
        case answered
        /// No Gemini key: the question became a search.
        case noKey
        /// The message is a full sentence; `settings`: the fix is in Settings → AI.
        case failed(String, settings: Bool)
    }

    /// The field's text.
    @Published var query = ""
    @Published private(set) var phase: Phase = .idle
    @Published private(set) var answer: MemoryAnswer?
    /// The question the library's search results are for (cleared when the text changes from it).
    @Published private(set) var searched: String?
    /// Best matches for `searched`, best first.
    @Published private(set) var hits: [MemoryHit] = []
    /// The search for `searched` is still running.
    @Published private(set) var searching = false

    /// "Worth revisiting" was dismissed: it stays away until Docket is opened again.
    @Published var resurfacingDismissed = false

    /// Earlier questions and answers, so a follow-up ("and her?") makes sense. Cleared by "Ask another".
    private(set) var history: [AskTurn] = []
    private var generation = 0
    private var work: Task<Void, Never>?

    /// The library's search results are showing (Return was pressed and the text hasn't changed since).
    var showsSearch: Bool { searched != nil && searched == query.trimmingCharacters(in: .whitespacesAndNewlines) }

    /// Searches for `question` and, with AI, asks it. A follow-up keeps the conversation going.
    func ask(_ question: String, library: MemoryLibrary, ai: MemoryAI?, scope: MemoryFilter = MemoryFilter()) {
        let q = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return }
        work?.cancel()
        generation += 1
        let run = generation
        query = q
        searched = q
        hits = []
        searching = true
        phase = ai == nil ? .noKey : .asking
        let history = self.history
        work = Task { [weak self] in
            let found = await library.search(q, ai: ai, filter: scope, limit: 60)
            guard let self, run == self.generation else { return }
            self.hits = found
            self.searching = false
            guard let ai else { return }
            do {
                let answer = try await MemoryAsk(ai: ai).ask(q, history: history, in: library)
                guard run == self.generation else { return }
                self.answer = answer
                self.history = Array((history + [answer.turn]).suffix(4))
                self.phase = .answered
            } catch {
                guard run == self.generation, !Task.isCancelled else { return }
                let e = error as? MemoryAIError ?? .network(error.localizedDescription)
                self.phase = .failed(e.errorDescription ?? "Something went wrong. Try again.", settings: e.needsSettings)
            }
        }
    }

    /// "Ask another": empties the field and forgets the answer and the conversation.
    func clear() {
        work?.cancel()
        generation += 1
        query = ""
        phase = .idle
        answer = nil
        searched = nil
        hits = []
        searching = false
        history = []
    }

    /// The text changed from what was searched: back to filtering as you type.
    func textChanged() {
        guard searched != nil, !showsSearch else { return }
        searched = nil
        hits = []
        searching = false
        if phase == .noKey { phase = .idle }
    }

    /// Screenshots: an answer without Gemini.
    func debugShow(_ answer: MemoryAnswer, hits: [MemoryHit]) {
        work?.cancel()
        generation += 1
        query = answer.question
        searched = answer.question
        self.hits = hits
        self.answer = answer
        phase = .answered
    }
}
