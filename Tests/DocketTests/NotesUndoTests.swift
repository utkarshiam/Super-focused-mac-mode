import AppKit
import XCTest
@testable import Docket

/// Note changes made outside the Markdown editor (Read-mode checkboxes, paste and drop, Insert Template)
/// are store undo steps on the window's undo manager. These make the same store calls the note pane does.
@MainActor
final class NotesUndoTests: XCTestCase {
    var dir: URL!
    var undo: UndoManager!

    override func setUp() async throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("docket-notes-undo-\(UUID().uuidString)")
        undo = UndoManager()
        undo.groupsByEvent = false
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private func makeStore() -> Store {
        let store = Store(persistence: Persistence(directory: dir), seedIfEmpty: false)
        store.undoManager = undo
        return store
    }

    /// One user action: the window's undo manager groups by event.
    private func step<T>(_ body: () -> T) -> T {
        undo.beginUndoGrouping()
        defer { undo.endUndoGrouping() }
        return body()
    }

    func testReadModeEditsUndoOneAtATimeAndRedo() {
        let store = makeStore()
        let id = step { store.addNote(body: "").id }
        // "Paste from clipboard" on the empty note, then a checkbox click in Read mode.
        let pasted = "# Errands\n- [ ] Buy milk\n- [ ] Post letter"
        step { store.undoable("Paste") { store.updateNoteBody(id, pasted) } }
        let ticked = NoteChecklist.toggle(lineAt: 1, in: pasted)!
        step { store.undoable("Tick Checkbox") { store.updateNoteBody(id, ticked) } }
        XCTAssertEqual(undo.undoActionName, "Tick Checkbox")

        undo.undo()
        XCTAssertEqual(store.note(id)?.body, pasted, "only the tick is undone")
        undo.undo()
        XCTAssertEqual(store.note(id)?.body, "")
        undo.undo()
        XCTAssertNil(store.note(id))

        undo.redo()
        undo.redo()
        undo.redo()
        XCTAssertEqual(store.note(id)?.body, ticked)
        XCTAssertFalse(undo.canRedo)
    }

    func testRedoKeepsChangesThatHadNoUndoStepOfTheirOwn() {
        let store = makeStore()
        let id = step { store.addNote(body: "").id }
        // Typing in the editor: its undo belongs to the text view, not the store.
        store.updateNoteBody(id, "Typed in the editor")

        undo.undo()
        XCTAssertNil(store.note(id))
        undo.redo()
        XCTAssertEqual(store.note(id)?.body, "Typed in the editor", "redo brings the note back as it was, not as it was created")
    }

    func testUndoingATickInTheNoteReopensItsTask() {
        let store = makeStore()
        let note = step { store.addNote(body: "# Launch\n- [ ] Book venue") }
        step { _ = store.extractActionItems(fromNote: note.id, parser: QuickParser()) }
        let task = store.linkedTasks(forNote: note.id)[0]
        let body = store.note(note.id)!.body
        let ticked = NoteChecklist.toggle(lineAt: 1, in: body)!

        step { store.undoable("Tick Checkbox") { store.updateNoteBody(note.id, ticked) } }
        XCTAssertTrue(store.task(task.id)!.isCompleted)

        undo.undo()
        XCTAssertEqual(store.note(note.id)?.body, body)
        XCTAssertFalse(store.task(task.id)!.isCompleted)
        undo.redo()
        XCTAssertEqual(store.note(note.id)?.body, ticked)
        XCTAssertTrue(store.task(task.id)!.isCompleted)
    }
}

/// Copying from Read mode gives plain text that pastes cleanly into Terminal or a code editor.
@MainActor
final class ReaderCopyTests: XCTestCase {
    func testPlainTextCopyHasRealLineBreaksAndNoPlaceholders() {
        let storage = NSTextStorage(attributedString: MarkdownRenderer.render(
            "Run these:\n\n```bash\nnpm install\nnpm start\n```\n\n- [ ] Buy milk\n- [x] Post letter\n\nFirst line\nsecond line"))
        let layout = NSLayoutManager()
        storage.addLayoutManager(layout)
        let container = NSTextContainer(size: NSSize(width: 600, height: CGFloat.greatestFiniteMagnitude))
        layout.addTextContainer(container)
        let reader = ReaderTextView(frame: NSRect(x: 0, y: 0, width: 600, height: 400), textContainer: container)
        reader.isEditable = false
        reader.setSelectedRange(NSRange(location: 0, length: storage.length))

        // The plain-text flavour ⌘C writes (NSTextView offers the legacy NSStringPboardType).
        let plain = reader.writablePasteboardTypes.filter { $0 == .string || $0.rawValue == "NSStringPboardType" }
        XCTAssertFalse(plain.isEmpty)
        let pb = NSPasteboard(name: NSPasteboard.Name("docket-tests-\(UUID().uuidString)"))
        defer { pb.releaseGlobally() }
        pb.clearContents()
        XCTAssertTrue(reader.writeSelection(to: pb, types: plain))
        XCTAssertEqual(pb.string(forType: .string), "Run these:\nnpm install\nnpm start\nBuy milk\nPost letter\nFirst line\nsecond line")
    }
}

/// A file dragged in from Finder, on a private pasteboard.
private final class FileDrag: NSObject, NSDraggingInfo {
    let draggingPasteboard = NSPasteboard(name: NSPasteboard.Name("docket-tests-\(UUID().uuidString)"))
    let draggingLocation: NSPoint

    init(_ url: URL, at location: NSPoint = .zero) {
        draggingLocation = location
        draggingPasteboard.clearContents()
        draggingPasteboard.writeObjects([url as NSURL])
    }

    deinit { draggingPasteboard.releaseGlobally() }

    var draggingDestinationWindow: NSWindow? { nil }
    var draggingSourceOperationMask: NSDragOperation { .copy }
    var draggedImageLocation: NSPoint { draggingLocation }
    var draggedImage: NSImage? { nil }
    var draggingSource: Any? { nil }
    var draggingSequenceNumber: Int { 1 }
    var draggingFormation: NSDraggingFormation = .default
    var animatesToDestination = false
    var numberOfValidItemsForDrop = 1
    var springLoadingHighlight: NSSpringLoadingHighlight { .none }
    func slideDraggedImage(to screenPoint: NSPoint) {}
    func resetSpringLoading() {}
    func enumerateDraggingItems(options enumOpts: NSDraggingItemEnumerationOptions = [], for view: NSView?, classes classArray: [AnyClass],
                                searchOptions: [NSPasteboard.ReadingOptionKey: Any] = [:],
                                using block: @escaping (NSDraggingItem, Int, UnsafeMutablePointer<ObjCBool>) -> Void) {}
}

/// Photos and videos dropped on a note are copied in the background, then land where they were dropped.
@MainActor
final class NoteMediaDropTests: XCTestCase {
    var dir: URL!
    var previous: URL!
    /// Holds the editor; it is never put on screen.
    var window: NSWindow?

    override func setUp() async throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("docket-drop-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        previous = MediaLibrary.dataDirectory
        MediaLibrary.dataDirectory = dir
    }

    override func tearDown() async throws {
        window = nil
        MediaLibrary.dataDirectory = previous
        try? FileManager.default.removeItem(at: dir)
    }

    /// A small PNG outside the library, like one in Finder.
    private func photo(_ name: String) throws -> URL {
        let image = NSImage(size: NSSize(width: 8, height: 8), flipped: false) { r in
            NSColor.red.setFill()
            r.fill()
            return true
        }
        let png = try XCTUnwrap(image.tiffRepresentation.flatMap(NSBitmapImageRep.init(data:))?.representation(using: .png, properties: [:]))
        let url = dir.appendingPathComponent(name)
        try png.write(to: url)
        return url
    }

    /// The editor's TextKit 1 setup, in `window` unless it should look already closed.
    private func editor(_ text: String, inWindow: Bool) -> MarkdownTextView {
        let storage = NSTextStorage()
        let layout = NSLayoutManager()
        storage.addLayoutManager(layout)
        let container = NSTextContainer(size: NSSize(width: 600, height: CGFloat.greatestFiniteMagnitude))
        layout.addTextContainer(container)
        let tv = MarkdownTextView(frame: NSRect(x: 0, y: 0, width: 600, height: 400), textContainer: container)
        tv.string = text
        if inWindow {
            let window = NSWindow(contentRect: tv.frame, styleMask: [.borderless], backing: .buffered, defer: true)
            window.contentView = tv
            self.window = window
        }
        return tv
    }

    /// Where a drop just before character `index` arrives, in window coordinates.
    private func dropPoint(before index: Int, in tv: NSTextView) -> NSPoint {
        let glyph = tv.layoutManager!.boundingRect(forGlyphRange: NSRange(location: index, length: 1), in: tv.textContainer!)
        return tv.convert(NSPoint(x: glyph.minX + tv.textContainerOrigin.x + 0.5, y: glyph.midY + tv.textContainerOrigin.y), to: nil)
    }

    /// Runs the main queue until `done`, for at most a few seconds.
    private func waitUntil(_ done: () -> Bool) {
        let deadline = Date().addingTimeInterval(5)
        while !done(), Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
    }

    func testReaderTakesADroppedPhotoAndAddsItOnceCopied() throws {
        let storage = NSTextStorage(attributedString: MarkdownRenderer.render("Notes"))
        let layout = NSLayoutManager()
        storage.addLayoutManager(layout)
        let container = NSTextContainer(size: NSSize(width: 600, height: CGFloat.greatestFiniteMagnitude))
        layout.addTextContainer(container)
        let reader = ReaderTextView(frame: NSRect(x: 0, y: 0, width: 600, height: 400), textContainer: container)
        reader.isEditable = false
        var added: [String] = []
        reader.onAppend = { added.append($0) }

        let drop = FileDrag(try photo("Whiteboard.png"))
        XCTAssertTrue(reader.prepareForDragOperation(drop), "a read-only text view turns drops away unless told otherwise")
        XCTAssertTrue(reader.performDragOperation(drop))
        XCTAssertTrue(added.isEmpty, "the copy runs in the background")
        waitUntil { !added.isEmpty }
        XCTAssertEqual(added.count, 1)
        XCTAssertTrue(added[0].hasPrefix("![Whiteboard](attachments/"), added[0])
    }

    func testEditorPutsTheDropWhereItWasDroppedAndLeavesTheCaretOfSomeoneStillTyping() throws {
        let tv = editor("Hello world", inWindow: true)
        XCTAssertTrue(tv.performDragOperation(FileDrag(try photo("Photo.png"), at: dropPoint(before: 5, in: tv))))
        // The user carries on typing at the end while it copies.
        tv.setSelectedRange(NSRange(location: 11, length: 0))
        tv.insertText("!", replacementRange: tv.selectedRange())
        waitUntil { tv.string.contains("attachments/") }

        XCTAssertTrue(tv.string.hasPrefix("Hello\n![Photo](attachments/"), tv.string)
        XCTAssertTrue(tv.string.hasSuffix(")\n world!"), tv.string)
        XCTAssertEqual(tv.selectedRange(), NSRange(location: (tv.string as NSString).length, length: 0), "the caret stays after the typing")
    }

    func testEditorNeverSplitsACharacterWhenTheTextChangedMeanwhile() throws {
        let tv = editor("abcdef", inWindow: true)
        XCTAssertTrue(tv.performDragOperation(FileDrag(try photo("Photo.png"), at: dropPoint(before: 1, in: tv))))
        tv.string = "😀xyz"   // offset 1 is now the middle of the emoji
        waitUntil { tv.string.contains("attachments/") }

        XCTAssertTrue(tv.string.hasPrefix("![Photo](attachments/"), tv.string)
        XCTAssertTrue(tv.string.hasSuffix(")\n😀xyz"), tv.string)
    }

    func testEditorThatClosedMeanwhileAddsThePhotoToTheEndOfTheNote() throws {
        let tv = editor("Hello", inWindow: false)   // like an editor SwiftUI has already removed
        var added: [String] = []
        tv.onAppend = { added.append($0) }
        XCTAssertTrue(tv.performDragOperation(FileDrag(try photo("Photo.png"))))
        waitUntil { !added.isEmpty }

        XCTAssertEqual(tv.string, "Hello")
        XCTAssertEqual(added.count, 1)
        XCTAssertTrue(added[0].hasPrefix("![Photo](attachments/"), added[0])
    }
}
