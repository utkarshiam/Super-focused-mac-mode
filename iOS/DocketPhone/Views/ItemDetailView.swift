import MemoryKit
import SwiftUI
import UIKit

/// One memory: summary, takeaways, moments (named by the lens), people and projects, the link, the
/// thumbnail, the text, and a few related items.
struct ItemDetailView: View {
    let itemID: UUID
    @EnvironmentObject private var model: AppModel
    @Environment(\.openURL) private var openURL
    @State private var image: UIImage?
    @State private var showAllText = false

    var body: some View {
        Group {
            if let item = model.item(itemID) {
                ScrollView {
                    VStack(alignment: .leading, spacing: Space.xxl) {
                        header(item)
                        if let image { thumbnail(image) }
                        if !item.summary.isEmpty {
                            Text(item.summary)
                                .font(.system(size: 17))
                                .lineSpacing(3)
                                .foregroundStyle(Color.bodyText)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        if let url = item.url.flatMap(URL.init(string:)) { linkButton(url) }
                        if !item.keyTakeaways.isEmpty { takeaways(item.keyTakeaways) }
                        moments(item)
                        names(item)
                        text(item)
                        files(item)
                        related(item)
                    }
                    .padding(.horizontal, Space.gutter)
                    .padding(.top, Space.sm)
                    .padding(.bottom, Space.x4)
                }
                .task(id: itemID) {
                    image = await ThumbnailCache.shared.image(for: item, url: model.thumbnailURL(for: item.id))
                }
            } else {
                Text("This memory is no longer in the library.")
                    .font(.system(size: 15))
                    .foregroundStyle(Color.ink2)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .paperBackground()
        .navigationBarTitleDisplayMode(.inline)
    }

    // MARK: Sections

    private func header(_ item: MemoryItem) -> some View {
        VStack(alignment: .leading, spacing: Space.sm) {
            HStack(spacing: 6) {
                Image(systemName: item.kind.symbolName).font(.system(size: 12, weight: .semibold))
                Text(metaLine(item))
            }
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(Color.ink3)
            Text(item.displayTitle)
                .font(.system(size: 26, weight: .bold))
                .tracking(-0.5)
                .foregroundStyle(Color.ink)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func metaLine(_ item: MemoryItem) -> String {
        var parts = [item.kind.label, PhoneFmt.dayTime(item.createdAt)]
        if let from = item.capturedFrom, !from.isEmpty { parts.append(from) }
        return parts.joined(separator: " · ")
    }

    private func thumbnail(_ image: UIImage) -> some View {
        Image(uiImage: image)
            .resizable()
            .scaledToFit()
            .frame(maxWidth: .infinity)
            .clipShape(RoundedRectangle(cornerRadius: Radius.md, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Radius.md, style: .continuous).strokeBorder(Color.hair, lineWidth: 1))
    }

    private func linkButton(_ url: URL) -> some View {
        Button {
            openURL(url)
        } label: {
            Label("Open \(LinkDetector.host(url.absoluteString))", systemImage: "safari")
        }
        .buttonStyle(PrimaryPill(height: 42))
    }

    private func takeaways(_ lines: [String]) -> some View {
        VStack(alignment: .leading, spacing: Space.sm) {
            Eyebrow("Takeaways")
            VStack(alignment: .leading, spacing: Space.sm) {
                ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                    HStack(alignment: .firstTextBaseline, spacing: Space.sm) {
                        Circle().fill(Color.ink3).frame(width: 5, height: 5).alignmentGuide(.firstTextBaseline) { $0[.bottom] + 1 }
                        Text(line)
                            .font(.system(size: 16))
                            .foregroundStyle(Color.bodyText)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func moments(_ item: MemoryItem) -> some View {
        let vocabulary = model.vocabulary
        ForEach(MomentKind.allCases) { kind in
            let list = item.moments.filter { $0.kind == kind }
            if !list.isEmpty {
                VStack(alignment: .leading, spacing: Space.sm) {
                    Eyebrow(vocabulary.label(for: kind))
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(list.enumerated()), id: \.element.id) { index, moment in
                            if index > 0 { Hairline() }
                            MomentLine(moment: moment)
                        }
                    }
                    .padding(.horizontal, Space.md)
                    .hairlineCard(radius: Radius.md)
                }
            }
        }
    }

    /// Topics, people, organisations and projects; each opens its page when the Mac's brain knows it.
    @ViewBuilder
    private func names(_ item: MemoryItem) -> some View {
        let vocabulary = model.vocabulary
        let topics = itemTopics(item)
        let groups: [(String, [NameChip])] = [
            ("Topics", topics.map { NameChip(name: $0.name, kind: .topic, entity: $0) }),
            (vocabulary.people, chips(item.people, .person)),
            ("Organisations", chips(item.organisations, .organisation)),
            (vocabulary.projects, chips(item.projects, .project)),
        ].filter { !$0.1.isEmpty }
        if !groups.isEmpty {
            VStack(alignment: .leading, spacing: Space.lg) {
                ForEach(groups, id: \.0) { group in
                    VStack(alignment: .leading, spacing: Space.sm) {
                        Eyebrow(group.0)
                        FlowLayout(spacing: Space.sm) {
                            ForEach(group.1) { chip in
                                if let entity = chip.entity {
                                    EntityChip(entity: entity)
                                } else {
                                    Label(chip.name, systemImage: chip.kind.symbolName)
                                        .font(.system(size: 14, weight: .medium))
                                        .foregroundStyle(Color.ink2)
                                        .padding(.horizontal, 12)
                                        .frame(height: 32)
                                        .overlay(Capsule().strokeBorder(Color.hairStrong, lineWidth: 1))
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    private struct NameChip: Identifiable {
        var name: String
        var kind: EntityKind
        var entity: BrainEntity?
        var id: String { (entity?.id.uuidString ?? "") + kind.rawValue + name }
    }

    /// The item's topics from the brain, its primary topic first.
    private func itemTopics(_ item: MemoryItem) -> [BrainEntity] {
        guard let brain = model.brain else { return [] }
        let primary = brain.primaryTopic(of: item.id)
        let others = brain.entities(forItem: item.id).filter { $0.kind == .topic && $0.id != primary?.id }
        return (primary.map { [$0] } ?? []) + others
    }

    /// Names on the item, resolved to entities where the brain has them (one chip per entity).
    private func chips(_ names: [String], _ kind: EntityKind) -> [NameChip] {
        var seen: Set<String> = []
        return names.compactMap { name in
            let entity = model.brainEntity(named: name, kind: kind)
            let key = entity?.id.uuidString ?? BrainText.fold(name)
            guard seen.insert(key).inserted else { return nil }
            return NameChip(name: entity?.name ?? name, kind: entity?.kind ?? kind, entity: entity)
        }
    }

    @ViewBuilder
    private func text(_ item: MemoryItem) -> some View {
        let full = item.fullText
        if !full.isEmpty {
            let long = full.count > 600
            VStack(alignment: .leading, spacing: Space.sm) {
                Eyebrow(item.kind == .audio ? "Transcript" : "Text")
                Text(long && !showAllText ? String(full.prefix(600)) + "…" : full)
                    .font(.system(size: 15))
                    .lineSpacing(3)
                    .foregroundStyle(Color.bodyText)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                if long {
                    Button(showAllText ? "Show less" : "Show all") { withAnimation(Motion.snappy) { showAllText.toggle() } }
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Color.ink)
                }
            }
        }
    }

    @ViewBuilder
    private func files(_ item: MemoryItem) -> some View {
        if !item.attachments.isEmpty {
            VStack(alignment: .leading, spacing: Space.sm) {
                Eyebrow("On your Mac")
                ForEach(item.attachments) { file in
                    HStack(spacing: Space.sm) {
                        Image(systemName: file.isImage ? "photo" : "doc")
                            .foregroundStyle(Color.ink2)
                        Text(file.name).foregroundStyle(Color.ink).lineLimit(1)
                        Spacer(minLength: Space.sm)
                        Text(ByteCountFormatter.string(fromByteCount: Int64(file.byteCount), countStyle: .file))
                            .foregroundStyle(Color.ink3)
                    }
                    .font(.system(size: 14))
                }
            }
        }
    }

    @ViewBuilder
    private func related(_ item: MemoryItem) -> some View {
        let hits = model.search?.related(toItem: item.id, limit: 3) ?? []
        if !hits.isEmpty {
            VStack(alignment: .leading, spacing: Space.sm) {
                Eyebrow("From memory")
                VStack(spacing: 0) {
                    ForEach(Array(hits.enumerated()), id: \.element.id) { index, hit in
                        if index > 0 { Hairline() }
                        NavigationLink(value: MemoryRoute.item(hit.item.id)) {
                            HStack(spacing: Space.md) {
                                ItemThumb(item: hit.item, size: 32)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(hit.item.displayTitle)
                                        .font(.system(size: 15, weight: .medium))
                                        .foregroundStyle(Color.ink)
                                        .lineLimit(1)
                                    Text(PhoneFmt.day(hit.item.createdAt))
                                        .font(.system(size: 12.5))
                                        .foregroundStyle(Color.ink3)
                                }
                                Spacer(minLength: 0)
                                Image(systemName: "chevron.right")
                                    .font(.system(size: 12, weight: .semibold))
                                    .foregroundStyle(Color.ink3)
                            }
                            .padding(.vertical, 10)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(PressScale(scale: 0.985))
                    }
                }
            }
        }
    }
}

/// One decision, promise, idea or insight, with who and when.
private struct MomentLine: View {
    let moment: Moment

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Space.sm) {
            if moment.kind == .promise {
                Image(systemName: moment.done ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 14))
                    .foregroundStyle(moment.done ? Color.ink3 : Color.ink2)
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(moment.text)
                    .font(.system(size: 15))
                    .foregroundStyle(moment.done ? Color.ink3 : Color.ink)
                    .strikethrough(moment.done, color: Color.ink3)
                    .fixedSize(horizontal: false, vertical: true)
                if let meta {
                    Text(meta).font(.system(size: 12.5, weight: .medium)).foregroundStyle(Color.ink3)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 11)
    }

    private var meta: String? {
        var parts: [String] = []
        if let direction = moment.direction { parts.append(direction == .mine ? "You owe" : "Owed to you") }
        if let who = moment.who, !who.isEmpty { parts.append(who) }
        if let due = moment.due { parts.append("Due \(PhoneFmt.day(due))") }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}

/// Lays children out left to right, wrapping onto new lines.
struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, lineHeight: CGFloat = 0, widest: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > 0 && x + size.width > width {
                y += lineHeight + spacing
                x = 0
                lineHeight = 0
            }
            x += size.width + spacing
            widest = max(widest, x - spacing)
            lineHeight = max(lineHeight, size.height)
        }
        return CGSize(width: min(widest, width), height: y + lineHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, lineHeight: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > bounds.minX && x + size.width > bounds.maxX {
                y += lineHeight + spacing
                x = bounds.minX
                lineHeight = 0
            }
            view.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
        }
    }
}
