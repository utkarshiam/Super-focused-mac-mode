import ImageIO
import XCTest
@testable import MemoryKit

@MainActor
final class PhoneBridgeTests: XCTestCase {
    var dir: URL!
    var bridge: PhoneBridge!
    var library: MemoryLibrary!

    override func setUp() async throws {
        dir = makeTempDirectory()
        bridge = PhoneBridge(root: dir.appendingPathComponent("Docket", isDirectory: true))
        library = MemoryLibrary(directory: dir.appendingPathComponent("Memory", isDirectory: true), saveDelay: 60)
    }

    override func tearDown() async throws { try? FileManager.default.removeItem(at: dir) }

    /// Backdates a file so it counts as settled.
    private func age(_ url: URL, by seconds: TimeInterval) throws {
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-seconds)], ofItemAtPath: url.path)
    }

    private func ageInbox(by seconds: TimeInterval = 10) throws {
        for name in try FileManager.default.contentsOfDirectory(atPath: bridge.inboxURL.path) {
            try age(bridge.inboxURL.appendingPathComponent(name), by: seconds)
        }
    }

    func testNoteEnvelopeIsIngestedAndRemoved() throws {
        let env = CaptureEnvelope(kind: .note, createdAt: day(-1), title: "Idea", text: "A weekly digest email", device: "iPhone 17")
        let url = try bridge.writeCapture(env)
        XCTAssertEqual(url.lastPathComponent, "\(env.id.uuidString).capture.json")

        XCTAssertTrue(bridge.pendingEntries().isEmpty, "fresh files wait")
        try ageInbox()
        let report = bridge.ingest(into: library)
        XCTAssertEqual(report.itemIDs.count, 1)
        let item = try XCTUnwrap(library.item(report.itemIDs[0]))
        XCTAssertEqual(item.title, "Idea")
        XCTAssertEqual(item.body, "A weekly digest email")
        XCTAssertEqual(item.origin, .phone)
        XCTAssertEqual(item.capturedFrom, "iPhone 17")
        XCTAssertEqual(item.createdAt, day(-1))
        XCTAssertEqual(item.sourceRef, SourceRef.phone(env.id))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: bridge.inboxURL.path), [])
    }

    func testPhotoEnvelopeBringsItsAttachment() throws {
        let png = try XCTUnwrap(MemoryLibrary.debugImagePNG(width: 30, height: 20))
        let env = CaptureEnvelope(kind: .photo, createdAt: day(0), text: "Whiteboard")
        try bridge.writeCapture(env, attachmentData: png, name: "IMG_0042.png")
        XCTAssertTrue(FileManager.default.fileExists(atPath: bridge.inboxURL.appendingPathComponent("\(env.id.uuidString)--IMG_0042.png").path))
        try ageInbox()
        let report = bridge.ingest(into: library)
        let item = try XCTUnwrap(report.itemIDs.first.flatMap(library.item))
        XCTAssertEqual(item.kind, .image)
        XCTAssertEqual(item.body, "Whiteboard")
        let attachment = try XCTUnwrap(item.attachments.first)
        XCTAssertEqual(attachment.name, "IMG_0042.png")
        XCTAssertEqual(try Data(contentsOf: library.fileURL(for: attachment, of: item.id)), png)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: bridge.inboxURL.path), [])
    }

    func testLinkEnvelopeMergesWithAnExistingLink() throws {
        let existing = library.addLink("https://example.com/a")
        try bridge.writeCapture(CaptureEnvelope(kind: .link, text: "Again", url: "https://www.example.com/a/"))
        try ageInbox()
        let report = bridge.ingest(into: library)
        XCTAssertEqual(report.itemIDs, [existing.id])
        XCTAssertEqual(library.count, 1)
    }

    func testPlaceholdersFreshFilesAndWaitingPairsAreSkipped() throws {
        let fm = FileManager.default
        try fm.createDirectory(at: bridge.inboxURL, withIntermediateDirectories: true)
        // An iCloud placeholder, a hidden file, a fresh loose file.
        try Data().write(to: bridge.inboxURL.appendingPathComponent(".report.pdf.icloud"))
        try Data().write(to: bridge.inboxURL.appendingPathComponent(".DS_Store"))
        try Data("fresh".utf8).write(to: bridge.inboxURL.appendingPathComponent("fresh.txt"))
        // An envelope whose attachment hasn't arrived yet.
        let waiting = CaptureEnvelope(kind: .voice, attachmentName: "memo.m4a")
        try MemoryCoding.encoder.encode(waiting).write(to: bridge.inboxURL.appendingPathComponent(waiting.fileName))
        try age(bridge.inboxURL.appendingPathComponent(waiting.fileName), by: 30)
        // An attachment whose envelope hasn't arrived yet.
        let orphan = "\(UUID().uuidString)--photo.jpg"
        try Data("jpg".utf8).write(to: bridge.inboxURL.appendingPathComponent(orphan))
        try age(bridge.inboxURL.appendingPathComponent(orphan), by: 30)

        XCTAssertEqual(bridge.pendingEntries(), [])
        XCTAssertEqual(bridge.ingest(into: library).itemIDs, [])

        // Much later, both halves give up waiting.
        try age(bridge.inboxURL.appendingPathComponent(waiting.fileName), by: 3600)
        try age(bridge.inboxURL.appendingPathComponent(orphan), by: 3600)
        try age(bridge.inboxURL.appendingPathComponent("fresh.txt"), by: 3600)
        let report = bridge.ingest(into: library)
        XCTAssertEqual(report.itemIDs.count, 3)
        let kinds = Set(report.itemIDs.compactMap { library.item($0)?.kind })
        XCTAssertEqual(kinds, [.audio, .image, .file])
        XCTAssertTrue(library.items.contains { $0.attachments.first?.name == "photo.jpg" }, "the uuid prefix is dropped")
        XCTAssertTrue(library.items.contains { $0.title == "fresh" && $0.origin == .phone })
        let left = try fm.contentsOfDirectory(atPath: bridge.inboxURL.path).sorted()
        XCTAssertEqual(left, [".DS_Store", ".report.pdf.icloud"])
    }

    func testTaskEnvelopesGoToTheHandler() throws {
        let task = CaptureEnvelope(kind: .task, title: "Call Priya", due: day(1, hour: 0))
        let done = CaptureEnvelope(kind: .taskDone, taskID: UUID())
        try bridge.writeCapture(task)
        try bridge.writeCapture(done)
        try ageInbox()

        XCTAssertEqual(bridge.ingest(into: library).tasksHandled, 0, "no handler: left for later")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: bridge.inboxURL.path).count, 2)

        var seen: [CaptureEnvelope.Kind] = []
        let report = bridge.ingest(into: library) { env in seen.append(env.kind); return true }
        XCTAssertEqual(report.tasksHandled, 2)
        XCTAssertEqual(Set(seen), [.task, .taskDone])
        XCTAssertEqual(library.count, 0, "tasks aren't memories")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: bridge.inboxURL.path), [])
    }

    func testVoiceEnvelopesGoToTheVoiceHandlerWithTheirRecording() throws {
        let voice = CaptureEnvelope(kind: .voice, transcript: "Call Rohan")
        try bridge.writeCapture(voice, attachmentData: Data([1, 2, 3]), name: "Recording.m4a")
        try bridge.writeCapture(CaptureEnvelope(kind: .taskUndone, taskID: UUID()))
        try ageInbox()

        var attempts = 0
        var heard: URL?
        let waiting = bridge.ingest(into: library, handleTask: { _ in true }, handleVoice: { env, audio in
            attempts += 1
            heard = audio
            XCTAssertEqual(env.transcript, "Call Rohan")
            return false
        })
        XCTAssertEqual(waiting.voiceHandled, 0)
        XCTAssertEqual(waiting.tasksHandled, 1, "taskUndone is a task envelope")
        XCTAssertEqual(heard?.lastPathComponent, "\(voice.id.uuidString)--Recording.m4a")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: bridge.inboxURL.path).count, 2, "false: both files stay")
        XCTAssertEqual(library.count, 0)

        let done = bridge.ingest(into: library, handleVoice: { _, _ in attempts += 1; return true })
        XCTAssertEqual(done.voiceHandled, 1)
        XCTAssertEqual(attempts, 2)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: bridge.inboxURL.path), [])
        XCTAssertEqual(library.count, 0, "the handler makes the memory, not the bridge")
    }

    func testSnapshotCarriesListNames() throws {
        let snapshot = PhoneBridge.makeSnapshot(library, tasks: [], listNames: ["Sales", "Hiring"])
        XCTAssertEqual(try roundTrip(snapshot).listNames, ["Sales", "Hiring"])
        XCTAssertEqual(PhoneBridge.makeSnapshot(library, tasks: []).listNames, [])
    }

    func testReingestingTheSameCaptureDoesNotDuplicate() throws {
        let env = CaptureEnvelope(kind: .note, text: "Once")
        try bridge.writeCapture(env)
        try ageInbox()
        bridge.ingest(into: library)
        try bridge.writeCapture(env)
        try ageInbox()
        bridge.ingest(into: library)
        XCTAssertEqual(library.count, 1)
    }

    func testSnapshotRoundTripWithVectorsAndThumbnails() async throws {
        library.setLenses([.artist])
        library.addFact("Painter", category: .role, pinned: true)
        let long = library.addNote(String(repeating: "word ", count: 2000), title: "Long")
        let photo = dir.appendingPathComponent("p.png")
        try XCTUnwrap(MemoryLibrary.debugImagePNG(width: 800, height: 600)).write(to: photo)
        let image = try library.addFile(at: photo)
        library.setVector([1, 2, 3], for: long.id, model: "m")
        let tasks = [TaskSnapshot(id: UUID(), title: "Ship prints", dueDate: day(0), priority: 2)]

        try await bridge.publish(library, tasks: tasks, now: day(0))
        let snapshot = try XCTUnwrap(try bridge.readSnapshot())
        XCTAssertEqual(snapshot.items.count, 2)
        XCTAssertLessThanOrEqual(snapshot.items.first { $0.id == long.id }!.body.count, PhoneBridge.snapshotTextLimit + 1)
        XCTAssertEqual(snapshot.lenses, [.artist])
        XCTAssertEqual(snapshot.profile.facts.first?.text, "Painter")
        XCTAssertEqual(snapshot.tasks, tasks)
        XCTAssertEqual(snapshot.embeddingModel, "m")
        XCTAssertEqual(snapshot.generatedAt, day(0))

        let vectors = try XCTUnwrap(bridge.readVectors())
        XCTAssertEqual(vectors, library.vectors)

        let thumb = bridge.thumbnailURL(for: image.id)
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(thumb as CFURL, nil))
        let props = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
        XCTAssertEqual(props[kCGImagePropertyPixelWidth] as? Int, 400)
        XCTAssertEqual(props[kCGImagePropertyPixelHeight] as? Int, 300)

        // Unchanged vectors aren't rewritten; removed items lose their thumbnail.
        let before = try FileManager.default.attributesOfItem(atPath: bridge.vectorsURL.path)[.modificationDate] as? Date
        library.remove(image.id)
        try await Task.sleep(nanoseconds: 50_000_000)
        try await bridge.publish(library, tasks: [], now: day(0))
        let after = try FileManager.default.attributesOfItem(atPath: bridge.vectorsURL.path)[.modificationDate] as? Date
        XCTAssertEqual(before, after)
        XCTAssertFalse(FileManager.default.fileExists(atPath: thumb.path))
        XCTAssertEqual(try bridge.readSnapshot()?.items.count, 1)
    }

    func testNoSnapshotYet() throws {
        XCTAssertNil(try bridge.readSnapshot())
        XCTAssertNil(bridge.readVectors())
    }

    func testSafeFileNames() {
        XCTAssertEqual(PhoneBridge.safeFileName("a/b:c.txt"), "a-b-c.txt")
        XCTAssertEqual(PhoneBridge.safeFileName("..hidden"), "hidden")
        XCTAssertEqual(PhoneBridge.safeFileName(""), "file")
        XCTAssertEqual(PhoneBridge.safeFileName(String(repeating: "x", count: 300) + ".pdf").count, 114)
    }
}
