import Combine
import Foundation
import MemoryKit
import SwiftUI
import UIKit

/// The app's state: the Docket folder, the Mac's latest snapshot (and a search engine built from it),
/// captures waiting to sync, tasks completed here, and the Gemini key.
@MainActor
final class AppModel: ObservableObject {
    enum Tab: String, Hashable {
        case capture, memory, ask, today
    }

    /// Where the library from the Mac stands.
    enum LibraryState: Equatable {
        case noFolder
        case loading
        /// The folder is there but the Mac hasn't published yet.
        case waitingForMac
        /// The snapshot is in iCloud and on its way down.
        case downloading
        case ready
        case problem(String)
    }

    @Published var tab: Tab = .capture
    @Published var showSettings = false
    @Published var memoryPath: [MemoryRoute] = []
    /// Library, Topics or Map (remembered).
    @Published var memoryMode: MemoryMode = .library {
        didSet { if !isDemo { UserDefaults.standard.set(memoryMode.rawValue, forKey: "memory.mode") } }
    }
    @Published var toast: String?
    /// A button on the toast ("Undo").
    @Published private(set) var toastAction: ToastAction?

    @Published private(set) var bridgeRoot: URL?
    @Published private(set) var snapshot: LibrarySnapshot?
    @Published private(set) var search: MemorySearch?
    @Published private(set) var libraryState: LibraryState = .noFolder
    @Published private(set) var records: [CaptureRecord] = []
    /// Tasks completed on this phone, until a snapshot confirms them (task id → when).
    @Published private(set) var completed: [UUID: Date] = [:]
    /// Tasks deleted on this phone, hidden until a snapshot confirms them (task id → when).
    @Published private(set) var deleted: [UUID: Date] = [:]
    /// Tasks sent from this phone (composer, dictation, Siri) the Mac's list doesn't show yet.
    @Published private(set) var sentTasks: [SentTask] = []
    /// The task composer, when open (Capture shows it).
    @Published var composing: ComposerRequest?
    @Published private(set) var syncProblem: String?
    @Published private(set) var hasKey = false

    let isDemo: Bool
    let local: LocalStore
    let ask = AskSession()
    let voice: VoiceCenter
    let spoken: SpokenTaskCenter

    /// The running app's model, for App Intents that run inside the app.
    static weak var current: AppModel?

    struct ToastAction {
        var title: String
        var run: () -> Void
    }

    private var apiKey: String?
    private var snapshotModified: Date?
    private var loading = false
    private var flushing = false
    private var pollTimer: Timer?
    private var toastTask: Task<Void, Never>?
    private let environment: [String: String]
    private var pendingDeletes: [UUID: Task<Void, Never>] = [:]
    private var voiceChanges: AnyCancellable?
    private var spokenChanges: AnyCancellable?

    init(environment: [String: String] = ProcessInfo.processInfo.environment) {
        self.environment = environment
        isDemo = environment["DOCKET_PHONE_DEMO"] == "1"
        if isDemo {
            local = LocalStore(root: DemoSeed.baseURL.appendingPathComponent("Local", isDirectory: true))
        } else {
            let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            local = LocalStore(root: documents)
            apiKey = Keychain.readKey()
            hasKey = apiKey != nil
            if let picked = FolderBookmark.resolve() {
                bridgeRoot = FolderBookmark.bridgeRoot(in: picked)
                libraryState = .loading
            }
            records = local.loadRecords()
            completed = local.loadCompleted()
            deleted = local.loadDeleted()
            sentTasks = local.loadSentTasks()
        }
        voice = VoiceCenter(local: local, isDemo: isDemo)
        spoken = SpokenTaskCenter(local: local, isDemo: isDemo)
        if !isDemo, let saved = UserDefaults.standard.string(forKey: "memory.mode").flatMap(MemoryMode.init(rawValue:)) {
            memoryMode = saved
        }
        if let mode = environment["DOCKET_PHONE_TAB"].flatMap({ MemoryMode(rawValue: $0.lowercased()) }), mode != .library {
            tab = .memory
            memoryMode = mode
        }
        if let tab = environment["DOCKET_PHONE_TAB"].flatMap({ Tab(rawValue: $0.lowercased()) }) { self.tab = tab }
        if environment["DOCKET_PHONE_TAB"]?.lowercased() == "settings" { showSettings = true }
        if ["record", "debrief", "dictate", "dictated", "composer"].contains(environment["DOCKET_PHONE_TAB"]?.lowercased()) { tab = .capture }
        voice.model = self
        spoken.attach(self)
        Self.current = self
        // Debrief tasks show in Today, so the voice queue's changes are the model's too.
        voiceChanges = voice.objectWillChange.sink { [weak self] in self?.objectWillChange.send() }
        spokenChanges = spoken.objectWillChange.sink { [weak self] in self?.objectWillChange.send() }
    }

    /// Called once when the window appears.
    func start() async {
        if isDemo {
            let seeded = await DemoSeed.prepare(local: local)
            bridgeRoot = seeded.root
            records = seeded.records
            hasKey = true
            libraryState = .loading
        }
        await refresh(force: true)
        if isDemo { await applyDemoLaunchOptions() }
        startPolling()
        if !isDemo { await voice.resumeAfterLaunch() }
    }

    // MARK: Folder

    var folderName: String? {
        guard let bridgeRoot else { return nil }
        return isDemo ? "Docket (demo)" : bridgeRoot.lastPathComponent
    }

    /// The user picked a folder in Settings.
    func choose(folder url: URL) {
        do {
            try FolderBookmark.save(url)
        } catch {
            show("Couldn't keep access to that folder: \(error.localizedDescription)")
            return
        }
        guard let resolved = FolderBookmark.resolve() else { return }
        bridgeRoot = FolderBookmark.bridgeRoot(in: resolved)
        snapshot = nil
        search = nil
        snapshotModified = nil
        libraryState = .loading
        Task { await refresh(force: true) }
    }

    // MARK: Refresh

    private func startPolling() {
        pollTimer?.invalidate()
        pollTimer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.refresh() }
        }
    }

    /// Sends waiting captures, reloads the snapshot when it changed (always when `force`), and notes
    /// which captures the Mac has taken in.
    func refresh(force: Bool = false) async {
        await flushPending()
        await reloadLibrary(force: force)
        await updateReceived()
        voice.sweep()
        spoken.sweep()
        sweepSentTasks()
    }

    private func reloadLibrary(force: Bool) async {
        guard let root = bridgeRoot else {
            libraryState = .noFolder
            return
        }
        guard !loading else { return }
        loading = true
        defer { loading = false }
        let known = force ? nil : snapshotModified
        let outcome = await Task.detached(priority: .userInitiated) { LibraryLoader.load(root: root, knownModified: known) }.value
        guard root == bridgeRoot else { return }
        switch outcome {
        case .unchanged:
            break
        case .nothingYet:
            if snapshot == nil { libraryState = .waitingForMac }
        case .downloading:
            if snapshot == nil { libraryState = .downloading }
        case .failed(let message):
            libraryState = snapshot == nil ? .problem(message) : .ready
            if snapshot != nil { syncProblem = message }
        case .loaded(let loaded):
            snapshot = loaded.snapshot
            search = loaded.search
            // Vectors still downloading: read everything again on the next pass.
            snapshotModified = loaded.vectorsPending ? nil : loaded.modified
            libraryState = .ready
            syncProblem = nil
            confirmCompletedTasks(with: loaded.snapshot)
        }
    }

    // MARK: Captures

    var waitingCount: Int { records.filter { $0.state == .waiting }.count }

    /// Saves a capture: into Pending first (so nothing is lost), then on to the Docket folder. `quiet`
    /// skips the toast and haptic (the caller shows its own). Returns false when it couldn't be saved.
    @discardableResult
    func capture(_ envelope: CaptureEnvelope, attachment: CaptureAttachment? = nil, title: String, detail: String? = nil,
                 quiet: Bool = false) -> Bool {
        var env = envelope
        if env.device == nil { env.device = UIDevice.current.model }
        do {
            try local.stage(env, attachment: attachment)
        } catch {
            show("Couldn't save that: \(error.localizedDescription)")
            return false
        }
        noteRecord(CaptureRecord(id: env.id, kind: env.kind, title: title, detail: detail, createdAt: env.createdAt, state: .waiting))
        if !quiet { Haptics.success() }
        Task {
            await flushPending()
            guard !quiet else { return }
            if let state = records.first(where: { $0.id == env.id })?.state {
                show(state == .waiting ? (bridgeRoot == nil ? "Saved. It syncs once you choose your Docket folder." : "Saved. It syncs when the folder is reachable.") : "Saved")
            }
        }
        return true
    }

    /// Adds a line to Recent, or updates the one with the same id (a voice note gets its title later).
    private func noteRecord(_ record: CaptureRecord) {
        if let i = records.firstIndex(where: { $0.id == record.id }) {
            records[i].title = record.title
            records[i].detail = record.detail
            if records[i].state != .waiting || record.state != .waiting { records[i].state = record.state }
        } else {
            withAnimation(Motion.gentle) {
                records.insert(record, at: 0)
                if records.count > LocalStore.recentLimit { records.removeLast(records.count - LocalStore.recentLimit) }
            }
        }
        saveRecords()
    }

    /// A voice note in Recent while it's still on the phone.
    func noteVoice(_ id: UUID, title: String, detail: String?) {
        let existing = records.first { $0.id == id }
        noteRecord(CaptureRecord(id: id, kind: .voice, title: title, detail: detail,
                                 createdAt: existing?.createdAt ?? voice.job(id)?.recordedAt ?? Date(), state: existing?.state ?? .waiting))
    }

    private func flushPending() async {
        guard let root = bridgeRoot, !flushing else { return }
        flushing = true
        defer { flushing = false }
        let store = local
        let report = await Task.detached(priority: .userInitiated) { store.flush(to: root) }.value
        syncProblem = report.problem
        guard !report.sent.isEmpty else { return }
        let sent = Set(report.sent)
        for i in records.indices where sent.contains(records[i].id) { records[i].state = .synced }
        saveRecords()
    }

    private func updateReceived() async {
        guard let root = bridgeRoot, !isDemo else { return }
        let synced = records.filter { $0.state == .synced }.map(\.id)
        guard !synced.isEmpty else { return }
        let store = local
        let gone = Set(await Task.detached { store.received(synced, bridgeRoot: root) }.value)
        guard !gone.isEmpty else { return }
        for i in records.indices where gone.contains(records[i].id) { records[i].state = .received }
        saveRecords()
    }

    private func saveRecords() {
        guard !isDemo else { return }
        local.saveRecords(records)
    }

    // MARK: Tasks

    /// The Mac's open tasks plus tasks sent from here it doesn't list yet (debriefs, the composer, dictation,
    /// Siri; merged by id), minus ones deleted here.
    var openTasks: [TaskSnapshot] {
        let fromMac = snapshot?.tasks.filter { !$0.done } ?? []
        var known = Set((snapshot?.tasks ?? []).map(\.id))
        let fromVoice = voice.pendingTasks(excluding: known)
        known.formUnion(fromVoice.map(\.id))
        let sent = sentTasks.filter { !known.contains($0.id) }.map(\.task.asSnapshot)
        return (fromMac + fromVoice + sent).filter { deleted[$0.id] == nil }
    }

    /// A task sent from this phone (a debrief, the composer, dictation, Siri) the Mac hasn't listed yet.
    func isJustAdded(_ id: UUID) -> Bool {
        !(snapshot?.tasks.contains { $0.id == id } ?? false) && (voice.debriefTask(id) != nil || sentTask(id) != nil)
    }

    func sentTask(_ id: UUID) -> DebriefTask? { sentTasks.first { $0.id == id }?.task }

    /// Sends a new task with every field (a `.task` envelope whose id is the task's); it shows in Today at once.
    @discardableResult
    func addTask(_ task: DebriefTask, quiet: Bool = false) -> Bool {
        var task = task
        task.title = task.title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !task.title.isEmpty else { return false }
        guard capture(.task(task), title: task.title, detail: PhoneFmt.taskDetail(task), quiet: quiet) else { return false }
        sentTasks.removeAll { $0.id == task.id }
        sentTasks.insert(SentTask(task: task, sentAt: Date()), at: 0)
        saveSentTasks()
        return true
    }

    /// Takes back a task sent from here: straight out of Pending when it hasn't gone anywhere yet, else a
    /// taskDelete for the Mac.
    func takeBackTask(_ id: UUID) {
        let title = sentTask(id)?.title
        withAnimation(Motion.snappy) { sentTasks.removeAll { $0.id == id } }
        saveSentTasks()
        if !flushing, local.unstage(id) {
            forgetRecord(id)
        } else {
            sendTaskDelete(id, title: title)
        }
    }

    /// An edited task sent from here: the old one is taken back and the edit added. Keeps the id when the old
    /// one never left the phone; otherwise the edit gets a new one. Returns the task as sent.
    @discardableResult
    func replaceTask(_ task: DebriefTask) -> DebriefTask {
        var sent = task
        let unsent = !flushing && local.unstage(task.id)
        if unsent {
            forgetRecord(task.id)
        } else {
            sendTaskDelete(task.id, title: sentTask(task.id)?.title ?? task.title)
            sent.id = UUID()
        }
        sentTasks.removeAll { $0.id == task.id }
        addTask(sent, quiet: true)
        return sent
    }

    private func forgetRecord(_ id: UUID) {
        records.removeAll { $0.id == id }
        saveRecords()
    }

    private func saveSentTasks() {
        guard !isDemo else { return }
        local.saveSentTasks(sentTasks)
    }

    /// Forgets sent tasks the Mac lists now, or took in and published since, or that are three days old.
    private func sweepSentTasks(now: Date = Date()) {
        guard !sentTasks.isEmpty else { return }
        let before = sentTasks
        let known = Set((snapshot?.tasks ?? []).map(\.id))
        let received = Set(records.filter { $0.state == .received }.map(\.id))
        let generated = snapshot?.generatedAt ?? .distantPast
        for i in sentTasks.indices where sentTasks[i].receivedAt == nil && received.contains(sentTasks[i].id) {
            sentTasks[i].receivedAt = now
        }
        sentTasks.removeAll { sent in
            known.contains(sent.id) || (sent.receivedAt.map { generated > $0 } ?? false) || now.timeIntervalSince(sent.sentAt) > 3 * 24 * 3600
        }
        if sentTasks != before { saveSentTasks() }
    }

    func isCompletedHere(_ id: UUID) -> Bool { completed[id] != nil }

    /// Marks a task done here and tells the Mac (a taskDone envelope). It stays checked until a
    /// snapshot without it arrives.
    func complete(_ task: TaskSnapshot) {
        guard completed[task.id] == nil else { return }
        let now = Date()
        voice.commitNow(containing: task.id)
        withAnimation(Motion.snappy) { completed[task.id] = now }
        if !isDemo { local.saveCompleted(completed) }
        capture(CaptureEnvelope(kind: .taskDone, createdAt: now, title: task.title, taskID: task.id),
                title: task.title, detail: "Done", quiet: true)
        Haptics.success()
    }

    /// Unticks a task ticked here: a taskUndone envelope puts it back on the Mac.
    func uncomplete(_ task: TaskSnapshot) {
        guard completed[task.id] != nil else { return }
        withAnimation(Motion.snappy) { _ = completed.removeValue(forKey: task.id) }
        if !isDemo { local.saveCompleted(completed) }
        capture(CaptureEnvelope(kind: .taskUndone, title: task.title, taskID: task.id), title: task.title, detail: "Not done", quiet: true)
        Haptics.select()
    }

    /// Swipe to delete: hidden at once, with Undo on the toast for a few seconds; then the Mac is told
    /// (or, for a debrief task not yet written, it's simply dropped from the debrief).
    func deleteTask(_ task: TaskSnapshot) {
        let now = Date()
        withAnimation(Motion.snappy) { deleted[task.id] = now }
        Haptics.select()
        pendingDeletes[task.id]?.cancel()
        pendingDeletes[task.id] = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            guard !Task.isCancelled, let self else { return }
            self.pendingDeletes[task.id] = nil
            let onMac = self.snapshot?.tasks.contains { $0.id == task.id } ?? false
            if self.voice.debriefTask(task.id) != nil, !onMac {
                self.voice.removeTask(task.id)
            } else if self.sentTask(task.id) != nil, !onMac {
                self.takeBackTask(task.id)
            } else {
                self.sendTaskDelete(task.id, title: task.title)
            }
            if !self.isDemo { self.local.saveDeleted(self.deleted) }
        }
        show("Deleted “\(task.title)”", action: ToastAction(title: "Undo") { [weak self] in
            guard let self else { return }
            self.pendingDeletes[task.id]?.cancel()
            self.pendingDeletes[task.id] = nil
            withAnimation(Motion.snappy) { _ = self.deleted.removeValue(forKey: task.id) }
        })
    }

    /// Tells the Mac to delete a task.
    func sendTaskDelete(_ id: UUID, title: String?) {
        capture(CaptureEnvelope(kind: .taskDelete, title: title, taskID: id), title: title ?? "Task", detail: "Deleted", quiet: true)
    }

    /// A newer snapshot that no longer lists a task (or lists it done) confirms it; others stay
    /// pending for two days at most.
    private func confirmCompletedTasks(with snapshot: LibrarySnapshot) {
        let open = Set(snapshot.tasks.filter { !$0.done }.map(\.id))
        let cutoff = Date().addingTimeInterval(-2 * 24 * 3600)
        func confirm(_ map: [UUID: Date]) -> [UUID: Date] {
            map.filter { id, date in date > cutoff && (open.contains(id) || snapshot.generatedAt <= date) }
        }
        if !completed.isEmpty {
            let before = completed
            completed = confirm(completed)
            if completed != before, !isDemo { local.saveCompleted(completed) }
        }
        if !deleted.isEmpty {
            let before = deleted
            deleted = confirm(deleted).merging(deleted.filter { pendingDeletes[$0.key] != nil }) { a, _ in a }
            if deleted != before, !isDemo { local.saveDeleted(deleted) }
        }
    }

    // MARK: Library helpers

    var lenses: [Lens] { snapshot?.lenses ?? [] }
    var vocabulary: LensVocabulary { Lens.vocabulary(for: lenses) }

    func item(_ id: UUID) -> MemoryItem? { search?.item(id) ?? snapshot?.items.first { $0.id == id } }

    func thumbnailURL(for id: UUID) -> URL? {
        bridgeRoot.map { PhoneBridge(root: $0).thumbnailURL(for: id) }
    }

    /// "Last updated from your Mac: Fri 9 Oct · 17:20"
    var lastUpdatedLine: String? {
        snapshot.map { "Last updated from your Mac: \(PhoneFmt.dayTime($0.generatedAt))" }
    }

    // MARK: AI

    /// Gemini with the user's key, or nil without one (search still works, Ask explains).
    /// What the Mac's memory (this snapshot) knows that helps with some spoken words (`TaskContext`): names,
    /// dates, notes and who to chase, for Gemini to fill in. Nil without a snapshot or when it knows nothing.
    func taskContextBlock(for text: String) -> String? {
        guard let snapshot, let search else { return nil }
        let block = TaskContext.build(text: text, search: search, snapshot: snapshot).promptBlock()
        return block.isEmpty ? nil : block
    }

    func makeAI() -> MemoryAI? {
        if isDemo { return DemoAI() }
        guard let apiKey else { return nil }
        return GeminiMemoryAI(apiKey: apiKey)
    }

    func saveKey(_ key: String) -> Bool {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !isDemo else { return false }
        guard Keychain.saveKey(trimmed) else { return false }
        apiKey = trimmed
        hasKey = true
        return true
    }

    func removeKey() {
        guard !isDemo else { return }
        Keychain.deleteKey()
        apiKey = nil
        hasKey = false
    }

    // MARK: Toast

    func show(_ message: String, action: ToastAction? = nil) {
        toastTask?.cancel()
        withAnimation(Motion.snappy) {
            toast = message
            toastAction = action
        }
        toastTask = Task {
            try? await Task.sleep(nanoseconds: action == nil ? 2_400_000_000 : 5_000_000_000)
            guard !Task.isCancelled else { return }
            withAnimation(Motion.gentle) {
                toast = nil
                toastAction = nil
            }
        }
    }

    func dismissToast() {
        toastTask?.cancel()
        withAnimation(Motion.gentle) {
            toast = nil
            toastAction = nil
        }
    }

    // MARK: Demo

    /// `DOCKET_PHONE_MAP_FOCUS=<name>`: the map opens focused on that entity (demo only).
    var demoMapFocus: String? { isDemo ? environment["DOCKET_PHONE_MAP_FOCUS"] : nil }
    /// `DOCKET_PHONE_MAP_DAYS=<n>`: the map's time slider starts n days back (demo only).
    var demoMapDaysBack: Int? { isDemo ? environment["DOCKET_PHONE_MAP_DAYS"].flatMap(Int.init) : nil }
    /// `DOCKET_PHONE_SEARCH=<words>`: Memory's Library starts with that search (demo only).
    var demoSearch: String? { isDemo ? environment["DOCKET_PHONE_SEARCH"] : nil }
    /// `DOCKET_PHONE_MAP_ZOOM=<factor>`: the map opens zoomed in (demo only).
    var demoMapZoom: Double? { isDemo ? environment["DOCKET_PHONE_MAP_ZOOM"].flatMap(Double.init) : nil }
    /// `DOCKET_PHONE_MAP_TIMING=1`: logs each map draw's time (demo only).
    var demoMapTiming: Bool { isDemo && environment["DOCKET_PHONE_MAP_TIMING"] == "1" }
    /// `DOCKET_PHONE_MAP_SELECT=<name>`: that node's card is open (demo only).
    var demoMapSelect: String? { isDemo ? environment["DOCKET_PHONE_MAP_SELECT"] : nil }

    private func applyDemoLaunchOptions() async {
        switch environment["DOCKET_PHONE_TAB"]?.lowercased() {
        case "record":
            voice.recorder.showDemo(elapsed: 167, transcript: DemoSeed.recordingTranscript)
        case "debrief":
            voice.showDemoCard()
        case "today":
            voice.showDemoCard()
            voice.closeCard()
            spoken.showDemoResult()
            spoken.closeCard()
        case "dictate":
            spoken.showDemoListening()
        case "dictated":
            spoken.showDemoResult()
        case "composer":
            composing = ComposerRequest(draft: DemoSeed.composerDraft(now: Date()), expanded: true)
        default:
            break
        }
        if let which = environment["DOCKET_PHONE_ITEM"], let items = snapshot?.items, !items.isEmpty {
            let lowered = which.lowercased()
            let item: MemoryItem? = lowered == "first" ? items.first
                : Int(lowered).flatMap { items.indices.contains($0) ? items[$0] : nil }
                ?? items.first { $0.displayTitle.lowercased().contains(lowered) }
            if let item {
                tab = .memory
                memoryPath = [.item(item.id)]
            }
        }
        if let name = environment["DOCKET_PHONE_ENTITY"], let entity = demoEntity(name) {
            tab = .memory
            memoryPath = [.entity(entity.id)]
        }
        if tab == .ask, let search, let snapshot, let answer = await DemoSeed.answer(search: search, snapshot: snapshot) {
            ask.inject(answer)
        }
    }
}

// MARK: - Loading the library (off the main thread)

enum LibraryLoader {
    struct Loaded: Sendable {
        var snapshot: LibrarySnapshot
        var search: MemorySearch
        var modified: Date?
        var vectorsPending: Bool
    }

    enum Outcome: Sendable {
        case unchanged
        case nothingYet
        case downloading
        case failed(String)
        case loaded(Loaded)
    }

    /// Reads snapshot.json (when newer than `knownModified`) and vectors.bin, and builds the search
    /// engine. Missing, cloud-only and half-written files come back as states, not errors.
    static func load(root: URL, knownModified: Date?) -> Outcome {
        let bridge = PhoneBridge(root: root)
        let fm = FileManager.default
        var isDirectory: ObjCBool = false
        guard fm.fileExists(atPath: root.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            return .failed("Can't open the Docket folder. Choose it again in Settings.")
        }
        switch CloudFiles.prepare(bridge.snapshotURL) {
        case .missing: return .nothingYet
        case .downloading: return .downloading
        case .ready: break
        }
        let modified = CloudFiles.modified(bridge.snapshotURL)
        if let knownModified, let modified, modified <= knownModified { return .unchanged }
        let snapshot: LibrarySnapshot
        do {
            snapshot = try CloudFiles.read(bridge.snapshotURL) { url in
                try MemoryCoding.decoder.decode(LibrarySnapshot.self, from: Data(contentsOf: url))
            }
        } catch {
            // Usually a file iCloud is still writing: the next pass picks it up.
            return .failed("Couldn't read the latest update from your Mac yet. Trying again shortly.")
        }
        var vectors = VectorIndex()
        var vectorsPending = false
        switch CloudFiles.prepare(bridge.vectorsURL) {
        case .ready:
            if let read = try? CloudFiles.read(bridge.vectorsURL, { try VectorIndex(data: Data(contentsOf: $0)) }) {
                vectors = read
            } else {
                vectorsPending = !snapshot.embeddingModel.isEmpty
            }
        case .downloading:
            vectorsPending = true
        case .missing:
            vectorsPending = false
        }
        let search = MemorySearch(items: snapshot.items, vectors: vectors)
        return .loaded(Loaded(snapshot: snapshot, search: search, modified: modified, vectorsPending: vectorsPending))
    }
}
