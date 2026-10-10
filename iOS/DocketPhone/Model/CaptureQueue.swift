import Foundation
import MemoryKit

/// A capture as the phone remembers it for the "Recent" list.
struct CaptureRecord: Identifiable, Hashable, Codable {
    enum State: String, Codable {
        /// In the app's own Pending folder (no Docket folder yet, or writing failed).
        case waiting
        /// Written to the Docket folder's Inbox.
        case synced
        /// Gone from the Inbox: the Mac took it in.
        case received
    }

    /// The envelope's id.
    var id: UUID
    var kind: CaptureEnvelope.Kind
    var title: String
    /// Secondary text: a link's host, a recording's length, a task's due date.
    var detail: String?
    var createdAt: Date
    var state: State
}

/// A task this phone sent (composer, dictation, Siri), shown in Today as "Just added" until the Mac's task
/// list has it.
struct SentTask: Codable, Identifiable, Equatable {
    var task: DebriefTask
    var sentAt: Date
    /// When the phone saw the Mac take its envelope from the Inbox.
    var receivedAt: Date?

    var id: UUID { task.id }
}

extension CaptureEnvelope {
    /// A `.task` envelope carrying every field (its id is the task's), plus title/due for older Macs.
    static func task(_ task: DebriefTask) -> CaptureEnvelope {
        CaptureEnvelope(id: task.id, kind: .task, title: task.title, text: task.notes.isEmpty ? nil : task.notes,
                        due: task.dueDate, dueHasTime: task.dueDate != nil && task.dueHasTime, device: "iPhone", task: task)
    }
}

/// What a capture carries besides its envelope.
enum CaptureAttachment {
    /// A file on disk; `move` when it's ours to take (a finished recording).
    case file(URL, move: Bool)
    /// Bytes in memory (a picked photo).
    case data(Data, name: String)
}

/// The app's own folder: captures wait in `Pending/` (same file layout as the Inbox) until the
/// Docket folder is reachable; the recent list and locally completed tasks live next to it.
struct LocalStore: Sendable {
    let root: URL

    var pendingURL: URL { root.appendingPathComponent("Pending", isDirectory: true) }
    var recordsURL: URL { root.appendingPathComponent("captures.json") }
    var completedURL: URL { root.appendingPathComponent("completed-tasks.json") }
    var deletedURL: URL { root.appendingPathComponent("deleted-tasks.json") }
    var sentTasksURL: URL { root.appendingPathComponent("sent-tasks.json") }

    static let recentLimit = 30

    /// Puts a capture in Pending: attachment first, envelope last.
    func stage(_ envelope: CaptureEnvelope, attachment: CaptureAttachment?) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: pendingURL, withIntermediateDirectories: true)
        var env = envelope
        switch attachment {
        case .file(let url, let move)?:
            if env.attachmentName == nil { env.attachmentName = url.lastPathComponent }
            let target = pendingURL.appendingPathComponent(env.attachmentFileName!)
            try? fm.removeItem(at: target)
            if move { try fm.moveItem(at: url, to: target) } else { try fm.copyItem(at: url, to: target) }
        case .data(let data, let name)?:
            env.attachmentName = name
            try data.write(to: pendingURL.appendingPathComponent(env.attachmentFileName!), options: .atomic)
        case nil:
            break
        }
        try MemoryCoding.encoder.encode(env).write(to: pendingURL.appendingPathComponent(env.fileName), options: .atomic)
    }

    /// Takes a capture back out of Pending before it went anywhere (an attachment-less one). True when it was
    /// still there, so the Mac will never see it.
    func unstage(_ id: UUID) -> Bool {
        let url = pendingURL.appendingPathComponent("\(id.uuidString).capture.json")
        guard FileManager.default.fileExists(atPath: url.path) else { return false }
        return (try? FileManager.default.removeItem(at: url)) != nil
    }

    /// Envelopes waiting in Pending, oldest first.
    func pending() -> [(envelope: CaptureEnvelope, url: URL)] {
        let urls = (try? FileManager.default.contentsOfDirectory(at: pendingURL, includingPropertiesForKeys: nil)) ?? []
        return urls.filter { $0.lastPathComponent.hasSuffix(".capture.json") }
            .compactMap { url in
                guard let data = try? Data(contentsOf: url),
                      let env = try? MemoryCoding.decoder.decode(CaptureEnvelope.self, from: data) else { return nil }
                return (env, url)
            }
            .sorted { $0.envelope.createdAt < $1.envelope.createdAt }
    }

    struct FlushReport: Sendable {
        var sent: [UUID] = []
        var problem: String?
    }

    /// Moves every pending capture into `<bridgeRoot>/Inbox` (coordinated, via `PhoneBridge`). A
    /// capture that fails stays pending for the next try.
    func flush(to bridgeRoot: URL) -> FlushReport {
        var report = FlushReport()
        let fm = FileManager.default
        let bridge = PhoneBridge(root: bridgeRoot)
        for (env, envelopeURL) in pending() {
            var envelope = env
            var attachment: URL?
            if let name = env.attachmentFileName {
                let candidate = pendingURL.appendingPathComponent(name)
                if fm.fileExists(atPath: candidate.path) { attachment = candidate } else { envelope.attachmentName = nil }
            }
            do {
                try fm.createDirectory(at: bridge.inboxURL, withIntermediateDirectories: true)
                let envelopeTarget = bridge.inboxURL.appendingPathComponent(envelope.fileName)
                let attachmentTarget = envelope.attachmentFileName.map { bridge.inboxURL.appendingPathComponent($0) }
                try CloudFiles.write(envelopeTarget, attachmentTarget) {
                    try bridge.writeCapture(envelope, attachment: attachment)
                }
                try? fm.removeItem(at: envelopeURL)
                if let attachment { try? fm.removeItem(at: attachment) }
                report.sent.append(env.id)
            } catch {
                report.problem = "Couldn't write to the Docket folder: \(error.localizedDescription)"
                break
            }
        }
        return report
    }

    /// Which of these synced captures are no longer in the Inbox (the Mac took them in).
    func received(_ ids: [UUID], bridgeRoot: URL) -> [UUID] {
        let inbox = PhoneBridge(root: bridgeRoot).inboxURL
        let fm = FileManager.default
        guard fm.fileExists(atPath: inbox.path) else { return [] }
        return ids.filter { id in
            let name = "\(id.uuidString).capture.json"
            return !fm.fileExists(atPath: inbox.appendingPathComponent(name).path)
                && !fm.fileExists(atPath: inbox.appendingPathComponent(".\(name).icloud").path)
        }
    }

    // MARK: Small JSON files

    func loadRecords() -> [CaptureRecord] { load([CaptureRecord].self, from: recordsURL) ?? [] }
    func saveRecords(_ records: [CaptureRecord]) { save(records, to: recordsURL) }
    func loadCompleted() -> [UUID: Date] { load([UUID: Date].self, from: completedURL) ?? [:] }
    func saveCompleted(_ completed: [UUID: Date]) { save(completed, to: completedURL) }
    func loadDeleted() -> [UUID: Date] { load([UUID: Date].self, from: deletedURL) ?? [:] }
    func saveDeleted(_ deleted: [UUID: Date]) { save(deleted, to: deletedURL) }
    func loadSentTasks() -> [SentTask] { load([SentTask].self, from: sentTasksURL) ?? [] }
    func saveSentTasks(_ tasks: [SentTask]) { save(tasks, to: sentTasksURL) }

    private func load<T: Decodable>(_ type: T.Type, from url: URL) -> T? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? MemoryCoding.decoder.decode(type, from: data)
    }

    private func save<T: Encodable>(_ value: T, to url: URL) {
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try? MemoryCoding.encoder.encode(value).write(to: url, options: .atomic)
    }
}
