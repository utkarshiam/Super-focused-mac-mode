import Foundation
import MemoryKit

/// One Ask conversation: questions, answers with [n] citations, follow-ups.
@MainActor
final class AskSession: ObservableObject {
    struct Entry: Identifiable {
        let id = UUID()
        let question: String
        var answer: MemoryAnswer?
        var error: String?
        /// The fix is in Settings (no key, key refused).
        var needsSettings = false

        var isPending: Bool { answer == nil && error == nil }
    }

    @Published private(set) var entries: [Entry] = []
    @Published var draft = ""

    private var task: Task<Void, Never>?

    var isBusy: Bool { entries.last?.isPending ?? false }

    /// Earlier exchanges sent along with a follow-up (the last few answered ones).
    private var history: [AskTurn] {
        Array(entries.compactMap { $0.answer?.turn }.suffix(4))
    }

    func ask(_ question: String, model: AppModel) {
        let q = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty, !isBusy else { return }
        draft = ""
        guard let ai = model.makeAI() else { return }
        guard let search = model.search, let snapshot = model.snapshot else {
            entries.append(Entry(question: q, error: "Your memory hasn't arrived from your Mac yet."))
            return
        }
        let history = self.history
        let entry = Entry(question: q)
        entries.append(entry)
        let id = entry.id
        task = Task {
            do {
                let answer = try await MemoryAsk(ai: ai).ask(q, history: history, search: search,
                                                             profile: snapshot.profile, lenses: snapshot.lenses)
                update(id) { $0.answer = answer }
            } catch is CancellationError {
                entries.removeAll { $0.id == id }
            } catch let error as MemoryAIError {
                update(id) {
                    $0.error = error.errorDescription?.replacingOccurrences(of: "Settings → AI", with: "Settings")
                    $0.needsSettings = error.needsSettings
                }
            } catch {
                update(id) { $0.error = error.localizedDescription }
            }
        }
    }

    func retry(_ entry: Entry, model: AppModel) {
        entries.removeAll { $0.id == entry.id }
        ask(entry.question, model: model)
    }

    func clear() {
        task?.cancel()
        entries = []
    }

    /// Demo mode: a ready-made answer, no network.
    func inject(_ answer: MemoryAnswer) {
        var entry = Entry(question: answer.question)
        entry.answer = answer
        entries = [entry]
    }

    private func update(_ id: UUID, _ change: (inout Entry) -> Void) {
        guard let i = entries.firstIndex(where: { $0.id == id }) else { return }
        change(&entries[i])
    }
}
