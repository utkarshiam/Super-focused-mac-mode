import Foundation
import MemoryKit

/// Demo mode (`DOCKET_PHONE_DEMO=1`) for screenshots: a throwaway Docket folder seeded with
/// `MemoryLibrary.debugSeed` and published the way the Mac does, a few tasks, a few recent captures
/// and a canned Ask answer. Nothing touches the user's real folder, Keychain or the network.
///
/// Launch options: `DOCKET_PHONE_TAB=capture|record|debrief|memory|ask|today|settings`,
/// `DOCKET_PHONE_ITEM=first|<index>|<words in a title>` opens that item.
enum DemoSeed {
    static var baseURL: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("DocketPhoneDemo", isDirectory: true)
    }

    struct Seeded {
        var root: URL
        var records: [CaptureRecord]
    }

    @MainActor
    static func prepare(local: LocalStore, now: Date = Date()) async -> Seeded {
        let fm = FileManager.default
        try? fm.removeItem(at: baseURL)
        let root = baseURL.appendingPathComponent("Docket", isDirectory: true)
        let library = MemoryLibrary(directory: baseURL.appendingPathComponent("MacLibrary", isDirectory: true), saveDelay: 0)
        library.debugSeed(now: now, lenses: [.founder, .manager])
        library.flush()
        // Published a little while ago, like a Mac that synced this afternoon.
        let published = now.addingTimeInterval(-14 * 60)
        try? await PhoneBridge(root: root).publish(library, tasks: tasks(now: now), now: published)
        try? fm.createDirectory(at: PhoneBridge(root: root).inboxURL, withIntermediateDirectories: true)
        return Seeded(root: root, records: records(now: now))
    }

    static func tasks(now: Date) -> [TaskSnapshot] {
        let cal = Calendar.current
        let today = cal.startOfDay(for: now)
        func day(_ offset: Int, hour: Int? = nil, minute: Int = 0) -> Date {
            let d = cal.date(byAdding: .day, value: offset, to: today)!
            guard let hour else { return d }
            return cal.date(bySettingHour: hour, minute: minute, second: 0, of: d)!
        }
        // Two meetings later on this day (whatever time the demo runs), so the day shows times.
        let nextHour = cal.dateInterval(of: .hour, for: now).map { $0.end } ?? now
        let lastSlot = cal.date(bySettingHour: 23, minute: 30, second: 0, of: today)!
        let soon = min(nextHour.addingTimeInterval(3600), cal.date(bySettingHour: 23, minute: 0, second: 0, of: today)!)
        let later = min(soon.addingTimeInterval(2.5 * 3600), lastSlot)
        func id(_ n: Int) -> UUID { UUID(uuidString: String(format: "00000000-0000-4000-8000-%012d", n))! }
        return [
            TaskSnapshot(id: id(1), title: "Send Q3 board deck to Alex Kim", dueDate: day(-1), estimateMinutes: 45, priority: 3, listName: "Board"),
            TaskSnapshot(id: id(2), title: "Review Acme security questionnaire", dueDate: soon, dueHasTime: true, estimateMinutes: 30, priority: 2, listName: "Sales"),
            TaskSnapshot(id: id(3), title: "Reply to Priya about the term sheet", dueDate: day(0), estimateMinutes: 15, priority: 3, listName: "Seed round"),
            TaskSnapshot(id: id(4), title: "1:1 with Maya Chen", dueDate: later, dueHasTime: true, estimateMinutes: 30, listName: "Team"),
            TaskSnapshot(id: id(5), title: "Write the double-charge postmortem", dueDate: day(2), estimateMinutes: 60, priority: 2, listName: "Billing API"),
            TaskSnapshot(id: id(6), title: "Pricing page: first draft", scheduledDate: day(3), estimateMinutes: 90, listName: "Pricing refresh"),
            TaskSnapshot(id: id(7), title: "Book the offsite venue", dueDate: day(5, hour: 11), dueHasTime: true, estimateMinutes: 20),
        ]
    }

    static func records(now: Date) -> [CaptureRecord] {
        func ago(_ minutes: Double) -> Date { now.addingTimeInterval(-minutes * 60) }
        return [
            CaptureRecord(id: UUID(), kind: .task, title: "Call the bank about the SAFE wire", detail: nil, createdAt: ago(3), state: .waiting),
            CaptureRecord(id: UUID(), kind: .voice, title: "Voice note", detail: "0:42", createdAt: ago(55), state: .received),
            CaptureRecord(id: UUID(), kind: .link, title: "What makes a pricing page convert", detail: "example.com", createdAt: ago(60 * 5), state: .received),
            CaptureRecord(id: UUID(), kind: .photo, title: "Whiteboard after the onboarding review", detail: nil, createdAt: ago(60 * 26), state: .received),
            CaptureRecord(id: UUID(), kind: .note, title: "Leo: partner pilot could start in November", detail: nil, createdAt: ago(60 * 50), state: .received),
        ]
    }

    // MARK: Voice

    /// What the live transcript shows in the recording screenshot (on-device recognition, rough).
    static let recordingTranscript = "Abhi Mehta Traders se nikla hoon. Rohan ne bola ki revised quote Friday tak chahiye, "
        + "with the eight percent volume discount. Monday ko gyarah baje Priya ko call karna hai about the sample batch. "
        + "Rohan will send the signed PO by Wednesday, mujhe bas follow up karna hai"

    static let debriefTranscript = "Abhi Mehta Traders se nikla hoon. Rohan ne bola ki revised quote Friday tak chahiye, with the 8% "
        + "volume discount. Monday ko 11 baje Priya ko call karna hai about the sample batch. Rohan will send the signed PO by "
        + "Wednesday, mujhe bas follow up karna hai."

    /// The result card's debrief: Hindi and English mixed, three tasks with real dates, one waiting on Rohan.
    static func debrief(recordedAt: Date) -> VoiceDebrief {
        let cal = Calendar.current
        func next(_ weekday: Int, hour: Int? = nil) -> Date {
            let day = cal.nextDate(after: cal.startOfDay(for: recordedAt), matching: DateComponents(weekday: weekday),
                                   matchingPolicy: .nextTime) ?? recordedAt
            guard let hour else { return cal.startOfDay(for: day) }
            return cal.date(bySettingHour: hour, minute: 0, second: 0, of: day) ?? day
        }
        return VoiceDebrief(
            transcript: debriefTranscript,
            title: "Pricing follow-up with Mehta Traders",
            summary: "Rohan wants a revised quote with an 8% volume discount; he'll send the signed PO once it's in.",
            keyTakeaways: ["Revised quote needs the 8% volume discount", "Signed PO follows the quote"],
            people: ["Rohan Mehta", "Priya Nair"], projects: ["Mehta Traders"], tags: ["sales", "pricing"],
            moments: [Moment(kind: .promise, text: "Rohan will send the signed PO", who: "Rohan Mehta", due: next(4), direction: .theirs)],
            tasks: [
                DebriefTask(title: "Send revised quote to Rohan Mehta", notes: "Include the 8% volume discount.", dueDate: next(6),
                            estimateMinutes: 30, priority: 3, listName: "Sales", people: ["Rohan Mehta"]),
                DebriefTask(title: "Call Priya Nair about the sample batch", dueDate: next(2, hour: 11), dueHasTime: true,
                            estimateMinutes: 30, people: ["Priya Nair"]),
                DebriefTask(title: "Follow up on the signed PO", dueDate: next(4), waitingOn: "Rohan Mehta", listName: "Sales",
                            people: ["Rohan Mehta"]),
            ],
            recordedAt: recordedAt, madeBy: "iPhone")
    }

    /// A ready answer for the Ask screenshot, built through MemoryAsk's own retrieval and parser.
    static func answer(search: MemorySearch, snapshot: LibrarySnapshot) async -> MemoryAnswer? {
        let question = "What did investors push back on?"
        let sources = await MemoryAsk(ai: DemoAI()).retrieve(question, history: [], search: search, filter: MemoryFilter())
        guard let seed = sources.firstIndex(where: { $0.title.hasPrefix("Seed round") }) else { return nil }
        let n = seed + 1
        var text = "Harbor Capital pushed back on two things: CAC payback wasn't clear, and the market slide felt too broad [\(n)]. "
            + "They did like the 92% logo retention and the self-serve motion [\(n)]."
        var citations: [[String: Any]] = [["source": n, "quote": "Main pushback: CAC payback is unclear and the market slide feels too broad."]]
        if let market = sources.firstIndex(where: { $0.title.hasPrefix("Market sizing") }) {
            text += " A bottom-up TAM of about $5.8B is the clearest answer to the market question [\(market + 1)]."
            citations.append(["source": market + 1])
        }
        let json: [String: Any] = [
            "answer": text,
            "answerable": true,
            "citations": citations,
            "followUps": ["What did Priya promise to send?", "How should I show CAC payback?", "Why did we pick a SAFE?"],
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: json) else { return nil }
        return try? MemoryAsk.parse(data, question: question, sources: sources)
    }
}

/// The demo's stand-in for Gemini: canned answers, no network, no embeddings.
struct DemoAI: MemoryAI {
    var embeddingModel: String { "demo-offline" }
    var embeddingDimensions: Int { 768 }

    func generateJSON(system: String, prompt: String, schema: MemoryJSON, parts: [MemoryInlinePart]) async throws -> Data {
        try await Task.sleep(nanoseconds: 700_000_000)
        let json: [String: Any] = [
            "answer": "This is demo mode, so answers are canned. With your Gemini key, Docket answers from the sources it found, citing each one [1].",
            "answerable": true,
            "citations": [["source": 1]],
            "followUps": [String](),
        ]
        return try JSONSerialization.data(withJSONObject: json)
    }

    func embed(_ texts: [String], task: EmbedTask) async throws -> [[Float]] {
        throw MemoryAIError.notConfigured
    }
}
