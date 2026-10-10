import MemoryKit
import SwiftUI

/// Memory's Topics view: areas as quiet headers with their topics under them, what's not sorted yet, and
/// (one chip away) people, organisations and projects in the lens's words. On top, at most three quiet
/// lines: what Docket reorganised since you last looked, the week's digest and connections you haven't
/// made, each one line until clicked. A click on anything opens its page on the right.
struct BrainTopicsView: View {
    @EnvironmentObject var app: AppState
    @ObservedObject private var center = MemoryCenter.shared
    @ObservedObject private var brain = MemoryCenter.shared.brain
    @ObservedObject private var library = MemoryCenter.shared.library
    @AppStorage("brainListKind") private var listRaw = BrainListKind.topics.rawValue
    /// Bumped when the banner is dismissed (its date lives in `BrainBanner.seenKey`).
    @AppStorage(BrainBanner.seenKey) private var seenStamp: Double = 0
    @State private var unsortedOpen = false

    private var list: BrainListKind { BrainListKind(rawValue: listRaw) ?? .topics }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Space.lg) {
                kindRow
                if let problem = brain.loadProblem {
                    MemoryNote(icon: "exclamationmark.triangle.fill", warning: true, text: problem)
                }
                if list == .topics {
                    topics
                } else {
                    entities(list.entityKind)
                }
            }
            .padding(.horizontal, Space.gutter)
            .padding(.top, Space.xs)
            .padding(.bottom, Space.x4)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// Topics · People · Organisations · Projects (lens words).
    private var kindRow: some View {
        let vocabulary = library.vocabulary
        return HStack(spacing: 6) {
            ForEach(BrainListKind.allCases, id: \.self) { kind in
                MemoryChip(title: kind.label(vocabulary), isOn: list == kind, help: "Show \(kind.label(vocabulary).lowercased())") {
                    withAnimation(Motion.snappy) { listRaw = kind.rawValue }
                }
            }
        }
    }

    // MARK: Topics

    @ViewBuilder
    private var topics: some View {
        let areas = brain.areas()
        let loose = brain.topics(in: nil)
        if areas.isEmpty && loose.isEmpty {
            notOrganised
        } else {
            BrainBannerLine(seenStamp: $seenStamp)
            BrainInsightsCard()
            let slots = BrainPalette.slots(for: areas.map(\.id))
            ForEach(areas) { area in
                let kids = brain.topics(in: area.id)
                if !kids.isEmpty || area.itemCount > 0 {
                    section(area, topics: kids, slot: slots[area.id])
                }
            }
            if !loose.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    Eyebrow(text: areas.isEmpty ? "Topics" : "Other topics").padding(.leading, Space.md).padding(.bottom, 4)
                    ForEach(loose) { t in row(t, slot: nil) }
                }
                .padding(.horizontal, -Space.md)
            }
            unsorted
            organisedLine
        }
    }

    /// An area: its name as a quiet header (a click opens the area's page), its topics as rows.
    private func section(_ area: BrainEntity, topics: [BrainEntity], slot: Int?) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Button { open(area.id) } label: {
                HStack(spacing: 6) {
                    Eyebrow(text: area.name)
                    Text("\(area.itemCount)")
                        .font(.system(size: 10.5, weight: .bold))
                        .monospacedDigit()
                        .foregroundStyle(Color.ink3.opacity(0.8))
                }
                .padding(.horizontal, Space.md)
                .padding(.bottom, 4)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Open \(area.name)")
            ForEach(topics) { t in row(t, slot: slot) }
        }
        .padding(.horizontal, -Space.md)
    }

    private func row(_ e: BrainEntity, slot: Int?) -> some View {
        BrainEntityRow(entity: e, slot: slot, isSelected: app.selectedEntityID == e.id,
                       secondLine: secondLine(e)) { open(e.id) }
    }

    /// "4 memories · 2 sub-topics", or for people "3 memories · also Priya, P. Shah".
    private func secondLine(_ e: BrainEntity) -> String {
        var parts = [BrainText.memories(e.itemCount)]
        let kids = e.kind == .topic ? brain.children(of: e.id).count : 0
        if kids > 0 { parts.append(BrainText.subTopics(kids)) }
        if e.kind.isExtracted, let others = BrainText.aliases(e, limit: 2) { parts.append(others) }
        return parts.joined(separator: " · ")
    }

    /// "12 not sorted yet": a click shows them (each opens; the detail files it).
    @ViewBuilder
    private var unsorted: some View {
        let items = brain.unsortedItems
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: 2) {
                Button { withAnimation(Motion.snappy) { unsortedOpen.toggle() } } label: {
                    HStack(spacing: Space.md) {
                        Image(systemName: "tray")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(Color.ink2)
                            .frame(width: 8)
                            .padding(.horizontal, 2)
                        Text(BrainText.unsorted(items.count))
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(Color.ink2)
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(Color.ink3)
                            .rotationEffect(.degrees(unsortedOpen ? 90 : 0))
                    }
                    .padding(.horizontal, Space.md)
                    .frame(height: 40)
                    .contentShape(Rectangle())
                    .hoverHighlight(cornerRadius: Radius.md)
                }
                .buttonStyle(.plain)
                .help("Docket files these at the next reorganisation, or file one yourself from its detail")
                if unsortedOpen {
                    ForEach(items.prefix(30)) { item in
                        Button { app.selectedMemoryID = item.id } label: {
                            HStack(spacing: Space.md) {
                                MemoryKindTile(item: item, size: 26)
                                Text(item.displayTitle)
                                    .font(.system(size: 13.5, weight: .semibold))
                                    .foregroundStyle(Color.ink)
                                    .lineLimit(1)
                                Spacer(minLength: Space.sm)
                                Text(MemoryText.date(item.createdAt, now: app.clock))
                                    .font(.system(size: 12.5, weight: .bold))
                                    .monospacedDigit()
                                    .foregroundStyle(Color.ink2)
                                    .fixedSize()
                            }
                            .padding(.horizontal, Space.md)
                            .padding(.vertical, 6)
                            .contentShape(Rectangle())
                            .hoverHighlight(cornerRadius: Radius.sm)
                        }
                        .buttonStyle(PressScale(scale: 0.985))
                        .transition(.opacity)
                    }
                }
            }
            .padding(.horizontal, -Space.md)
        }
    }

    /// "Organised Thu 8 Oct · Organise now", quietly at the end.
    private var organisedLine: some View {
        HStack(spacing: 6) {
            Text(center.brainLine)
            if !brain.isWorking {
                Text("·")
                Button("Organise now") { center.organizeNow() }
                    .buttonStyle(.plain)
                    .foregroundStyle(Color.ink2)
                    .help("Sort memories into topics again (what you fixed by hand stays)")
            }
        }
        .font(.system(size: 12, weight: .medium))
        .foregroundStyle(Color.ink3)
        .padding(.top, Space.sm)
    }

    private var notOrganised: some View {
        VStack(spacing: Space.md) {
            EmptyState(icon: "square.grid.2x2", title: "No topics yet",
                       message: library.count < brain.minimumItemsToOrganize
                       ? "Once there are a few memories, Docket sorts them into topics and areas by itself."
                       : "Docket sorts your memories into topics and areas by itself, or now if you like.")
            if library.count >= brain.minimumItemsToOrganize {
                Button(brain.isWorking ? "Organising…" : "Organise now") { center.organizeNow() }
                    .buttonStyle(PrimaryPill())
                    .disabled(brain.isWorking)
            }
        }
        .frame(minHeight: 320)
    }

    // MARK: People, organisations, projects

    @ViewBuilder
    private func entities(_ kind: EntityKind) -> some View {
        let all = brain.entities(kind).filter { $0.itemCount > 0 }
        if all.isEmpty {
            Text("No \(kind.pluralLabel(library.vocabulary).lowercased()) yet.")
                .textStyle(.callout)
                .foregroundStyle(Color.ink2)
                .padding(.vertical, Space.lg)
        } else {
            LazyVStack(alignment: .leading, spacing: 2) {
                ForEach(all.prefix(300)) { e in row(e, slot: nil) }
            }
            .padding(.horizontal, -Space.md)
        }
    }

    private func open(_ id: UUID) {
        if app.selectedEntityID == id {
            withAnimation(Motion.sheet) { app.selectedEntityID = nil }
        } else {
            app.selectedEntityID = id
        }
    }
}

/// One topic, person, organisation or project: its area's colour (topics), name, a quiet second line, and
/// when it was last seen (a real date) on the right.
struct BrainEntityRow: View {
    @EnvironmentObject var app: AppState
    let entity: BrainEntity
    let slot: Int?
    let isSelected: Bool
    let secondLine: String
    let action: () -> Void
    @Environment(\.colorScheme) private var scheme
    @State private var hovering = false

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Radius.md, style: .continuous)
        Button(action: action) {
            HStack(spacing: Space.md) {
                marker
                VStack(alignment: .leading, spacing: 2) {
                    Text(entity.name)
                        .font(.system(size: 14, weight: .semibold))
                        .tracking(-0.2)
                        .foregroundStyle(Color.ink)
                        .lineLimit(1)
                    Text(secondLine)
                        .font(.system(size: 12.5))
                        .foregroundStyle(Color.ink2)
                        .lineLimit(1)
                }
                Spacer(minLength: Space.sm)
                if let last = entity.lastSeen {
                    Text(MemoryText.date(last, now: app.clock))
                        .font(.system(size: 14, weight: .bold))
                        .tracking(-0.2)
                        .monospacedDigit()
                        .foregroundStyle(Color.ink)
                        .lineLimit(1)
                        .fixedSize()
                        .help("Last seen")
                }
            }
            .padding(.horizontal, Space.md)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(shape.fill(isSelected ? Color.fill : (hovering ? Color.pressedTint : Color.clear)))
            .overlay(shape.strokeBorder(isSelected ? Color.hairStrong : Color.clear, lineWidth: 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(PressScale(scale: 0.99))
        .onHover { h in withAnimation(Motion.fast) { hovering = h } }
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }

    /// Topics: a dot in their area's map colour. Others: their kind's symbol.
    @ViewBuilder
    private var marker: some View {
        if entity.kind == .topic {
            Circle()
                .fill(slot.map { Color(nsColor: NSColor(hex: BrainPalette.hex(slot: $0, dark: scheme == .dark))) } ?? Color.ink3)
                .frame(width: 8, height: 8)
                .frame(width: 12)
        } else {
            Image(systemName: entity.kind.symbolName)
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(Color.ink2)
                .frame(width: 28, height: 28)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.fill))
        }
    }
}

// MARK: - Banner

/// "Docket reorganised your memory: 2 new topics, 1 merged" until dismissed.
private struct BrainBannerLine: View {
    @EnvironmentObject var app: AppState
    @ObservedObject private var brain = MemoryCenter.shared.brain
    @Binding var seenStamp: Double

    var body: some View {
        let seen = seenStamp > 0 ? Date(timeIntervalSince1970: seenStamp) : nil
        if let line = BrainBanner.line(brain.changeLog, since: seen, now: app.clock) {
            HStack(spacing: Space.sm) {
                Image(systemName: "sparkles")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Color.ink3)
                Text(line.text)
                    .textStyle(.footnote)
                    .foregroundStyle(Color.ink2)
                    .lineLimit(1)
                    .help(details(since: seen))
                Spacer(minLength: Space.sm)
                Button { withAnimation(Motion.gentle) { seenStamp = line.newest.timeIntervalSince1970 } } label: {
                    Image(systemName: "xmark").font(.system(size: 10, weight: .bold))
                }
                .buttonStyle(IconButtonStyle(size: 22))
                .help("Got it")
                .accessibilityLabel("Dismiss")
            }
            .transition(.opacity)
        }
    }

    private func details(since seen: Date?) -> String {
        let cutoff = seen ?? app.clock.addingTimeInterval(-BrainBanner.firstLookWindow)
        return brain.changeLog.filter { $0.kind != .correction && $0.date > cutoff }
            .map { "\(MemoryText.date($0.date, now: app.clock)): \($0.summary)" }
            .joined(separator: "\n")
    }
}

// MARK: - Digest and connections

/// The week's digest and the connections you haven't made: one line each, opened with a click.
private struct BrainInsightsCard: View {
    @EnvironmentObject var app: AppState
    @ObservedObject private var brain = MemoryCenter.shared.brain
    @ObservedObject private var library = MemoryCenter.shared.library
    @AppStorage("brainDigestOpen") private var digestOpen = false
    @AppStorage("brainConnectionsOpen") private var connectionsOpen = false

    var body: some View {
        let digest = currentDigest
        let connections = Array(brain.connections.prefix(3))
        if digest != nil || !connections.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                if let digest {
                    header(icon: "calendar", title: BrainText.digestTitle(digest, now: app.clock),
                           line: BrainText.digestLine(digest, vocabulary: library.vocabulary), open: $digestOpen)
                    if digestOpen { digestBody(digest).transition(.opacity) }
                }
                if digest != nil && !connections.isEmpty {
                    Rectangle().fill(Color.hair).frame(height: 1).padding(.leading, Space.md)
                }
                if !connections.isEmpty {
                    header(icon: "point.3.connected.trianglepath.dotted", title: BrainText.connections(connections.count),
                           line: connections[0].reason, open: $connectionsOpen)
                    if connectionsOpen {
                        VStack(alignment: .leading, spacing: Space.md) {
                            ForEach(connections) { c in connectionRow(c) }
                        }
                        .padding(.horizontal, Space.md)
                        .padding(.bottom, Space.md)
                        .transition(.opacity)
                    }
                }
            }
            .hairlineCard(radius: Radius.lg)
        }
    }

    /// This week's digest, or last week's early in a quiet week.
    private var currentDigest: BrainDigest? {
        let now = app.clock
        let this = brain.digest(for: now)
        if this.itemCount > 0 { return this }
        let last = brain.digest(for: BrainInsights.week(of: now).start.addingTimeInterval(-86_400))
        return last.itemCount > 0 ? last : nil
    }

    private func header(icon: String, title: String, line: String, open: Binding<Bool>) -> some View {
        Button { withAnimation(Motion.snappy) { open.wrappedValue.toggle() } } label: {
            HStack(spacing: Space.sm) {
                Image(systemName: icon)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color.ink2)
                    .frame(width: 18)
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color.ink)
                    .lineLimit(1)
                    .fixedSize()
                if !open.wrappedValue {
                    Text(line)
                        .font(.system(size: 12.5))
                        .foregroundStyle(Color.ink2)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                Spacer(minLength: Space.xs)
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(Color.ink3)
                    .rotationEffect(.degrees(open.wrappedValue ? 90 : 0))
            }
            .padding(.horizontal, Space.md)
            .frame(height: 40)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: Digest

    @ViewBuilder
    private func digestBody(_ d: BrainDigest) -> some View {
        let vocabulary = library.vocabulary
        VStack(alignment: .leading, spacing: Space.md) {
            if d.isWritten {
                Text(attributed(d))
                    .font(.system(size: 14))
                    .lineSpacing(4)
                    .foregroundStyle(Color.bodyText)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                    .environment(\.openURL, OpenURLAction { url in
                        guard let n = MemoryAnswerLinks.citation(url), n >= 1, n <= d.sources.count else { return .systemAction }
                        withAnimation(Motion.sheet) { app.selectedMemoryID = d.sources[n - 1] }
                        return .handled
                    })
            } else {
                Text(BrainText.digestLine(d, vocabulary: vocabulary))
                    .textStyle(.callout)
                    .foregroundStyle(Color.ink2)
            }
            let topics = d.newTopics.isEmpty ? d.biggestTopics : d.newTopics
            if !topics.isEmpty {
                FlowLayout(spacing: Space.sm, lineSpacing: Space.sm) {
                    ForEach(topics) { t in
                        SuggestionChip(title: "\(t.name)  +\(t.count)", icon: d.newTopics.isEmpty ? "number" : "sparkles") {
                            app.selectedEntityID = t.topicID
                        }
                        .help(d.newTopics.isEmpty ? "Busiest this week" : "New this week")
                    }
                }
            }
            if !d.isWritten {
                momentList(vocabulary.decisions, d.decisions)
                momentList("Open \(vocabulary.promises.lowercased())", d.openPromises)
            }
        }
        .padding(.horizontal, Space.md)
        .padding(.bottom, Space.md)
    }

    @ViewBuilder
    private func momentList(_ title: String, _ moments: [DigestMoment]) -> some View {
        if !moments.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                Eyebrow(text: title)
                ForEach(moments.prefix(4)) { m in
                    Button { app.selectedMemoryID = m.itemID } label: {
                        HStack(alignment: .firstTextBaseline, spacing: Space.sm) {
                            Image(systemName: MemoryText.symbol(for: m.kind))
                                .font(.system(size: 10.5, weight: .semibold))
                                .foregroundStyle(Color.ink3)
                                .frame(width: 14)
                            Text(m.text)
                                .font(.system(size: 13, weight: .medium))
                                .foregroundStyle(Color.ink)
                                .lineLimit(2)
                                .multilineTextAlignment(.leading)
                            Spacer(minLength: 0)
                            if let due = m.due {
                                Text(MemoryText.date(due, now: app.clock))
                                    .font(.system(size: 12, weight: .bold))
                                    .monospacedDigit()
                                    .foregroundStyle(Color.ink2)
                                    .fixedSize()
                            }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private func attributed(_ d: BrainDigest) -> AttributedString {
        var out = AttributedString()
        for segment in BrainText.summarySegments(d.text, sources: d.sources.count) {
            switch segment {
            case .text(let s): out += BrainText.inline(s)
            case .citation(let n): out += MemoryAnswerLinks.chip(n)
            }
        }
        return out
    }

    // MARK: Connections

    private func connectionRow(_ c: BrainConnection) -> some View {
        HStack(alignment: .top, spacing: Space.sm) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    itemButton(c.a)
                    Image(systemName: "arrow.left.and.right")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(Color.ink3)
                    itemButton(c.b)
                }
                Text(c.reason)
                    .font(.system(size: 12.5))
                    .foregroundStyle(Color.ink2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            Button { withAnimation(Motion.base) { brain.dismissConnection(c.id) } } label: {
                Image(systemName: "xmark").font(.system(size: 9.5, weight: .bold))
            }
            .buttonStyle(IconButtonStyle(size: 22))
            .help("Not useful: don't show it again")
        }
    }

    @ViewBuilder
    private func itemButton(_ id: UUID) -> some View {
        if let item = library.item(id) {
            Button(item.displayTitle) { withAnimation(Motion.sheet) { app.selectedMemoryID = id } }
                .buttonStyle(.plain)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Color.ink)
                .lineLimit(1)
                .truncationMode(.tail)
                .help("Open “\(item.displayTitle)”")
        }
    }
}
