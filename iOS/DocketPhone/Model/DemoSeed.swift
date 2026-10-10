import Foundation
import MemoryKit

/// Demo mode (`DOCKET_PHONE_DEMO=1`) for screenshots: a throwaway Docket folder seeded with
/// `MemoryLibrary.debugSeed` and published the way the Mac does, a few tasks, a few recent captures
/// and a canned Ask answer. Nothing touches the user's real folder, Keychain or the network.
///
/// Launch options: `DOCKET_PHONE_TAB=capture|record|debrief|dictate|dictated|composer|memory|topics|map|ask|today|settings`,
/// `DOCKET_PHONE_ITEM=first|<index>|<words in a title>` opens that item, `DOCKET_PHONE_ENTITY=<name>` opens
/// that topic's or person's page.
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
        // The organised brain (areas, topics, pages, connections, digest, map), offline.
        let brain = MemoryBrain(library: library, saveDelay: 0, autoUpdate: false)
        brain.debugSeed(now: now)
        brain.flush()
        // Published a little while ago, like a Mac that synced this afternoon.
        let published = now.addingTimeInterval(-14 * 60)
        try? await PhoneBridge(root: root).publish(library, tasks: tasks(now: now), listNames: listNames, now: published, brain: brain)
        if let n = ProcessInfo.processInfo.environment["DOCKET_PHONE_MAP_NODES"].flatMap(Int.init) { padMap(root: root, to: n) }
        try? fm.createDirectory(at: PhoneBridge(root: root).inboxURL, withIntermediateDirectories: true)
        return Seeded(root: root, records: records(now: now))
    }

    /// `DOCKET_PHONE_MAP_NODES=<n>` (stress test): pads the published map with made-up people around its
    /// topics until it has n nodes.
    static func padMap(root: URL, to target: Int) {
        let url = PhoneBridge(root: root).snapshotURL
        guard let data = try? Data(contentsOf: url),
              var snapshot = try? MemoryCoding.decoder.decode(LibrarySnapshot.self, from: data),
              var brain = snapshot.brain else { return }
        let topics = brain.map.nodes.filter { $0.kind == .topic }
        guard !topics.isEmpty else { return }
        var seed: UInt64 = 42
        func random() -> Double {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            return Double(seed >> 11) / Double(1 << 53)
        }
        var added: [UUID] = []
        while brain.map.nodes.count < target {
            let topic = topics[Int(random() * Double(topics.count))]
            let angle = random() * 2 * .pi, distance = 0.4 + random() * 1.6
            let id = UUID()
            brain.map.nodes.append(MapNode(id: id, kind: [.person, .organisation, .project][Int(random() * 3)], name: "Contact \(added.count + 1)",
                                           size: 1 + Int(random() * 4), areaID: topic.areaID,
                                           position: MapPoint(x: topic.position.x + cos(angle) * distance, y: topic.position.y + sin(angle) * distance),
                                           firstSeen: topic.firstSeen, lastSeen: topic.lastSeen))
            brain.map.edges.append(MapEdge(a: id, b: topic.id, weight: 0.2 + random() * 0.4, kind: .shared))
            if let other = added.randomElement() { brain.map.edges.append(MapEdge(a: id, b: other, weight: random() * 0.3, kind: .shared)) }
            added.append(id)
        }
        snapshot.brain = brain
        if let out = try? MemoryCoding.encoder.encode(snapshot) { try? out.write(to: url, options: .atomic) }
    }

    static let listNames = ["Board", "Sales", "Seed round", "Team", "Billing API", "Pricing refresh"]

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
            TaskSnapshot(id: id(4), title: "1:1 with Maya Chen", dueDate: later, dueHasTime: true, estimateMinutes: 30, listName: "Team",
                         repeatRule: TaskRepeat(frequency: .weekly, weekdays: [cal.component(.weekday, from: later)]), reminderMinutes: 10),
            TaskSnapshot(id: id(5), title: "Write the double-charge postmortem", dueDate: day(4), scheduledDate: day(2), estimateMinutes: 60, priority: 2,
                         listName: "Billing API"),
            TaskSnapshot(id: id(6), title: "Pricing page: first draft", scheduledDate: day(3), estimateMinutes: 90, listName: "Pricing refresh"),
            TaskSnapshot(id: id(7), title: "Book the offsite venue", dueDate: day(5, hour: 11), dueHasTime: true, estimateMinutes: 20,
                         reminderMinutes: 0, isAlarm: true),
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

    // MARK: Spoken tasks

    /// What "Speak a task" hears in the dictate screenshot.
    static let spokenWords = "Every weekday at 9:30 standup with the team, set an alarm. And work on the board deck on Monday, it's due Friday, block an hour and a half"

    /// The dictated screenshot's two tasks: a repeating weekday standup with an alarm, and one with a Do on day
    /// before its deadline.
    static func spokenTasks(now: Date) -> [DebriefTask] {
        let cal = Calendar.current
        let today = cal.startOfDay(for: now)
        func next(_ weekday: Int, after day: Date) -> Date {
            cal.nextDate(after: day, matching: DateComponents(weekday: weekday), matchingPolicy: .nextTime) ?? day
        }
        // The next weekday morning at 9:30 that's still ahead.
        var standup = cal.date(bySettingHour: 9, minute: 30, second: 0, of: today)!
        while standup <= now || [1, 7].contains(cal.component(.weekday, from: standup)) {
            standup = cal.date(byAdding: .day, value: 1, to: standup)!
        }
        let monday = next(2, after: today)
        let friday = next(6, after: monday)
        return [
            DebriefTask(title: "Team standup", dueDate: standup, dueHasTime: true, estimateMinutes: 15, listName: "Team",
                        reminderMinutes: 0, isAlarm: true, repeatRule: TaskRepeat(frequency: .weekly, weekdays: [2, 3, 4, 5, 6])),
            DebriefTask(title: "Work on the board deck", dueDate: friday, estimateMinutes: 90, priority: 3, listName: "Board",
                        scheduledDate: monday),
        ]
    }

    /// The composer screenshot: every field filled.
    static func composerDraft(now: Date) -> DebriefTask {
        let cal = Calendar.current
        let thursday = cal.nextDate(after: cal.startOfDay(for: now), matching: DateComponents(weekday: 5), matchingPolicy: .nextTime)!
        let friday = cal.date(byAdding: .day, value: 1, to: thursday)!
        let at = cal.date(bySettingHour: 15, minute: 0, second: 0, of: friday)!
        return DebriefTask(title: "Pipeline review with Rohan Mehta", dueDate: at, dueHasTime: true, estimateMinutes: 30, priority: 3,
                           listName: "Sales", scheduledDate: thursday, reminderMinutes: 15, isAlarm: true,
                           repeatRule: TaskRepeat(frequency: .weekly, interval: 2, weekdays: [6]))
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
