import XCTest
@testable import MemoryKit

/// One theme of synthetic items: same label, similar vectors.
struct Theme {
    var label: String
    var count: Int
    var people: [String] = []
    var projects: [String] = []
    var organisations: [String] = []
    var tags: [String] = []
}

/// Builds a library of processed items in themes, with vectors (model "fake-embed", `dims`) that cluster by
/// theme: one random direction per theme plus noise. Deterministic. Items are dated one per day backwards
/// from `day(0)`.
@MainActor
func themedLibrary(_ dir: URL, themes: [Theme], dims: Int = 48, noise: Float = 0.3, seed: UInt64 = 7,
                   withVectors: Bool = true) -> MemoryLibrary {
    let library = MemoryLibrary(directory: dir, saveDelay: 60)
    var rng = SeedRandom(seed: seed)
    let bases = themes.map { _ in (0..<dims).map { _ in rng.nextGaussian() } }
    var n = 0
    library.batch {
        for (t, theme) in themes.enumerated() {
            for i in 0..<theme.count {
                let item = library.add(MemoryItem(title: "\(theme.label) note \(i + 1)", summary: "About \(theme.label.lowercased()), part \(i + 1).",
                                                  people: theme.people, projects: theme.projects, organisations: theme.organisations,
                                                  topics: [theme.label], tags: theme.tags, createdAt: day(-n), processing: .processed))
                n += 1
                if withVectors {
                    let v = (0..<dims).map { bases[t][$0] + noise * rng.nextGaussian() }
                    library.setVector(v, for: item.id, model: "fake-embed")
                }
            }
        }
    }
    return library
}

/// Adds one processed item near a theme's vector (by copying a member's vector with a little noise).
@MainActor
@discardableResult
func addNear(_ library: MemoryLibrary, like other: MemoryItem, title: String, topics: [String] = [], date: Date = day(1),
             seed: UInt64 = 99) -> MemoryItem {
    let item = library.add(MemoryItem(title: title, summary: "More on \(title.lowercased()).", topics: topics, createdAt: date, processing: .processed))
    var rng = SeedRandom(seed: seed)
    if let v = library.vector(for: other.id) {
        library.setVector(v.map { $0 + 0.05 * rng.nextGaussian() }, for: item.id, model: library.vectors.model)
    }
    return item
}

/// A FakeAI that answers every brain prompt plausibly:
/// - taxonomy: names each cluster after its first label (sub-topics: "<label> <id>"), areas from `areas`
///   (label → area name; default "Work");
/// - same-entity: `same` for every pair;
/// - synthesis: a summary citing [1] and [2], one fact, one question, one disagreement citing [1][2];
/// - connections: "Both are about X." ; digest: two bullets.
func brainAI(areas: [String: String] = [:], same: Bool = true, extraction: String? = nil) -> FakeAI {
    FakeAI(dimensions: 48, onGenerate: { call in
        if call.system.contains("You organise the user's personal memory") {
            return taxonomyAnswer(call.prompt, areas: areas)
        }
        if call.system.contains("You decide whether two names") {
            let count = call.prompt.components(separatedBy: "\n").filter { $0.range(of: #"^\d+\. "#, options: .regularExpression) != nil }.count
            let answers = (1...max(1, count)).map { ["pair": $0, "same": same] as [String: Any] }
            return try JSONSerialization.data(withJSONObject: ["answers": answers])
        }
        if call.system.contains("You keep a living page") {
            let json: [String: Any] = [
                "summary": "First point [1]. Second point [2][1]. Bad cite [9].",
                "keyFacts": [["text": "A fact [1]", "sources": [1]], ["text": "No source", "sources": [42]]],
                "openQuestions": ["What next?"],
                "disagreements": [["text": "Price: $40 vs $45", "sources": [1, 2]]],
            ]
            return try JSONSerialization.data(withJSONObject: json)
        }
        if call.system.contains("You point out links") {
            let count = call.prompt.components(separatedBy: "\n").filter { $0.range(of: #"^\d+\.$"#, options: .regularExpression) != nil }.count
            let links = (1...max(1, count)).map { ["pair": $0, "reason": "Both are about the same idea."] as [String: Any] }
            return try JSONSerialization.data(withJSONObject: ["links": links])
        }
        if call.system.contains("weekly digest") {
            return try JSONSerialization.data(withJSONObject: ["text": "- You learned a thing [1].\n- And another [2]."])
        }
        return Data((extraction ?? #"{"title":"T","summary":"S.","keyTakeaways":[],"people":[],"projects":[],"organisations":[],"topics":[],"tags":[],"moments":[],"extractedText":""}"#).utf8)
    })
}

/// Parses the taxonomy prompt's cluster lines and answers with names from labels.
func taxonomyAnswer(_ prompt: String, areas: [String: String]) -> Data {
    var topics: [[String: Any]] = []
    var areaNames: [String] = []
    var current: (id: String, sub: Bool)?
    func flush(label: String?) {
        guard let c = current else { return }
        let base = label ?? "Topic"
        let name = c.sub ? "\(base) \(c.id)" : base.prefix(1).uppercased() + base.dropFirst()
        let area = c.sub ? "" : (areas[base.lowercased()] ?? "Work")
        if !c.sub, !areaNames.contains(area) { areaNames.append(area) }
        topics.append(["id": c.id, "name": name, "area": area, "description": "About \(base).", "sameAs": ""])
        current = nil
    }
    var pendingLabel: String?
    for line in prompt.components(separatedBy: "\n") {
        if let r = line.range(of: #"^c\d+(\.\d+)? · "#, options: .regularExpression) {
            flush(label: pendingLabel)
            pendingLabel = nil
            let id = String(line[r]).replacingOccurrences(of: " · ", with: "")
            current = (id, line.contains("sub-topic of"))
        } else if line.hasPrefix("  labels: ") {
            let first = line.dropFirst("  labels: ".count).components(separatedBy: ", ").first ?? ""
            pendingLabel = first.components(separatedBy: " ×").first
        }
    }
    flush(label: pendingLabel)
    let json: [String: Any] = ["areas": areaNames.map { ["name": $0, "description": "All about \($0)."] }, "topics": topics]
    return try! JSONSerialization.data(withJSONObject: json)
}

extension MemoryBrain {
    /// A brain for tests: no auto-update, no save delay surprises, the test clock.
    static func test(_ library: MemoryLibrary, now: Date = day(0)) -> MemoryBrain {
        let brain = MemoryBrain(library: library, saveDelay: 60, autoUpdate: false)
        brain.now = { now }
        return brain
    }
}
