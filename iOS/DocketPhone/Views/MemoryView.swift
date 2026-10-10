import MemoryKit
import SwiftUI
import UIKit

/// A filter chip's meaning, labelled with the lens vocabulary ("Learnings", "Objections", …).
struct MemoryChip: Identifiable, Hashable {
    let id: String
    let title: String
    let filter: MemoryFilter

    static func chips(_ vocabulary: LensVocabulary) -> [MemoryChip] {
        [
            MemoryChip(id: "all", title: "All", filter: MemoryFilter()),
            MemoryChip(id: "decision", title: vocabulary.decisions, filter: MemoryFilter(momentKind: .decision)),
            MemoryChip(id: "promise", title: vocabulary.promises, filter: MemoryFilter(momentKind: .promise, openOnly: true)),
            MemoryChip(id: "idea", title: vocabulary.ideas, filter: MemoryFilter(momentKind: .idea)),
            MemoryChip(id: "insight", title: vocabulary.insights, filter: MemoryFilter(momentKind: .insight)),
            MemoryChip(id: "link", title: "Links", filter: MemoryFilter(kinds: [.link])),
            MemoryChip(id: "voice", title: "Voice notes", filter: MemoryFilter(kinds: [.audio])),
            MemoryChip(id: "image", title: "Images", filter: MemoryFilter(kinds: [.image, .video])),
        ]
    }
}

/// Search state for the Memory tab: text results at once, then by meaning when a key is set and
/// the Mac's vectors match Gemini's model. Searching runs off the main thread.
@MainActor
final class MemoryBrowser: ObservableObject {
    @Published var query = ""
    @Published var chipID = "all"
    @Published private(set) var results: [MemoryItem] = []
    @Published private(set) var hasSearched = false

    private var task: Task<Void, Never>?

    func update(search: MemorySearch?, chips: [MemoryChip], ai: MemoryAI?) {
        task?.cancel()
        guard let search else {
            results = []
            return
        }
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let filter = chips.first { $0.id == chipID }?.filter ?? MemoryFilter()
        task = Task {
            let textHits = await Task.detached(priority: .userInitiated) {
                search.search(q, filter: filter, limit: q.isEmpty ? 2000 : 60)
            }.value
            guard !Task.isCancelled else { return }
            results = textHits.map(\.item)
            hasSearched = true
            guard !q.isEmpty, let ai,
                  search.vectors.isCompatible(model: ai.embeddingModel, dimensions: ai.embeddingDimensions) else { return }
            try? await Task.sleep(nanoseconds: 400_000_000)
            guard !Task.isCancelled, let vector = try? await ai.embed([q], task: .query).first, !Task.isCancelled else { return }
            let model = ai.embeddingModel
            let hits = await Task.detached(priority: .userInitiated) {
                search.search(q, queryVector: vector, model: model, filter: filter, limit: 60)
            }.value
            guard !Task.isCancelled else { return }
            results = hits.map(\.item)
        }
    }
}

struct MemoryView: View {
    @EnvironmentObject private var model: AppModel
    @StateObject private var browser = MemoryBrowser()

    private var chips: [MemoryChip] { MemoryChip.chips(model.vocabulary) }

    var body: some View {
        NavigationStack(path: $model.memoryPath) {
            content
                .paperBackground()
                .navigationTitle("Memory")
                .toolbar { ToolbarItem(placement: .topBarTrailing) { SettingsButton() } }
                .navigationDestination(for: UUID.self) { id in
                    ItemDetailView(itemID: id)
                }
        }
        .onAppear { runSearch() }
        .onChange(of: browser.query) { _, _ in runSearch() }
        .onChange(of: browser.chipID) { _, _ in runSearch() }
        .onChange(of: model.snapshot?.generatedAt) { _, _ in runSearch() }
    }

    private func runSearch() {
        browser.update(search: model.search, chips: chips, ai: model.makeAI())
    }

    @ViewBuilder
    private var content: some View {
        if model.snapshot == nil {
            ScrollView {
                LibraryEmptyState()
                    .padding(.horizontal, Space.gutter)
                    .padding(.top, Space.x4)
            }
            .refreshable { await model.refresh(force: true) }
        } else {
            List {
                Section {
                    chipRow
                        .listRowInsets(EdgeInsets())
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                    if let line = model.lastUpdatedLine {
                        Text(line)
                            .font(.system(size: 12.5, weight: .medium))
                            .foregroundStyle(Color.ink3)
                            .listRowInsets(EdgeInsets(top: 2, leading: Space.gutter, bottom: 6, trailing: Space.gutter))
                            .listRowBackground(Color.clear)
                            .listRowSeparator(.hidden)
                    }
                }
                Section {
                    if browser.results.isEmpty && browser.hasSearched {
                        Text(browser.query.isEmpty ? "Nothing here yet." : "Nothing in your memory matches “\(browser.query)”.")
                            .font(.system(size: 15))
                            .foregroundStyle(Color.ink2)
                            .listRowBackground(Color.clear)
                            .listRowSeparator(.hidden)
                    }
                    ForEach(browser.results) { item in
                        NavigationLink(value: item.id) {
                            MemoryRow(item: item)
                        }
                        .listRowBackground(Color.paper)
                        .listRowSeparatorTint(Color.hair)
                        .listRowInsets(EdgeInsets(top: 12, leading: Space.gutter, bottom: 12, trailing: Space.lg))
                        .alignmentGuide(.listRowSeparatorLeading) { _ in 56 }
                    }
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .searchable(text: $browser.query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search your memory")
            .refreshable { await model.refresh(force: true) }
        }
    }

    private var chipRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: Space.sm) {
                ForEach(chips) { chip in
                    FilterChip(title: chip.title, selected: browser.chipID == chip.id) {
                        Haptics.select()
                        withAnimation(Motion.snappy) { browser.chipID = chip.id }
                    }
                }
            }
            .padding(.horizontal, Space.gutter)
            .padding(.vertical, Space.sm)
        }
    }
}

/// What to show before the Mac's library has arrived.
struct LibraryEmptyState: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: Space.md) {
            Image(systemName: symbol)
                .font(.system(size: 28, weight: .regular))
                .foregroundStyle(Color.ink3)
                .padding(.bottom, Space.xs)
            Text(title).textStyle(.title3).foregroundStyle(Color.ink)
            Text(message)
                .font(.system(size: 15))
                .foregroundStyle(Color.ink2)
                .fixedSize(horizontal: false, vertical: true)
            if model.libraryState == .noFolder {
                Button("Choose folder") { model.showSettings = true }
                    .buttonStyle(PrimaryPill(height: 42))
                    .padding(.top, Space.sm)
            } else if model.libraryState == .loading || model.libraryState == .downloading {
                ProgressView().tint(Color.ink2).padding(.top, Space.sm)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var symbol: String {
        switch model.libraryState {
        case .noFolder: "folder"
        case .loading, .downloading: "icloud.and.arrow.down"
        case .waitingForMac, .ready: "desktopcomputer"
        case .problem: "exclamationmark.triangle"
        }
    }

    private var title: String {
        switch model.libraryState {
        case .noFolder: "Choose your Docket folder"
        case .loading: "Opening your memory…"
        case .downloading: "Downloading from iCloud…"
        case .waitingForMac, .ready: "Nothing from your Mac yet"
        case .problem: "Can't read your memory"
        }
    }

    private var message: String {
        switch model.libraryState {
        case .noFolder: "Your memory lives on your Mac. It reaches this iPhone through a Docket folder in iCloud Drive."
        case .loading: "Reading the latest update from your Mac."
        case .downloading: "Your memory is in iCloud and on its way to this iPhone."
        case .waitingForMac, .ready: "On your Mac: Settings → Memory → iPhone. Your library shows up here after the next sync."
        case .problem(let message): message
        }
    }
}

// MARK: - Rows

struct MemoryRow: View {
    let item: MemoryItem
    @EnvironmentObject private var model: AppModel

    var body: some View {
        HStack(alignment: .top, spacing: Space.md) {
            ItemThumb(item: item, size: 40)
            VStack(alignment: .leading, spacing: 4) {
                Text(item.displayTitle)
                    .font(.system(size: 16, weight: .semibold))
                    .tracking(-0.2)
                    .foregroundStyle(Color.ink)
                    .lineLimit(2)
                if !item.summary.isEmpty {
                    Text(item.summary)
                        .font(.system(size: 14))
                        .foregroundStyle(Color.ink2)
                        .lineLimit(2)
                }
                Text(meta)
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(Color.ink3)
                    .lineLimit(1)
            }
        }
    }

    private var meta: String {
        var parts = [PhoneFmt.day(item.createdAt), item.kind.label]
        if let person = item.people.first { parts.append(item.people.count > 1 ? "\(person) +\(item.people.count - 1)" : person) }
        return parts.joined(separator: " · ")
    }
}

/// An item's thumbnail from Library/Thumbs when the Mac published one, else its kind's symbol.
struct ItemThumb: View {
    let item: MemoryItem
    var size: CGFloat = 40
    @EnvironmentObject private var model: AppModel
    @State private var image: UIImage?

    var body: some View {
        KindTile(symbol: item.kind.symbolName, size: size, image: image)
            .task(id: item.id) { image = await ThumbnailCache.shared.image(for: item, url: model.thumbnailURL(for: item.id)) }
    }
}

/// Thumbnails read off the main thread (downloading from iCloud when needed), kept in memory.
@MainActor
final class ThumbnailCache {
    static let shared = ThumbnailCache()
    private var images: [UUID: UIImage] = [:]
    private var missing: Set<UUID> = []

    func image(for item: MemoryItem, url: URL?) async -> UIImage? {
        if let cached = images[item.id] { return cached }
        guard let url, !missing.contains(item.id), item.attachments.contains(where: \.isImage) || item.kind == .image else { return nil }
        let (data, absent) = await Task.detached(priority: .utility) { () -> (Data?, Bool) in
            switch CloudFiles.prepare(url) {
            case .missing: return (nil, true)
            case .downloading: return (nil, false)
            case .ready: return (try? CloudFiles.read(url) { try Data(contentsOf: $0) }, false)
            }
        }.value
        guard let data, let image = UIImage(data: data) else {
            if absent { missing.insert(item.id) }
            return nil
        }
        images[item.id] = image
        return image
    }

    func reset() {
        images = [:]
        missing = []
    }
}
