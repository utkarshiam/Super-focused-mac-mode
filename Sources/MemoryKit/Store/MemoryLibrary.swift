import Combine
import Foundation

/// The user's memory: items, their vectors and files, the profile and the chosen lenses, kept in one
/// directory. Main-actor bound and observable; SwiftUI views can read it directly.
///
/// Files in `directory`:
/// ```
/// memory.json          MemoryFileContents: {"version": 1, "items": [...], "profile": {...},
///                      "lenses": [...], "lensesChosen": true}; pretty-printed, sorted keys, ISO dates
/// vectors.bin          VectorIndex binary (model + dimensions stamped in the header)
/// Files/<itemID>/…     attachments, copied in
/// ```
/// Changes are saved after `saveDelay` (debounced, atomic writes on a background queue). Call `flush()`
/// when the app quits (and in tests) to write everything now.
@MainActor
public final class MemoryLibrary: ObservableObject {
    public nonisolated let directory: URL

    public nonisolated var fileURL: URL { directory.appendingPathComponent("memory.json") }
    public nonisolated var vectorsURL: URL { directory.appendingPathComponent("vectors.bin") }
    public nonisolated var filesURL: URL { directory.appendingPathComponent("Files", isDirectory: true) }

    /// Every item, newest `createdAt` first. Mutate through the methods below.
    public private(set) var items: [MemoryItem] = []
    @Published public private(set) var profile = MemoryProfile()
    /// The chosen lenses, primary first.
    @Published public private(set) var lenses: [Lens] = []
    /// Whether the user has been through lens onboarding (choosing none counts).
    @Published public private(set) var lensesChosen = false
    /// Bumps on every change (items, vectors, profile, lenses). Cheap to compare for caches.
    @Published public private(set) var revision = 0
    /// Set when memory.json couldn't be read at launch (it was set aside, the library started empty).
    @Published public private(set) var loadProblem: String?
    /// The last save failure, if the latest save failed.
    @Published public private(set) var saveProblem: String?

    /// Fires after every change (on the main actor). Debounce it to publish the phone snapshot.
    public let changes = PassthroughSubject<Void, Never>()

    /// How long changes wait before being written.
    public var saveDelay: TimeInterval

    private var positions: [UUID: Int] = [:]
    private var positionsValid = false
    private var refs: [String: UUID] = [:]
    private var loadedVectors: VectorIndex?
    private var vectorsDirty = false
    private var itemsDirty = false
    private var saveTask: Task<Void, Never>?
    private nonisolated let io = DispatchQueue(label: "MemoryKit.MemoryLibrary.io", qos: .utility)
    private var searchEntries: [UUID: (updatedAt: Date, entry: MemorySearch.Entry)] = [:]
    private var cachedSearch: (revision: Int, search: MemorySearch)?
    private var directoryCache: (revision: Int, people: [MemoryEntity], projects: [MemoryEntity], topics: [MemoryEntity])?
    var queryVectors: [String: [Float]] = [:]

    /// Opens (or creates) the library in `directory`. Reads memory.json now; vectors load on first use.
    public init(directory: URL, saveDelay: TimeInterval = 1.0) {
        self.directory = directory
        self.saveDelay = saveDelay
        load()
    }

    // MARK: Loading and saving

    struct FileContents: Codable {
        static let currentVersion = 1
        var version = FileContents.currentVersion
        var items: [MemoryItem] = []
        var profile = MemoryProfile()
        var lenses: [Lens] = []
        var lensesChosen = false

        init(items: [MemoryItem], profile: MemoryProfile, lenses: [Lens], lensesChosen: Bool) {
            self.items = items
            self.profile = profile
            self.lenses = lenses
            self.lensesChosen = lensesChosen
        }

        private enum CodingKeys: String, CodingKey { case version, items, profile, lenses, lensesChosen }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            version = c.value(.version, default: Self.currentVersion)
            items = c.value(.items, default: [])
            profile = c.value(.profile, default: MemoryProfile())
            lenses = Lens.decodeList(c.value(.lenses, default: [String]()))
            lensesChosen = c.value(.lensesChosen, default: !lenses.isEmpty)
        }
    }

    private func load() {
        let fm = FileManager.default
        try? fm.createDirectory(at: directory, withIntermediateDirectories: true)
        guard fm.fileExists(atPath: fileURL.path) else { return }
        do {
            let data = try Data(contentsOf: fileURL)
            let file = try MemoryCoding.decoder.decode(FileContents.self, from: data)
            items = file.items.sorted { $0.createdAt > $1.createdAt }
            profile = file.profile
            lenses = file.lenses
            lensesChosen = file.lensesChosen
            rebuildRefs()
        } catch {
            let aside = directory.appendingPathComponent("memory.unreadable-\(Int(Date().timeIntervalSince1970)).json")
            try? fm.moveItem(at: fileURL, to: aside)
            loadProblem = "Your memory file couldn't be read, so Docket started a new one. The old file was kept as \(aside.lastPathComponent)."
        }
    }

    /// The vectors, read from vectors.bin the first time they're needed.
    public var vectors: VectorIndex {
        if let loadedVectors { return loadedVectors }
        var index = VectorIndex()
        if let data = try? Data(contentsOf: vectorsURL), let read = try? VectorIndex(data: data) {
            index = read
            // Drop rows for items that are gone (deleted while the file was stale).
            index.retain { item($0) != nil }
        }
        loadedVectors = index
        return index
    }

    /// Writes pending changes now (synchronously, waiting for any write in flight).
    public func flush() {
        saveTask?.cancel()
        saveTask = nil
        write(synchronously: true)
    }

    private func scheduleSave() {
        guard saveTask == nil else { return }
        let delay = saveDelay
        saveTask = Task { [weak self] in
            if delay > 0 { try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000)) }
            guard !Task.isCancelled, let self else { return }
            self.saveTask = nil
            self.write(synchronously: false)
        }
    }

    private func write(synchronously: Bool) {
        guard itemsDirty || vectorsDirty else { return }
        let contents = itemsDirty ? FileContents(items: items, profile: profile, lenses: lenses, lensesChosen: lensesChosen) : nil
        let vectorIndex = vectorsDirty ? loadedVectors : nil
        itemsDirty = false
        vectorsDirty = false
        let directory = directory, fileURL = fileURL, vectorsURL = vectorsURL
        let job: @Sendable () -> String? = {
            do {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                if let contents { try MemoryCoding.encoder.encode(contents).write(to: fileURL, options: .atomic) }
                if let vectorIndex { try vectorIndex.encoded().write(to: vectorsURL, options: .atomic) }
                return nil
            } catch {
                return "Docket couldn't save your memory: \(error.localizedDescription)"
            }
        }
        if synchronously {
            saveProblem = io.sync(execute: job)
        } else {
            io.async { [weak self] in
                let problem = job()
                Task { @MainActor in self?.saveProblem = problem }
            }
        }
    }

    private var batchDepth = 0
    private var batchedChange = false

    /// Runs several changes with one change notification at the end (imports, bulk edits).
    public func batch(_ body: () throws -> Void) rethrows {
        batchDepth += 1
        defer {
            batchDepth -= 1
            if batchDepth == 0 && batchedChange {
                batchedChange = false
                notify()
            }
        }
        try body()
    }

    /// Call after every mutation.
    private func changed(items itemsChanged: Bool = true, vectors vectorsChanged: Bool = false) {
        if itemsChanged { itemsDirty = true }
        if vectorsChanged { vectorsDirty = true }
        revision &+= 1
        if batchDepth > 0 {
            batchedChange = true
            return
        }
        notify()
    }

    private func notify() {
        objectWillChange.send()
        scheduleSave()
        changes.send()
    }

    // MARK: Lookup

    public func item(_ id: UUID) -> MemoryItem? {
        position(of: id).map { items[$0] }
    }

    public func item(sourceRef: String) -> MemoryItem? {
        refs[sourceRef].flatMap(item)
    }

    public var count: Int { items.count }

    private func position(of id: UUID) -> Int? {
        if !positionsValid {
            positions.removeAll(keepingCapacity: true)
            for (i, item) in items.enumerated() { positions[item.id] = i }
            positionsValid = true
        }
        return positions[id]
    }

    private func rebuildRefs() {
        refs.removeAll(keepingCapacity: true)
        for item in items { if let ref = item.sourceRef { refs[ref] = item.id } }
        positionsValid = false
    }

    /// The index where an item created at `date` belongs (newest first).
    private func insertionIndex(for date: Date) -> Int {
        var low = 0, high = items.count
        while low < high {
            let mid = (low + high) / 2
            if items[mid].createdAt > date { low = mid + 1 } else { high = mid }
        }
        return low
    }

    // MARK: Adding and changing

    /// Adds an item (a new id if one with this id exists). If its `sourceRef` is already in the
    /// library, updates that item instead (see `upsert`). Returns what's stored.
    @discardableResult
    public func add(_ item: MemoryItem) -> MemoryItem {
        if let ref = item.sourceRef, refs[ref] != nil { return upsert(item) }
        var new = item
        if position(of: new.id) != nil { new.id = UUID() }
        new.title = new.title.trimmingCharacters(in: .whitespacesAndNewlines)
        new.tags = TextFold.uniqueNames(new.tags.map { $0.lowercased() })
        items.insert(new, at: insertionIndex(for: new.createdAt))
        if let ref = new.sourceRef { refs[ref] = new.id }
        positionsValid = false
        changed()
        return new
    }

    /// Adds the item, or, when an item with the same `sourceRef` exists, updates that one with the new
    /// content while keeping its id, pinned state, attachments, moments' done marks and creation date.
    /// Changed content (title, body or URL) sends it back to processing. Items without a sourceRef are added.
    @discardableResult
    public func upsert(_ item: MemoryItem) -> MemoryItem {
        guard let ref = item.sourceRef, let existingID = refs[ref], let existing = self.item(existingID) else {
            return add(item)
        }
        var merged = existing
        let contentChanged = existing.body != item.body
            || (item.url != nil && existing.url != item.url)
            || (!item.title.isEmpty && existing.title != item.title)
        merged.kind = item.kind
        if !item.title.isEmpty { merged.title = item.title }
        merged.body = item.body
        merged.url = item.url ?? existing.url
        if merged.url != existing.url { merged.extractedText = "" }
        if !item.extractedText.isEmpty { merged.extractedText = item.extractedText }
        merged.capturedFrom = item.capturedFrom ?? existing.capturedFrom
        merged.people = TextFold.uniqueNames(existing.people + item.people)
        merged.tags = TextFold.uniqueNames((existing.tags + item.tags).map { $0.lowercased() })
        merged.attachments = existing.attachments + item.attachments.filter { a in !existing.attachments.contains { $0.id == a.id } }
        merged.lightweight = item.lightweight
        if contentChanged {
            merged.processing = .pending
            merged.attempts = 0
        }
        merged.updatedAt = Date()
        replace(merged)
        if contentChanged { removeVector(for: merged.id) }
        return merged
    }

    /// Replaces the stored item with the same id. Ignored when it isn't in the library.
    public func update(_ item: MemoryItem) {
        guard let i = position(of: item.id) else { return }
        var new = item
        new.updatedAt = Date()
        if items[i].sourceRef != new.sourceRef {
            if let old = items[i].sourceRef { refs[old] = nil }
            if let ref = new.sourceRef { refs[ref] = new.id }
        }
        replace(new, at: i)
    }

    /// Changes an item in place. Returns the result, or nil when it isn't in the library.
    @discardableResult
    public func update(_ id: UUID, _ change: (inout MemoryItem) -> Void) -> MemoryItem? {
        guard var item = item(id) else { return nil }
        change(&item)
        update(item)
        return self.item(id)
    }

    /// Changes several items with one save and one change notification.
    public func update(_ ids: [UUID], _ change: (inout MemoryItem) -> Void) {
        var touched = false, needsSort = false
        let now = Date()
        for id in ids {
            guard let i = position(of: id) else { continue }
            var item = items[i]
            change(&item)
            guard item != items[i] else { continue }
            item.updatedAt = now
            if items[i].createdAt != item.createdAt { needsSort = true }
            items[i] = item
            touched = true
        }
        guard touched else { return }
        if needsSort {
            items.sort { $0.createdAt > $1.createdAt }
            positionsValid = false
        }
        changed()
    }

    private func replace(_ item: MemoryItem, at known: Int? = nil) {
        guard let i = known ?? position(of: item.id) else { return }
        if items[i].createdAt == item.createdAt {
            items[i] = item
        } else {
            items.remove(at: i)
            items.insert(item, at: insertionIndex(for: item.createdAt))
            positionsValid = false
        }
        changed()
    }

    /// Removes items, their vectors and their files.
    public func remove(_ ids: Set<UUID>) {
        guard !ids.isEmpty else { return }
        let before = items.count
        for id in ids { if let ref = item(id)?.sourceRef { refs[ref] = nil } }
        items.removeAll { ids.contains($0.id) }
        guard items.count != before else { return }
        positionsValid = false
        var vectorsChanged = false
        if loadedVectors != nil || FileManager.default.fileExists(atPath: vectorsURL.path) {
            var index = vectors
            for id in ids where index.contains(id) { index.remove(id); vectorsChanged = true }
            loadedVectors = index
        }
        for id in ids {
            searchEntries[id] = nil
            try? FileManager.default.removeItem(at: filesURL.appendingPathComponent(id.uuidString, isDirectory: true))
        }
        changed(vectors: vectorsChanged)
    }

    public func remove(_ id: UUID) { remove([id]) }

    public func setPinned(_ id: UUID, _ pinned: Bool) {
        update(id) { $0.pinned = pinned }
    }

    /// Records that the user opened the item (feeds "worth revisiting"). Doesn't touch `updatedAt`.
    public func markViewed(_ id: UUID, at date: Date = Date()) {
        guard let i = position(of: id) else { return }
        items[i].lastViewedAt = date
        changed()
    }

    /// Ticks a promise (or any moment) done or not.
    public func setMomentDone(_ momentID: UUID, in itemID: UUID, _ done: Bool) {
        update(itemID) { item in
            if let m = item.moments.firstIndex(where: { $0.id == momentID }) { item.moments[m].done = done }
        }
    }

    // MARK: Capture conveniences

    /// A note (or other text) the user wrote. With a sourceRef it updates the earlier capture of the same thing.
    @discardableResult
    public func addNote(_ text: String, title: String = "", kind: MemoryKind = .note, origin: MemoryOrigin = .manual,
                        sourceRef: String? = nil, capturedFrom: String? = nil, createdAt: Date = Date()) -> MemoryItem {
        add(MemoryItem(kind: kind, origin: origin, sourceRef: sourceRef, title: title, body: text,
                       capturedFrom: capturedFrom, createdAt: createdAt))
    }

    /// A web page. Saving the same page twice updates the first one (same normalized URL).
    @discardableResult
    public func addLink(_ address: String, note: String = "", title: String = "", origin: MemoryOrigin = .manual,
                        capturedFrom: String? = nil, createdAt: Date = Date()) -> MemoryItem {
        let url = address.trimmingCharacters(in: .whitespacesAndNewlines)
        if let ref = SourceRef.url(url), let existing = item(sourceRef: ref) {
            // Keep what was fetched; just add the new note, if any.
            if !note.isEmpty, !existing.body.contains(note) {
                return update(existing.id) { $0.body = note + ($0.body.isEmpty ? "" : "\n\n" + $0.body) } ?? existing
            }
            return existing
        }
        return add(MemoryItem(kind: .link, origin: origin, sourceRef: SourceRef.url(url), title: title, body: note,
                              url: url, capturedFrom: capturedFrom, createdAt: createdAt))
    }

    /// A file: copied (or moved) into the library. `kind` defaults to the one for its extension; `name`
    /// (shown to the user) defaults to the file's name. Throws when it can't be read.
    @discardableResult
    public func addFile(at source: URL, kind: MemoryKind? = nil, name: String? = nil, title: String = "", note: String = "",
                        origin: MemoryOrigin = .manual, sourceRef: String? = nil, capturedFrom: String? = nil,
                        createdAt: Date = Date(), move: Bool = false) throws -> MemoryItem {
        let shownName = name ?? source.lastPathComponent
        let kind = kind ?? MemoryKind.forFile(extension: (shownName as NSString).pathExtension)
        let id = UUID()
        let attachment = try copyIn(source, itemID: id, name: shownName, move: move)
        // Documents keep their file name as a title; AI names photos, recordings and videos.
        let fileTitle = title.isEmpty && (kind == .file || kind == .pdf) ? (shownName as NSString).deletingPathExtension : title
        return add(MemoryItem(id: id, kind: kind, origin: origin, sourceRef: sourceRef, title: fileTitle, body: note,
                              capturedFrom: capturedFrom, attachments: [attachment], createdAt: createdAt))
    }

    // MARK: Files

    /// Where an attachment's bytes are.
    public nonisolated func fileURL(for attachment: MemoryAttachment, of itemID: UUID) -> URL {
        filesURL.appendingPathComponent(itemID.uuidString, isDirectory: true).appendingPathComponent(attachment.fileName)
    }

    /// Copies (or moves) a file into the item's folder and lists it on the item.
    @discardableResult
    public func attachFile(at source: URL, to itemID: UUID, name: String? = nil, move: Bool = false) throws -> MemoryAttachment {
        guard item(itemID) != nil else { throw CocoaError(.fileNoSuchFile) }
        let attachment = try copyIn(source, itemID: itemID, name: name ?? source.lastPathComponent, move: move)
        update(itemID) { $0.attachments.append(attachment) }
        return attachment
    }

    /// Writes bytes as a file in the item's folder and lists it on the item.
    @discardableResult
    public func attachData(_ data: Data, name: String, to itemID: UUID) throws -> MemoryAttachment {
        guard item(itemID) != nil else { throw CocoaError(.fileNoSuchFile) }
        let folder = try itemFolder(itemID)
        let fileName = uniqueName(PhoneBridge.safeFileName(name), in: folder)
        try data.write(to: folder.appendingPathComponent(fileName), options: .atomic)
        let attachment = MemoryAttachment(name: name, fileName: fileName,
                                          mimeType: MimeType.forExtension((name as NSString).pathExtension), byteCount: data.count)
        update(itemID) { $0.attachments.append(attachment) }
        return attachment
    }

    /// Removes an attachment and its file.
    public func removeAttachment(_ attachmentID: UUID, from itemID: UUID) {
        guard let item = item(itemID), let attachment = item.attachments.first(where: { $0.id == attachmentID }) else { return }
        try? FileManager.default.removeItem(at: fileURL(for: attachment, of: itemID))
        update(itemID) { $0.attachments.removeAll { $0.id == attachmentID } }
    }

    private func itemFolder(_ itemID: UUID) throws -> URL {
        let folder = filesURL.appendingPathComponent(itemID.uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    private func copyIn(_ source: URL, itemID: UUID, name: String, move: Bool) throws -> MemoryAttachment {
        let folder = try itemFolder(itemID)
        let fileName = uniqueName(PhoneBridge.safeFileName(name), in: folder)
        let target = folder.appendingPathComponent(fileName)
        if move { try FileManager.default.moveItem(at: source, to: target) }
        else { try FileManager.default.copyItem(at: source, to: target) }
        let attributes = try? FileManager.default.attributesOfItem(atPath: target.path)
        let size = (attributes?[.size] as? NSNumber)?.intValue ?? 0
        let ext = (name as NSString).pathExtension.isEmpty ? source.pathExtension : (name as NSString).pathExtension
        return MemoryAttachment(name: name, fileName: fileName, mimeType: MimeType.forExtension(ext), byteCount: size)
    }

    private nonisolated func uniqueName(_ name: String, in folder: URL) -> String {
        let fm = FileManager.default
        guard fm.fileExists(atPath: folder.appendingPathComponent(name).path) else { return name }
        let base = (name as NSString).deletingPathExtension, ext = (name as NSString).pathExtension
        for n in 2... {
            let candidate = ext.isEmpty ? "\(base) \(n)" : "\(base) \(n).\(ext)"
            if !fm.fileExists(atPath: folder.appendingPathComponent(candidate).path) { return candidate }
        }
        return name
    }

    // MARK: Vectors

    public func vector(for id: UUID) -> [Float]? { vectors.vector(for: id) }

    /// Stores an item's vector. A vector from another model or size starts the index over (the
    /// processor then re-embeds the rest).
    public func setVector(_ vector: [Float], for id: UUID, model: String) {
        guard item(id) != nil else { return }
        var index = vectors
        index.set(vector, for: id, model: model)
        loadedVectors = index
        changed(items: false, vectors: true)
    }

    public func removeVector(for id: UUID) {
        var index = vectors
        guard index.contains(id) else { return }
        index.remove(id)
        loadedVectors = index
        changed(items: false, vectors: true)
    }

    /// Drops every vector (e.g. "Rebuild index", or a new embedding model).
    public func removeAllVectors() {
        loadedVectors = VectorIndex()
        queryVectors.removeAll()
        changed(items: false, vectors: true)
    }

    // MARK: Lists and filters

    /// Items passing `filter`, newest first, or best match first when `filter.text` isn't empty
    /// (text-only ranking; use `search` for meaning).
    public func items(matching filter: MemoryFilter) -> [MemoryItem] {
        let text = filter.text.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty { return items.filter(filter.matches) }
        return searchEngine().search(text, filter: filter, limit: items.count).map(\.item)
    }

    /// Everyone mentioned, most mentioned first.
    public func people() -> [MemoryEntity] { directories().people }
    /// Every project, most mentioned first.
    public func projects() -> [MemoryEntity] { directories().projects }
    /// Topics and tags together, most used first.
    public func topics() -> [MemoryEntity] { directories().topics }

    private func directories() -> (people: [MemoryEntity], projects: [MemoryEntity], topics: [MemoryEntity]) {
        if let cache = directoryCache, cache.revision == revision { return (cache.people, cache.projects, cache.topics) }
        let people = MemoryEntity.collect(items, \.people)
        let projects = MemoryEntity.collect(items, \.projects)
        let topics = MemoryEntity.collect(items) { $0.topics + $0.tags }
        directoryCache = (revision, people, projects, topics)
        return (people, projects, topics)
    }

    /// Moments across the library, newest item first (open promises: soonest due first).
    public func moments(_ kind: MomentKind? = nil, openOnly: Bool = false) -> [MomentRef] {
        var out: [MomentRef] = []
        for item in items {
            for m in item.moments where (kind == nil || m.kind == kind) && (!openOnly || !m.done) {
                out.append(MomentRef(moment: m, itemID: item.id, itemTitle: item.displayTitle, itemDate: item.createdAt))
            }
        }
        if kind == .promise && openOnly {
            out.sort { ($0.moment.due ?? .distantFuture, $1.itemDate) < ($1.moment.due ?? .distantFuture, $0.itemDate) }
        }
        return out
    }

    /// Items not yet processed by AI (pending), oldest first.
    public var pendingItems: [MemoryItem] { items.reversed().filter { $0.processing == .pending } }

    // MARK: Profile

    @discardableResult
    public func addFact(_ text: String, category: ProfileFact.Category = .other, pinned: Bool = false) -> ProfileFact? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let fact = ProfileFact(text: trimmed, category: category, pinned: pinned, source: .user)
        profile.facts.append(fact)
        changed()
        return fact
    }

    /// Saves an edited fact. Editing an AI fact's text makes it the user's (AI won't replace it).
    public func updateFact(_ fact: ProfileFact) {
        guard let i = profile.facts.firstIndex(where: { $0.id == fact.id }) else { return }
        var new = fact
        new.text = new.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !new.text.isEmpty else { return removeFact(fact.id) }
        if new.text != profile.facts[i].text { new.source = .user }
        new.updatedAt = Date()
        profile.facts[i] = new
        changed()
    }

    public func removeFact(_ id: UUID) {
        profile.facts.removeAll { $0.id == id }
        changed()
    }

    public func setFactPinned(_ id: UUID, _ pinned: Bool) {
        guard let i = profile.facts.firstIndex(where: { $0.id == id }) else { return }
        profile.facts[i].pinned = pinned
        changed()
    }

    /// Replaces the profile wholesale (used by `ProfileSynthesizer`, which keeps pinned and user facts).
    public func setProfile(_ profile: MemoryProfile) {
        self.profile = profile
        changed()
    }

    // MARK: Lenses

    /// Saves the user's lens choice (primary first). Choosing none still finishes onboarding.
    public func setLenses(_ lenses: [Lens]) {
        var unique: [Lens] = []
        for lens in lenses where !unique.contains(lens) { unique.append(lens) }
        self.lenses = unique
        lensesChosen = true
        changed()
    }

    /// What things are called for the chosen lenses.
    public var vocabulary: LensVocabulary { Lens.vocabulary(for: lenses) }

    // MARK: Search

    /// A searchable copy of the library (cached until the next change). Safe to use off the main actor.
    public func searchEngine(options: MemorySearch.Options = MemorySearch.Options()) -> MemorySearch {
        if let cachedSearch, cachedSearch.revision == revision, cachedSearch.search.options == options { return cachedSearch.search }
        var entries: [MemorySearch.Entry] = []
        entries.reserveCapacity(items.count)
        for item in items {
            if let cached = searchEntries[item.id], cached.updatedAt == item.updatedAt, cached.entry.item == item {
                entries.append(cached.entry)
            } else {
                let entry = MemorySearch.Entry(item)
                searchEntries[item.id] = (item.updatedAt, entry)
                entries.append(entry)
            }
        }
        let search = MemorySearch(entries: entries, vectors: vectors, options: options)
        cachedSearch = (revision, search)
        return search
    }

    /// The query's vector, or nil with no AI, no stored vectors from that model, or no network.
    /// Remembers recent queries so typing doesn't embed the same text twice.
    public func queryVector(_ text: String, ai: MemoryAI?) async -> [Float]? {
        guard let ai, vectors.isCompatible(model: ai.embeddingModel, dimensions: ai.embeddingDimensions) else { return nil }
        let key = ai.embeddingModel + "\n" + text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let cached = queryVectors[key] { return cached }
        guard let vector = try? await ai.embed([text], task: .query).first else { return nil }
        if queryVectors.count > 64 { queryVectors.removeAll() }
        queryVectors[key] = vector
        return vector
    }

    /// Hybrid search: by meaning when `ai` is given and vectors exist, always by text.
    public func search(_ query: String, ai: MemoryAI? = nil, filter: MemoryFilter = MemoryFilter(), limit: Int = 20) async -> [MemoryHit] {
        let vector = await queryVector(query, ai: ai)
        let engine = searchEngine()
        let model = ai?.embeddingModel
        return await Task.detached(priority: .userInitiated) {
            engine.search(query, queryVector: vector, model: model, filter: filter, limit: limit)
        }.value
    }

    /// "From memory": a few items related to a piece of text (a task's title and notes, a thread).
    public func related(to text: String, ai: MemoryAI? = nil, excluding: Set<UUID> = [], limit: Int = 3) async -> [MemoryHit] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        var vector: [Float]?
        if let ai, vectors.isCompatible(model: ai.embeddingModel, dimensions: ai.embeddingDimensions) {
            vector = try? await ai.embed([trimmed], task: .document).first
        }
        let engine = searchEngine()
        let model = ai?.embeddingModel
        return await Task.detached(priority: .userInitiated) {
            engine.related(to: trimmed, vector: vector, model: model, excluding: excluding, limit: limit)
        }.value
    }

    /// Items related to a stored item (by its vector, else by text).
    public func related(toItem id: UUID, limit: Int = 3) -> [MemoryHit] {
        searchEngine().related(toItem: id, limit: limit)
    }
}

// MARK: - Directory entries

/// A person, project or topic with how often it comes up.
public struct MemoryEntity: Identifiable, Hashable, Sendable {
    /// The most common spelling.
    public var name: String
    public var count: Int
    /// The newest item mentioning it.
    public var lastSeen: Date
    public var id: String { TextFold.fold(name) }

    static func collect(_ items: [MemoryItem], _ names: (MemoryItem) -> [String]) -> [MemoryEntity] {
        var groups: [String: (spellings: [String: Int], count: Int, last: Date)] = [:]
        for item in items {
            var seen = Set<String>()
            for raw in names(item) {
                let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                let key = TextFold.fold(name)
                guard !key.isEmpty, seen.insert(key).inserted else { continue }
                var g = groups[key] ?? ([:], 0, item.createdAt)
                g.spellings[name, default: 0] += 1
                g.count += 1
                g.last = max(g.last, item.createdAt)
                groups[key] = g
            }
        }
        return groups.values.map { g in
            let name = g.spellings.max { $0.value != $1.value ? $0.value < $1.value : $0.key > $1.key }!.key
            return MemoryEntity(name: name, count: g.count, lastSeen: g.last)
        }.sorted { $0.count != $1.count ? $0.count > $1.count : $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }
}

/// A moment with the item it belongs to.
public struct MomentRef: Identifiable, Hashable, Sendable {
    public var moment: Moment
    public var itemID: UUID
    public var itemTitle: String
    public var itemDate: Date
    public var id: UUID { moment.id }
}
