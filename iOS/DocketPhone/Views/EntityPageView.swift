import MemoryKit
import SwiftUI

/// A living page: a topic, area, person, organisation or project as the Mac's brain knows it. What you
/// know (with [n] citations), key facts, notes that disagree, open questions, sub-topics, related things
/// and the timeline of memories. Read-only: corrections happen on the Mac.
struct EntityPageView: View {
    let entityID: UUID
    @EnvironmentObject private var model: AppModel

    var body: some View {
        Group {
            if let entity = model.brain?.entity(entityID) {
                page(entity)
            } else {
                Text("This page is no longer in your memory.")
                    .font(.system(size: 15))
                    .foregroundStyle(Color.ink2)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .paperBackground()
        .navigationBarTitleDisplayMode(.inline)
    }

    private func page(_ entity: BrainEntity) -> some View {
        let sources = pageSources(entity)
        let items = model.brainItems(for: entity.id)
        let children = model.brain?.children(of: entity.id) ?? []
        let related = model.brainRelated(to: entity.id)
        return ScrollView {
            VStack(alignment: .leading, spacing: Space.xxl) {
                header(entity, items: items, children: children)
                if !entity.summary.isEmpty {
                    section("What you know") {
                        CitedProse(text: entity.summary, sources: sources, size: 16.5)
                    }
                } else if !entity.detail.isEmpty && entity.kind.isTaxonomy {
                    Text(entity.detail)
                        .font(.system(size: 16.5))
                        .foregroundStyle(Color.bodyText)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if !entity.keyFacts.isEmpty {
                    section("Key facts") {
                        CitedProse(text: entity.keyFacts.map { "- " + cited($0, sources) }.joined(separator: "\n"), sources: sources, size: 15.5)
                    }
                }
                if !entity.disagreements.isEmpty {
                    section("Notes that disagree") {
                        VStack(spacing: Space.md) {
                            ForEach(entity.disagreements) { DisagreementCard(text: $0) }
                        }
                    }
                }
                if !entity.openQuestions.isEmpty {
                    section("Open questions") {
                        VStack(alignment: .leading, spacing: Space.sm) {
                            ForEach(Array(entity.openQuestions.enumerated()), id: \.offset) { _, q in
                                HStack(alignment: .firstTextBaseline, spacing: Space.sm) {
                                    Image(systemName: "questionmark.circle")
                                        .font(.system(size: 13, weight: .medium))
                                        .foregroundStyle(Color.ink3)
                                    Text(q)
                                        .font(.system(size: 15.5))
                                        .foregroundStyle(Color.bodyText)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                            }
                        }
                    }
                }
                if !children.isEmpty {
                    section(entity.kind == .area ? "Topics" : "Sub-topics") {
                        VStack(spacing: 0) {
                            ForEach(Array(children.enumerated()), id: \.element.id) { index, child in
                                if index > 0 { Hairline() }
                                NavigationLink(value: MemoryRoute.entity(child.id)) {
                                    EntityRowContent(entity: child)
                                        .padding(.vertical, 11)
                                }
                                .buttonStyle(PressScale(scale: 0.985))
                            }
                        }
                        .padding(.horizontal, Space.md)
                        .hairlineCard(radius: Radius.md)
                    }
                }
                if !related.isEmpty {
                    section("Related") {
                        FlowLayout(spacing: Space.sm) {
                            ForEach(related) { EntityChip(entity: $0) }
                        }
                    }
                }
                if !items.isEmpty {
                    section("Timeline") {
                        VStack(spacing: 0) {
                            ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                                if index > 0 { Hairline() }
                                NavigationLink(value: MemoryRoute.item(item.id)) {
                                    TimelineRow(item: item)
                                }
                                .buttonStyle(PressScale(scale: 0.985))
                            }
                        }
                        if entity.itemCount > items.count {
                            Text("The latest \(items.count) of \(entity.itemCount). The rest are on your Mac.")
                                .font(.system(size: 12.5, weight: .medium))
                                .foregroundStyle(Color.ink3)
                                .padding(.top, Space.xs)
                        }
                    }
                }
                if !entity.hasPage && entity.itemCount >= 2 {
                    MacCorrectionsNote(text: "Your Mac writes this page once a Gemini key is set there.")
                }
                MacCorrectionsNote()
            }
            .padding(.horizontal, Space.gutter)
            .padding(.top, Space.sm)
            .padding(.bottom, Space.x4)
        }
    }

    // MARK: Header

    private func header(_ entity: BrainEntity, items: [MemoryItem], children: [BrainEntity]) -> some View {
        let path = model.brainPath(to: entity.id).dropLast()
        return VStack(alignment: .leading, spacing: Space.sm) {
            if !path.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 4) {
                        ForEach(Array(path)) { crumb in
                            NavigationLink(value: MemoryRoute.entity(crumb.id)) {
                                Text(crumb.name).lineLimit(1)
                            }
                            .buttonStyle(PressScale(scale: 0.95))
                            Image(systemName: "chevron.right").font(.system(size: 9, weight: .bold)).foregroundStyle(Color.ink3)
                        }
                    }
                    .font(.system(size: 13.5, weight: .medium))
                    .foregroundStyle(Color.ink2)
                }
            }
            HStack(spacing: 6) {
                Circle().fill(AreaColors.color(for: model.brainArea(of: entity.id), in: AreaColors.indices(model.brain)))
                    .frame(width: 7, height: 7)
                Image(systemName: entity.kind.symbolName).font(.system(size: 11, weight: .semibold))
                Text(entity.kind.label(model.vocabulary))
            }
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(Color.ink3)
            Text(entity.name)
                .font(.system(size: 28, weight: .bold))
                .tracking(-0.6)
                .foregroundStyle(Color.ink)
                .fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 3) {
                Text(countLine(entity, children: children))
                if let seen = seenLine(entity) { Text(seen) }
                let others = entity.aliases.filter { BrainText.fold($0) != BrainText.fold(entity.name) }
                if !others.isEmpty { Text("Also written " + others.prefix(4).joined(separator: ", ")) }
            }
            .font(.system(size: 13.5, weight: .medium))
            .foregroundStyle(Color.ink3)
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func countLine(_ entity: BrainEntity, children: [BrainEntity]) -> String {
        var parts = [BrainText.memories(entity.itemCount)]
        if !children.isEmpty {
            parts.append(entity.kind == .area ? PhoneFmt.count(children.count, "topic") : PhoneFmt.count(children.count, "sub-topic"))
        }
        return parts.joined(separator: " · ")
    }

    private func seenLine(_ entity: BrainEntity) -> String? {
        switch (entity.firstSeen, entity.lastSeen) {
        case let (first?, last?) where Calendar.current.isDate(first, inSameDayAs: last): "Seen \(PhoneFmt.day(first))"
        case let (first?, last?): "First seen \(PhoneFmt.day(first)) · last \(PhoneFmt.day(last))"
        case let (first?, nil): "First seen \(PhoneFmt.day(first))"
        case let (nil, last?): "Last seen \(PhoneFmt.day(last))"
        default: nil
        }
    }

    // MARK: Helpers

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: Space.md) {
            Eyebrow(title)
            content()
        }
    }

    /// Every item the page cites: the summary's sources first (so its [n] stay put), then the rest.
    private func pageSources(_ e: BrainEntity) -> [UUID] {
        var out = e.summarySources
        for id in e.keyFacts.flatMap(\.itemIDs) + e.disagreements.flatMap(\.itemIDs) where !out.contains(id) { out.append(id) }
        return out
    }

    private func cited(_ fact: CitedText, _ sources: [UUID]) -> String {
        let marks = fact.itemIDs.compactMap { id in sources.firstIndex(of: id).map { "[\($0 + 1)]" } }
        return marks.isEmpty ? fact.text : fact.text + " " + marks.joined()
    }
}

/// Where memories contradict each other: the claim, then each source with its real date.
private struct DisagreementCard: View {
    let text: CitedText
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: Space.sm) {
            HStack(alignment: .firstTextBaseline, spacing: Space.sm) {
                Image(systemName: "arrow.left.arrow.right")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(Tone.warning.fg)
                Text(text.text)
                    .font(.system(size: 15.5, weight: .medium))
                    .foregroundStyle(Color.ink)
                    .fixedSize(horizontal: false, vertical: true)
            }
            let items = text.itemIDs.compactMap(model.item)
            if !items.isEmpty {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(items) { item in
                        NavigationLink(value: MemoryRoute.item(item.id)) {
                            HStack(spacing: Space.sm) {
                                Text(PhoneFmt.day(item.createdAt))
                                    .font(.system(size: 12.5, weight: .semibold))
                                    .monospacedDigit()
                                    .foregroundStyle(Tone.warning.fg)
                                    .frame(minWidth: 74, alignment: .leading)
                                Text(item.displayTitle)
                                    .font(.system(size: 14))
                                    .foregroundStyle(Color.ink)
                                    .lineLimit(1)
                                Spacer(minLength: 0)
                                Image(systemName: "chevron.right")
                                    .font(.system(size: 10, weight: .bold))
                                    .foregroundStyle(Color.ink3)
                            }
                            .padding(.vertical, 7)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(PressScale(scale: 0.985))
                    }
                }
                .padding(.leading, 20)
            }
        }
        .padding(Space.md)
        .background(RoundedRectangle(cornerRadius: Radius.md, style: .continuous).fill(Tone.warning.bg))
        .overlay(RoundedRectangle(cornerRadius: Radius.md, style: .continuous).strokeBorder(Tone.warning.border, lineWidth: 1))
    }
}

/// One memory on a page's timeline: its real date, title and first line.
private struct TimelineRow: View {
    let item: MemoryItem

    var body: some View {
        HStack(alignment: .top, spacing: Space.md) {
            Text(PhoneFmt.day(item.createdAt))
                .font(.system(size: 12.5, weight: .semibold))
                .monospacedDigit()
                .foregroundStyle(Color.ink3)
                .frame(width: 78, alignment: .leading)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.displayTitle)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Color.ink)
                    .lineLimit(2)
                if !item.summary.isEmpty {
                    Text(item.summary)
                        .font(.system(size: 13.5))
                        .foregroundStyle(Color.ink2)
                        .lineLimit(2)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 11)
        .contentShape(Rectangle())
    }
}

/// An entity row: area-coloured dot, name, count and the real date it was last seen.
struct EntityRowContent: View {
    let entity: BrainEntity
    var showsKind = false
    /// Off inside a List row (the NavigationLink draws its own).
    var chevron = true
    @EnvironmentObject private var model: AppModel

    var body: some View {
        HStack(spacing: Space.md) {
            if showsKind {
                Image(systemName: entity.kind.symbolName)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Color.ink2)
                    .frame(width: 22)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(entity.name)
                    .font(.system(size: 16, weight: .semibold))
                    .tracking(-0.2)
                    .foregroundStyle(Color.ink)
                    .lineLimit(1)
                Text(meta)
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(Color.ink3)
                    .lineLimit(1)
            }
            Spacer(minLength: Space.sm)
            Text("\(entity.itemCount)")
                .font(.system(size: 14, weight: .semibold))
                .monospacedDigit()
                .foregroundStyle(Color.ink2)
            if chevron {
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Color.ink3)
            }
        }
        .contentShape(Rectangle())
    }

    private var meta: String {
        var parts: [String] = []
        if showsKind { parts.append(entity.kind.label(model.vocabulary)) }
        if let last = entity.lastSeen { parts.append("Last seen \(PhoneFmt.day(last))") }
        let subs = model.brain?.children(of: entity.id).count ?? 0
        if subs > 0 && entity.kind == .topic { parts.append(PhoneFmt.count(subs, "sub-topic")) }
        if parts.isEmpty { parts.append(BrainText.memories(entity.itemCount)) }
        return parts.joined(separator: " · ")
    }
}
