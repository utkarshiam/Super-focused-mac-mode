import Foundation
import MemoryKit

/// Memory → tasks: a promise in a memory made into a task ("Add as task"). The user's own promise becomes a
/// task due on its date; one someone owes them becomes a follow-up waiting on that person. Either way the task
/// links back to the memory and the promise (`TaskItem.memoryID`, `momentID`), so the promise isn't offered
/// twice and the task shows "From memory: …".
@MainActor
enum MemoryTasks {
    /// The task for a promise in `item`. Notes say where it came from and who and what it involves.
    static func task(for m: Moment, in item: MemoryItem, calendar: Calendar = .current) -> TaskItem {
        let text = clean(m.text)
        let who = m.who?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let theirs = m.direction == .theirs && !who.isEmpty
        var t = TaskItem(title: theirs ? "Follow up: \(text)" : text)
        if let due = m.due { t.dueDate = calendar.startOfDay(for: due) }
        if theirs { t.waitingOn = who }
        var involved: [String] = []
        for name in [who] + item.people + item.organisations + item.projects where !name.isEmpty {
            if !involved.contains(where: { $0.caseInsensitiveCompare(name) == .orderedSame }) { involved.append(name) }
        }
        var notes = ["From memory: \(item.displayTitle) (\(MemoryText.date(item.createdAt)))"]
        if !involved.isEmpty { notes.append("With " + involved.prefix(4).joined(separator: ", ")) }
        t.notes = notes.joined(separator: "\n")
        t.memoryID = item.id
        t.momentID = m.id
        return t
    }

    /// The task already made from this promise (done or not), if it's still there.
    static func linkedTask(_ momentID: UUID, in store: Store) -> TaskItem? {
        store.tasks.first { $0.momentID == momentID }
    }

    /// Adds the promise's task (once: an existing one is returned instead).
    @discardableResult
    static func add(_ m: Moment, in item: MemoryItem, store: Store) -> TaskItem {
        if let existing = linkedTask(m.id, in: store) { return existing }
        return store.addTask(task(for: m, in: item, calendar: store.calendar))
    }

    /// The open promise in `item` a task title says the same as ("Send Jordan Lee the SOC 2 bridge letter" for
    /// the promise "Send Jordan Lee the SOC 2 bridge letter."), skipping promises in `taken`: tasks from "Turn into
    /// tasks" take over their promise, so it isn't offered again.
    static func promise(matching title: String, in item: MemoryItem, taken: Set<UUID>) -> Moment? {
        let words = Set(keyWords(title))
        guard !words.isEmpty else { return nil }
        var best: (Moment, Double)?
        for m in item.openPromises where !taken.contains(m.id) {
            let other = Set(keyWords(m.text))
            guard !other.isEmpty else { continue }
            let overlap = Double(words.intersection(other).count) / Double(words.union(other).count)
            if overlap >= 0.6, overlap > (best?.1 ?? 0) { best = (m, overlap) }
        }
        return best?.0
    }

    /// Lowercased words without accents, minus the few that don't change the meaning.
    private static func keyWords(_ text: String) -> [String] {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil).lowercased()
            .split { !$0.isLetter && !$0.isNumber }.map(String.init)
            .filter { !["the", "a", "an", "to", "for", "of", "on", "and"].contains($0) }
    }

    /// "Added “Send the bridge letter” for Wed 14 Oct".
    static func toast(_ t: TaskItem, now: Date = Date()) -> String {
        guard let due = t.dueDate else { return "Added “\(t.title)”" }
        return "Added “\(t.title)” for \(Fmt.due(due, hasTime: t.dueHasTime, now: now))"
    }

    /// One line, no closing full stop.
    private static func clean(_ text: String) -> String {
        var s = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        if s.hasSuffix("."), !s.hasSuffix("..") { s.removeLast() }
        return s.isEmpty ? "Follow up" : s
    }
}
