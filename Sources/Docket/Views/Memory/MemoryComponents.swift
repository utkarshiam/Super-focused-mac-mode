import AppKit
import MemoryKit
import SwiftUI
import UniformTypeIdentifiers

// Pieces the Memory screens share, and the "From memory" strip message threads show (tasks have their Brief).

// MARK: - Pictures

/// The picture for a memory, if it has one: its first photo (or a video's first frame, or a PDF's first
/// page), else a link's preview image. Decoded once and kept by `MediaCache`.
enum MemoryVisual {
    @MainActor
    static func image(for item: MemoryItem, library: MemoryLibrary) -> NSImage? {
        for a in item.attachments {
            let url = library.fileURL(for: a, of: item.id)
            if a.isImage { if let image = MediaCache.shared.image(for: url) { return image } else { continue } }
            if a.mimeType.hasPrefix("video/") { return MediaCache.shared.poster(for: url) }
            if a.mimeType == "application/pdf" { return MediaCache.shared.pdf(for: url)?.thumbnail }
        }
        if let address = item.imageURL, let url = URL(string: address), MediaLibrary.isWebURL(url),
           case .ready(let local) = RemoteMedia.shared.file(for: url) {
            return MediaCache.shared.image(for: local)
        }
        return nil
    }
}

/// A memory's kind as a small rounded tile, or its picture when it has one.
struct MemoryKindTile: View {
    let item: MemoryItem
    var size: CGFloat = 36
    @ObservedObject private var library = MemoryCenter.shared.library
    /// Bumped when a picture finishes loading, so the tile looks again.
    @State private var loaded = 0

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
        ZStack {
            shape.fill(Color.fill)
            if let image = MemoryVisual.image(for: item, library: library) {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(width: size, height: size)
                    .clipShape(shape)
            } else {
                Image(systemName: item.kind.symbolName)
                    .font(.system(size: size * 0.38, weight: .semibold))
                    .foregroundStyle(Color.ink2)
            }
        }
        .frame(width: size, height: size)
        .overlay(shape.strokeBorder(Color.hair, lineWidth: 1))
        .id(loaded)
        .onReceive(NotificationCenter.default.publisher(for: MediaCache.didLoad)) { _ in loaded += 1 }
        .accessibilityLabel(item.kind.label)
    }
}

// MARK: - Chips

/// A filter chip: ink on a soft fill when on, a hairline outline when off.
struct MemoryChip: View {
    let title: String
    var icon: String?
    var isOn = false
    var trailingIcon: String?
    var help = ""
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                if let icon { Image(systemName: icon).font(.system(size: 10, weight: .bold)) }
                Text(title).lineLimit(1)
                if let trailingIcon { Image(systemName: trailingIcon).font(.system(size: 8.5, weight: .heavy)) }
            }
            .font(.system(size: 12.5, weight: .semibold))
            .foregroundStyle(isOn ? Color.ink : Color.ink2)
            .padding(.horizontal, 11)
            .frame(height: 26)
            .background(Capsule().fill(isOn ? Color.fillStrong : (hovering ? Color.pressedTint : Color.clear)))
            .overlay(Capsule().strokeBorder(isOn ? Color.clear : Color.hair, lineWidth: 1))
            .contentShape(Capsule())
            .fixedSize()
        }
        .buttonStyle(PressScale(scale: 0.95))
        .onHover { h in withAnimation(Motion.fast) { hovering = h } }
        .help(help)
        .accessibilityAddTraits(isOn ? [.isButton, .isSelected] : .isButton)
    }
}

/// A soft suggestion: an example question, a follow-up, a person to filter by.
struct SuggestionChip: View {
    let title: String
    var icon: String?
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                if let icon { Image(systemName: icon).font(.system(size: 10, weight: .bold)).foregroundStyle(Color.ink3) }
                Text(title).lineLimit(1).truncationMode(.tail)
            }
            .font(.system(size: 12.5, weight: .medium))
            .foregroundStyle(Color.ink2)
            .padding(.horizontal, 11)
            .frame(height: 28)
        }
        .buttonStyle(MenuChromeStyle(shape: Capsule(), fill: .fill, hoverFill: .fillStrong))
    }
}

/// A calm line: an icon, what's up, and (optionally) what to do about it.
struct MemoryNote<Trailing: View>: View {
    let icon: String
    var warning = false
    let text: String
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(alignment: .center, spacing: Space.sm) {
            Image(systemName: icon)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(warning ? Color.warning : Color.ink3)
            Text(text)
                .textStyle(.footnote)
                .foregroundStyle(Color.ink2)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: Space.sm)
            trailing
        }
        .transition(.opacity)
    }
}

extension MemoryNote where Trailing == EmptyView {
    init(icon: String, warning: Bool = false, text: String) {
        self.init(icon: icon, warning: warning, text: text) { EmptyView() }
    }
}

/// Opens Settings on the AI page.
@MainActor
enum MemorySettings {
    static func openAI(_ app: AppState) {
        UserDefaults.standard.set(SettingsView.Tab.ai.rawValue, forKey: SettingsView.tabKey)
        app.showSettings()
    }
}

// MARK: - Lenses

extension Lens {
    /// Its symbol, or a stand-in where this macOS doesn't have that one ("handshake" is new).
    var symbol: String {
        if NSImage(systemSymbolName: symbolName, accessibilityDescription: nil) != nil { return symbolName }
        switch self {
        case .sales: return "chart.line.uptrend.xyaxis"
        case .manager: return "person.2"
        case .engineer: return "hammer"
        default: return "person"
        }
    }
}

/// One role on the onboarding card: its symbol, name and what Docket listens for. `primary`: picked first,
/// so it names things.
struct LensCard: View {
    let lens: Lens
    let isOn: Bool
    let primary: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Radius.md, style: .continuous)
        Button(action: action) {
            HStack(alignment: .top, spacing: Space.md) {
                Image(systemName: lens.symbol)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(isOn ? Color.onPrimary : Color.ink)
                    .frame(width: 34, height: 34)
                    .background(Circle().fill(isOn ? Color.primaryFill : Color.fill))
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(lens.displayName)
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(Color.ink)
                        if primary {
                            Text("Main")
                                .font(.system(size: 10, weight: .bold))
                                .foregroundStyle(Color.ink2)
                                .padding(.horizontal, 6)
                                .frame(height: 16)
                                .background(Capsule().fill(Color.fillStrong))
                        }
                    }
                    Text(lens.blurb)
                        .font(.system(size: 12))
                        .foregroundStyle(Color.ink2)
                        .lineLimit(3)
                        .fixedSize(horizontal: false, vertical: true)
                        .multilineTextAlignment(.leading)
                }
                Spacer(minLength: 0)
                Image(systemName: isOn ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(isOn ? Color.ink : Color.ink3)
            }
            .padding(Space.md)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(shape.fill(isOn ? Color.fill : (hovering ? Color.pressedTint : Color.card)))
            .overlay(shape.strokeBorder(isOn ? Color.hairStrong : Color.hair, lineWidth: 1))
            .contentShape(shape)
        }
        .buttonStyle(PressScale(scale: 0.985))
        .onHover { h in withAnimation(Motion.fast) { hovering = h } }
        .accessibilityAddTraits(isOn ? [.isButton, .isSelected] : .isButton)
    }
}

/// The lenses as small toggles (the profile view); the first one picked names things.
struct LensToggles: View {
    @ObservedObject var library: MemoryLibrary

    var body: some View {
        FlowLayout(spacing: Space.sm, lineSpacing: Space.sm) {
            ForEach(Lens.allCases) { lens in
                let on = library.lenses.contains(lens)
                MemoryChip(title: lens.displayName, icon: lens.symbol, isOn: on,
                           trailingIcon: on && library.lenses.first == lens && library.lenses.count > 1 ? "star.fill" : nil,
                           help: on ? "Stop using the \(lens.displayName) lens" : lens.blurb) {
                    var next = library.lenses
                    if on { next.removeAll { $0 == lens } } else { next.append(lens) }
                    withAnimation(Motion.snappy) { library.setLenses(next) }
                }
            }
        }
    }
}

// MARK: - Dropping things in

/// Files, links and text dropped on Memory, read off the drop and saved.
@MainActor
enum MemoryDrop {
    static let types: [UTType] = [.fileURL, .url, .plainText]

    /// Reads what was dropped and hands it over (files, web links, text), on the main thread.
    static func read(_ providers: [NSItemProvider], then done: @escaping @MainActor (_ files: [URL], _ links: [URL], _ texts: [String]) -> Void) {
        let group = DispatchGroup()
        let lock = NSLock()
        var files: [URL] = [], links: [URL] = [], texts: [String] = []
        for provider in providers {
            group.enter()
            if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) || provider.hasItemConformingToTypeIdentifier(UTType.url.identifier) {
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    if let url {
                        lock.lock()
                        if url.isFileURL { files.append(url) } else { links.append(url) }
                        lock.unlock()
                    }
                    group.leave()
                }
            } else if provider.canLoadObject(ofClass: String.self) {
                _ = provider.loadObject(ofClass: String.self) { text, _ in
                    if let text {
                        lock.lock()
                        texts.append(text)
                        lock.unlock()
                    }
                    group.leave()
                }
            } else {
                group.leave()
            }
        }
        group.notify(queue: .main) {
            Task { @MainActor in done(files, links, texts) }
        }
    }

    /// Saves them; returns what was saved.
    static func save(files: [URL], links: [URL], texts: [String]) -> [MemoryItem] {
        let center = MemoryCenter.shared
        var saved = center.capture(fileURLs: files)
        saved += links.map { center.capture(link: $0) }
        saved += texts.compactMap { center.capture(text: $0) }
        return saved
    }
}

// MARK: - From memory (tasks and threads)

/// A few memories related to an open message thread: one quiet line, collapsed until clicked, hidden when
/// nothing is related. A click on one opens it in Memory. (A task's is `TaskBriefSection`.)
struct FromMemoryStrip: View {
    @EnvironmentObject var app: AppState
    /// What to find related memories for (a thread's text).
    let text: String
    /// Memories of the thing itself (its own sourceRefs), left out.
    var excluding: [String] = []
    @AppStorage("fromMemoryExpanded") private var expanded = false
    @State private var hits: [MemoryHit] = []

    /// Screenshots: what to show instead of searching (nil: search as usual).
    static var debugHits: [MemoryHit]?

    var body: some View {
        // A container that's always there, so the search runs even while there's nothing to show.
        VStack(spacing: 0) {
            if !hits.isEmpty {
                VStack(alignment: .leading, spacing: 0) {
                    Button { withAnimation(Motion.snappy) { expanded.toggle() } } label: { header }
                        .buttonStyle(.plain)
                        .help(expanded ? "Hide related memories" : "Show related memories")
                    if expanded {
                        VStack(alignment: .leading, spacing: 0) {
                            ForEach(hits) { hit in
                                row(hit.item)
                            }
                        }
                        .padding(.horizontal, Space.xs)
                        .padding(.bottom, Space.xs)
                        .transition(.opacity)
                    }
                }
                .hairlineCard(radius: Radius.lg)
                .transition(.opacity)
            }
        }
        .task(id: text) { await load() }
    }

    private var header: some View {
        HStack(spacing: Space.sm) {
            Image(systemName: "brain")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Color.ink2)
                .frame(width: 18)
            Text("From memory")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Color.ink)
                .fixedSize()
            if !expanded, let first = hits.first {
                Text(first.item.displayTitle + (hits.count > 1 ? " +\(hits.count - 1)" : ""))
                    .font(.system(size: 12.5))
                    .foregroundStyle(Color.ink2)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            Spacer(minLength: Space.xs)
            Image(systemName: "chevron.right")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(Color.ink3)
                .rotationEffect(.degrees(expanded ? 90 : 0))
        }
        .padding(.horizontal, Space.md)
        .frame(height: 40)
        .contentShape(Rectangle())
    }

    private func row(_ item: MemoryItem) -> some View {
        Button { app.reveal(memory: item.id) } label: {
            HStack(spacing: Space.sm) {
                MemoryKindTile(item: item, size: 26)
                VStack(alignment: .leading, spacing: 1) {
                    Text(item.displayTitle)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Color.ink)
                        .lineLimit(1)
                    if !item.summary.isEmpty {
                        Text(item.summary)
                            .font(.system(size: 11.5))
                            .foregroundStyle(Color.ink2)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: Space.xs)
                Text(MemoryText.date(item.createdAt, now: app.clock))
                    .font(.system(size: 12, weight: .bold))
                    .monospacedDigit()
                    .foregroundStyle(Color.ink2)
                    .fixedSize()
            }
            .padding(.horizontal, Space.sm)
            .padding(.vertical, 6)
            .contentShape(Rectangle())
            .hoverHighlight(cornerRadius: Radius.sm)
        }
        .buttonStyle(PressScale(scale: 0.985))
        .help("Open in Memory")
    }

    private func load() async {
        if let stub = Self.debugHits {
            hits = stub
            return
        }
        // Typing in a title shouldn't search on every keystroke.
        try? await Task.sleep(nanoseconds: 350_000_000)
        guard !Task.isCancelled else { return }
        let center = MemoryCenter.shared
        let skip = Set(excluding.compactMap { center.library.item(sourceRef: $0)?.id })
        // Tasks remembered by earlier versions aren't memories: never shown here.
        let found = await center.library.related(to: text, ai: center.processor.ai, excluding: skip, limit: 4)
            .filter { !TaskContext.isTaskItem($0.item) }.prefix(3).map { $0 }
        guard !Task.isCancelled else { return }
        withAnimation(Motion.base) { hits = found }
    }
}

// MARK: - Go ▸ Memory

extension AppDelegate {
    @objc func goToMemory(_ sender: Any?) {
        showMainWindow()
        app.selection = .memory
    }
}
