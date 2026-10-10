import Foundation
import MemoryKit
import SwiftUI
import UIKit

// The phone's view of the brain: read-only, from `snapshot.brain` (the Mac organises and corrects).

/// Where the Memory tab can navigate: a memory, an entity's page, or the unsorted memories.
enum MemoryRoute: Hashable {
    case item(UUID)
    case entity(UUID)
    case unsorted
}

/// The Memory tab's three views.
enum MemoryMode: String, CaseIterable, Identifiable {
    case library, topics, map

    var id: String { rawValue }

    var title: String {
        switch self {
        case .library: "Library"
        case .topics: "Topics"
        case .map: "Map"
        }
    }
}

// MARK: - Navigation

/// Pushes a route onto whichever stack shows the view (Memory's, or an item sheet's own).
struct MemoryPushKey: EnvironmentKey {
    static let defaultValue: (MemoryRoute) -> Void = { _ in }
}

extension EnvironmentValues {
    var memoryPush: (MemoryRoute) -> Void {
        get { self[MemoryPushKey.self] }
        set { self[MemoryPushKey.self] = newValue }
    }
}

/// The pages any memory stack can push.
struct MemoryDestinations: ViewModifier {
    func body(content: Content) -> some View {
        content.navigationDestination(for: MemoryRoute.self) { route in
            switch route {
            case .item(let id): ItemDetailView(itemID: id)
            case .entity(let id): EntityPageView(entityID: id)
            case .unsorted: UnsortedView()
            }
        }
    }
}

extension View {
    func memoryDestinations() -> some View { modifier(MemoryDestinations()) }
}

// MARK: - Reading the brain

extension AppModel {
    var brain: BrainSnapshot? { snapshot?.brain }

    /// Entities whose name or a spelling matches `query` (folded), best first: exact, then word prefix,
    /// then anywhere; bigger first within each.
    func entityMatches(_ query: String, limit: Int = 5) -> [BrainEntity] {
        let q = BrainText.fold(query)
        guard let brain, q.count >= 2 else { return [] }
        var scored: [(BrainEntity, Int)] = []
        for e in brain.entities where e.itemCount > 0 || e.kind == .area {
            var best = 0
            for name in e.aliases {
                let n = BrainText.fold(name)
                if n == q { best = max(best, 3) }
                else if n.hasPrefix(q) || n.contains(" " + q) { best = max(best, 2) }
                else if n.contains(q) { best = max(best, 1) }
            }
            if best > 0 { scored.append((e, best)) }
        }
        return scored.sorted { ($0.1, $0.0.itemCount) > ($1.1, $1.0.itemCount) }.prefix(limit).map(\.0)
    }

    /// The snapshot's items behind an entity, newest first.
    func brainItems(for id: UUID) -> [MemoryItem] {
        guard let brain else { return [] }
        return brain.itemIDs(for: id).compactMap(item).sorted { $0.createdAt > $1.createdAt }
    }

    /// Area → topic → sub-topic, ending with the entity itself.
    func brainPath(to id: UUID) -> [BrainEntity] {
        guard let brain else { return [] }
        var path: [BrainEntity] = []
        var next: UUID? = id
        var seen: Set<UUID> = []
        while let current = next, seen.insert(current).inserted, let e = brain.entity(current) {
            path.insert(e, at: 0)
            next = e.parentID
        }
        return path
    }

    /// Entities sharing memories with `id` (not its parents or children), strongest first.
    func brainRelated(to id: UUID, limit: Int = 8) -> [BrainEntity] {
        guard let brain else { return [] }
        let mine = Set(brain.itemIDs(for: id))
        guard !mine.isEmpty else { return [] }
        let family = Set(brainPath(to: id).map(\.id)).union(brain.children(of: id).map(\.id))
        var scored: [(BrainEntity, Double)] = []
        for e in brain.entities where !family.contains(e.id) && e.kind != .area {
            let theirs = brain.itemIDs(for: e.id)
            guard !theirs.isEmpty else { continue }
            let shared = theirs.reduce(0) { $0 + (mine.contains($1) ? 1 : 0) }
            guard shared > 0 else { continue }
            scored.append((e, Double(shared) / (Double(mine.count) * Double(theirs.count)).squareRoot()))
        }
        return scored.sorted { ($0.1, $0.0.itemCount) > ($1.1, $1.0.itemCount) }.prefix(limit).map(\.0)
    }

    /// The entity behind a name on an item ("Rohan" → Rohan Mehta), trying organisations for project names.
    func brainEntity(named name: String, kind: EntityKind) -> BrainEntity? {
        guard let brain else { return nil }
        if let e = brain.entity(named: name, kind: kind) { return e }
        if kind == .project || kind == .person { return brain.entity(named: name, kind: .organisation) }
        return nil
    }

    /// Opens `DOCKET_PHONE_ENTITY=<name>` (demo): exact name first, then any spelling containing it.
    func demoEntity(_ name: String) -> BrainEntity? {
        guard let brain else { return nil }
        let q = BrainText.fold(name)
        return brain.entities.first { BrainText.fold($0.name) == q }
            ?? brain.entities.filter { $0.aliases.contains { BrainText.fold($0).contains(q) } }.max { $0.itemCount < $1.itemCount }
    }
}

// MARK: - Text and dates

enum BrainText {
    static func fold(_ s: String) -> String {
        s.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
            .lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// "5–11 Oct", "28 Sep – 4 Oct", "29 Dec 2025 – 4 Jan 2026" (the week's last day is `end` minus one day).
    static func weekRange(start: Date, end: Date, now: Date = Date(), calendar: Calendar = .current) -> String {
        let last = calendar.date(byAdding: .day, value: -1, to: end) ?? end
        let sameYear = calendar.component(.year, from: start) == calendar.component(.year, from: last)
        let thisYear = calendar.component(.year, from: last) == calendar.component(.year, from: now)
        let day = DateFormatter(), dayMonth = DateFormatter(), full = DateFormatter()
        day.setLocalizedDateFormatFromTemplate("d")
        dayMonth.setLocalizedDateFormatFromTemplate("d MMM")
        full.setLocalizedDateFormatFromTemplate("d MMM yyyy")
        if !sameYear { return "\(full.string(from: start)) – \(full.string(from: last))" }
        let tail = thisYear ? dayMonth.string(from: last) : full.string(from: last)
        if calendar.component(.month, from: start) == calendar.component(.month, from: last) {
            return "\(day.string(from: start))–\(tail)"
        }
        return "\(dayMonth.string(from: start)) – \(tail)"
    }

    /// "1 memory", "12 memories".
    static func memories(_ n: Int) -> String { PhoneFmt.count(n, "memory", "memories") }
}

// MARK: - Area colours

/// Muted hues for areas, the same as the Mac's `BrainPalette` (an area's colour runs through its topics and
/// people): dusty blue, terracotta, sage, lavender, ochre, teal, indigo, olive, each with a dark-mode twin.
/// Slots are assigned exactly as on the Mac (stable hash of the id, next free slot, areas in id order), so an
/// area has the same colour on both.
enum AreaColors {
    private static let light: [UInt32] = [0x5F83AB, 0xB57A62, 0x6E9874, 0x9C80B0, 0xB8954A, 0x5E9A96, 0x6E6FA8, 0x878760]
    private static let dark: [UInt32] = [0x8EA9CB, 0xD49C84, 0x94BD99, 0xC0A6D3, 0xD8B872, 0x87C1BC, 0x9A9BD3, 0xB0B086]
    static let uiColors: [UIColor] = zip(light, dark).map { UIColor.dynamic($0.0, $0.1) }
    static let none = UIColor.dynamic(0xA3A39E, 0x6E6E6B)

    /// Area id → palette slot (the Mac's `BrainPalette.slots`).
    static func indices(_ brain: BrainSnapshot?) -> [UUID: Int] {
        let count = light.count
        var taken = Set<Int>()
        var out: [UUID: Int] = [:]
        for id in Set((brain?.areas() ?? []).map(\.id)).sorted(by: { $0.uuidString < $1.uuidString }) {
            var slot = stableHash(id.uuidString).unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) & 0xFFFF } % count
            if taken.count < count {
                while taken.contains(slot) { slot = (slot + 1) % count }
            }
            taken.insert(slot)
            out[id] = slot
        }
        return out
    }

    /// The Mac's `stableHash` (djb2-xor, base 36).
    private static func stableHash(_ s: String) -> String {
        var h: UInt64 = 5381
        for b in s.utf8 { h = (h &* 33) ^ UInt64(b) }
        return String(h, radix: 36)
    }

    static func color(for areaID: UUID?, in indices: [UUID: Int]) -> Color {
        Color(uiColor: uiColor(for: areaID, in: indices))
    }

    static func uiColor(for areaID: UUID?, in indices: [UUID: Int]) -> UIColor {
        guard let areaID, let i = indices[areaID] else { return none }
        return uiColors[i]
    }
}

extension AppModel {
    /// The area an entity sits in (topics through their parents).
    func brainArea(of id: UUID) -> UUID? {
        if let first = brainPath(to: id).first, first.kind == .area { return first.id }
        return brain?.map.node(id)?.areaID
    }
}

// MARK: - Shared bits

/// "Corrections happen on your Mac." in one quiet line.
struct MacCorrectionsNote: View {
    var text = "Rename, merge and move things on your Mac."

    var body: some View {
        Text(text)
            .font(.system(size: 12.5, weight: .medium))
            .foregroundStyle(Color.ink3)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// An entity as a chip: kind symbol and name; opens its page.
struct EntityChip: View {
    let entity: BrainEntity

    var body: some View {
        NavigationLink(value: MemoryRoute.entity(entity.id)) {
            HStack(spacing: 6) {
                Image(systemName: entity.kind.symbolName).font(.system(size: 11, weight: .semibold)).foregroundStyle(Color.ink2)
                Text(entity.name).lineLimit(1)
            }
            .font(.system(size: 14, weight: .medium))
            .foregroundStyle(Color.ink)
            .padding(.horizontal, 12)
            .frame(height: 32)
            .background(Capsule().fill(Color.fill))
        }
        .buttonStyle(PressScale(scale: 0.95))
    }
}
