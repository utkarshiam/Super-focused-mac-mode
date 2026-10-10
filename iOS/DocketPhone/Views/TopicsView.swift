import MemoryKit
import SwiftUI

/// Memory → Topics: the week's digest and connections you haven't made at the top, then areas with their
/// topics (or people, organisations, projects in the lens words), and the unsorted count.
struct TopicsView: View {
    @EnvironmentObject private var model: AppModel
    @AppStorage("memory.topics.kind") private var kindRaw = EntityKind.topic.rawValue

    private var kind: EntityKind { EntityKind(rawValue: kindRaw) ?? .topic }

    var body: some View {
        if let brain = model.brain {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: Space.xxl) {
                    if let digest = brain.digest, !digest.isEmpty { DigestCard(digest: digest) }
                    let connections = brain.connections.filter { !$0.dismissed && model.item($0.a) != nil && model.item($0.b) != nil }
                    if !connections.isEmpty { ConnectionsStrip(connections: Array(connections.prefix(3))) }
                    VStack(alignment: .leading, spacing: Space.lg) {
                        kindSwitch(brain)
                        if kind == .topic { taxonomy(brain) } else { entityList(brain.entities(kind)) }
                    }
                    footer(brain)
                }
                .padding(.horizontal, Space.gutter)
                .padding(.top, Space.md)
                .padding(.bottom, Space.x4)
            }
            .refreshable { await model.refresh(force: true) }
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: Space.md) {
                    Image(systemName: "square.grid.2x2").font(.system(size: 28)).foregroundStyle(Color.ink3)
                    Text("Topics come from your Mac").textStyle(.title3).foregroundStyle(Color.ink)
                    Text("Your Mac sorts memories into areas and topics and sends them here with the next sync. Update Docket on your Mac if this stays empty.")
                        .font(.system(size: 15))
                        .foregroundStyle(Color.ink2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.horizontal, Space.gutter)
                .padding(.top, Space.x4)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .refreshable { await model.refresh(force: true) }
        }
    }

    // MARK: Switch

    private func kindSwitch(_ brain: BrainSnapshot) -> some View {
        let kinds: [EntityKind] = [.topic, .person, .organisation, .project].filter { $0 == .topic || !brain.entities($0).isEmpty }
        return ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: Space.sm) {
                ForEach(kinds) { k in
                    FilterChip(title: k.pluralLabel(model.vocabulary), selected: kind == k) {
                        Haptics.select()
                        withAnimation(Motion.snappy) { kindRaw = k.rawValue }
                    }
                }
            }
            .padding(.horizontal, Space.gutter)
        }
        .padding(.horizontal, -Space.gutter)
    }

    // MARK: Areas and topics

    @ViewBuilder
    private func taxonomy(_ brain: BrainSnapshot) -> some View {
        let colors = AreaColors.indices(brain)
        let areas = brain.areas().filter { !brain.children(of: $0.id).isEmpty }
        ForEach(areas) { area in
            VStack(alignment: .leading, spacing: Space.sm) {
                NavigationLink(value: MemoryRoute.entity(area.id)) {
                    HStack(spacing: Space.sm) {
                        Circle().fill(AreaColors.color(for: area.id, in: colors)).frame(width: 8, height: 8)
                        Eyebrow(area.name, color: .ink2)
                        Spacer(minLength: 0)
                        Text(BrainText.memories(area.itemCount))
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(Color.ink3)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(PressScale(scale: 0.985))
                topicCard(brain.children(of: area.id))
            }
        }
        let loose = brain.topics(in: nil)
        if !loose.isEmpty {
            VStack(alignment: .leading, spacing: Space.sm) {
                Eyebrow("Other topics", color: .ink2)
                topicCard(loose)
            }
        }
        if !brain.unsorted.isEmpty {
            NavigationLink(value: MemoryRoute.unsorted) {
                HStack(spacing: Space.md) {
                    Image(systemName: "tray")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(Color.ink2)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Unsorted")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(Color.ink)
                        Text("New memories wait here until your Mac reorganises.")
                            .font(.system(size: 12.5, weight: .medium))
                            .foregroundStyle(Color.ink3)
                            .lineLimit(2)
                    }
                    Spacer(minLength: Space.sm)
                    Text("\(brain.unsorted.count)")
                        .font(.system(size: 14, weight: .semibold))
                        .monospacedDigit()
                        .foregroundStyle(Color.ink2)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Color.ink3)
                }
                .padding(.vertical, 12)
                .padding(.horizontal, Space.md)
                .hairlineCard(radius: Radius.md)
            }
            .buttonStyle(PressScale(scale: 0.985))
        }
    }

    private func topicCard(_ topics: [BrainEntity]) -> some View {
        VStack(spacing: 0) {
            ForEach(Array(topics.enumerated()), id: \.element.id) { index, topic in
                if index > 0 { Hairline() }
                NavigationLink(value: MemoryRoute.entity(topic.id)) {
                    EntityRowContent(entity: topic).padding(.vertical, 11)
                }
                .buttonStyle(PressScale(scale: 0.985))
            }
        }
        .padding(.horizontal, Space.md)
        .hairlineCard(radius: Radius.md)
    }

    @ViewBuilder
    private func entityList(_ entities: [BrainEntity]) -> some View {
        if entities.isEmpty {
            Text("No \(kind.pluralLabel(model.vocabulary).lowercased()) yet.")
                .font(.system(size: 15))
                .foregroundStyle(Color.ink2)
        } else {
            VStack(spacing: 0) {
                ForEach(Array(entities.enumerated()), id: \.element.id) { index, e in
                    if index > 0 { Hairline() }
                    NavigationLink(value: MemoryRoute.entity(e.id)) {
                        EntityRowContent(entity: e).padding(.vertical, 11)
                    }
                    .buttonStyle(PressScale(scale: 0.985))
                }
            }
            .padding(.horizontal, Space.md)
            .hairlineCard(radius: Radius.md)
        }
    }

    private func footer(_ brain: BrainSnapshot) -> some View {
        var line = "Organised on your Mac"
        if let at = brain.organizedAt { line += " on \(PhoneFmt.day(at))" }
        return MacCorrectionsNote(text: line + ". Rename, merge and move topics there.")
    }
}

// MARK: - Digest

/// "What you learned · 5–11 Oct": counts, then the AI's bullets (or new and biggest topics without AI).
private struct DigestCard: View {
    let digest: BrainDigest
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: Space.md) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text("What you learned")
                        .font(.system(size: 17, weight: .semibold))
                        .tracking(-0.2)
                        .foregroundStyle(Color.ink)
                    Text(BrainText.weekRange(start: digest.weekStart, end: digest.weekEnd))
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(Color.ink3)
                }
                Text(meta)
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(Color.ink3)
                    .lineLimit(1)
            }
            if digest.isWritten {
                CitedProse(text: digest.text, sources: digest.sources, size: 14.5, maxBlocks: 3, lineLimit: 3)
            } else {
                let topics = digest.newTopics.isEmpty ? digest.biggestTopics : digest.newTopics
                if !topics.isEmpty {
                    FlowLayout(spacing: Space.sm) {
                        ForEach(topics.prefix(4)) { t in
                            NavigationLink(value: MemoryRoute.entity(t.topicID)) {
                                Text(t.name)
                                    .font(.system(size: 13.5, weight: .medium))
                                    .foregroundStyle(Color.ink)
                                    .padding(.horizontal, 10)
                                    .frame(height: 28)
                                    .background(Capsule().fill(Color.fill))
                            }
                            .buttonStyle(PressScale(scale: 0.95))
                        }
                    }
                }
                ForEach(digest.decisions.prefix(2)) { d in
                    Text(d.text)
                        .font(.system(size: 14.5))
                        .foregroundStyle(Color.bodyText)
                        .lineLimit(2)
                }
            }
        }
        .padding(Space.lg)
        .frame(maxWidth: .infinity, alignment: .leading)
        .hairlineCard(radius: Radius.md)
    }

    private var meta: String {
        var parts = [BrainText.memories(digest.itemCount)]
        if !digest.newTopics.isEmpty { parts.append(PhoneFmt.count(digest.newTopics.count, "new topic")) }
        if !digest.decisions.isEmpty { parts.append(PhoneFmt.count(digest.decisions.count, model.vocabulary.decisions.lowercased().dropLastS)) }
        return parts.joined(separator: " · ")
    }
}

private extension String {
    /// "decisions" → "decision" for PhoneFmt.count's singular.
    var dropLastS: String { hasSuffix("s") ? String(dropLast()) : self }
}

// MARK: - Connections

/// "Connections you haven't made": up to three pairs, side by side.
private struct ConnectionsStrip: View {
    let connections: [BrainConnection]
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: Space.sm) {
            Eyebrow("Connections you haven't made")
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: Space.md) {
                    ForEach(connections) { c in card(c) }
                }
                .padding(.horizontal, Space.gutter)
            }
            .padding(.horizontal, -Space.gutter)
        }
    }

    private func card(_ c: BrainConnection) -> some View {
        VStack(alignment: .leading, spacing: Space.sm) {
            if let a = model.item(c.a) { link(a) }
            if let b = model.item(c.b) { link(b) }
            Text(c.reason)
                .font(.system(size: 13.5))
                .foregroundStyle(Color.ink2)
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(Space.md)
        .frame(width: connections.count == 1 ? 320 : 264, alignment: .leading)
        .frame(minHeight: 132, alignment: .topLeading)
        .hairlineCard(radius: Radius.md)
    }

    private func link(_ item: MemoryItem) -> some View {
        NavigationLink(value: MemoryRoute.item(item.id)) {
            HStack(spacing: 6) {
                Image(systemName: item.kind.symbolName)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Color.ink3)
                    .frame(width: 14)
                Text(item.displayTitle)
                    .font(.system(size: 14.5, weight: .semibold))
                    .foregroundStyle(Color.ink)
                    .lineLimit(1)
            }
        }
        .buttonStyle(PressScale(scale: 0.97))
    }
}

// MARK: - Unsorted

/// Memories no topic has claimed yet.
struct UnsortedView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        let items = (model.brain?.unsorted ?? []).compactMap(model.item).sorted { $0.createdAt > $1.createdAt }
        List {
            Section {
                MacCorrectionsNote(text: "Your Mac files these into topics at its next reorganisation.")
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                    .listRowInsets(EdgeInsets(top: 4, leading: Space.gutter, bottom: 8, trailing: Space.gutter))
                ForEach(items) { item in
                    NavigationLink(value: MemoryRoute.item(item.id)) { MemoryRow(item: item) }
                        .listRowBackground(Color.paper)
                        .listRowSeparatorTint(Color.hair)
                        .listRowInsets(EdgeInsets(top: 12, leading: Space.gutter, bottom: 12, trailing: Space.lg))
                }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .paperBackground()
        .navigationTitle("Unsorted")
        .navigationBarTitleDisplayMode(.inline)
    }
}
