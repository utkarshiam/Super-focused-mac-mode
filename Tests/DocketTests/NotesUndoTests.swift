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
