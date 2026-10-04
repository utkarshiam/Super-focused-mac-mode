import AppKit
import Quartz
import SwiftUI

/// Lets the note pane insert text (e.g. a photo) at the editor's cursor.
final class NoteBridge: ObservableObject {
    weak var editor: NSTextView?

    /// Inserts on its own line at the cursor. Returns false when no editor is showing.
    @discardableResult
    func insertAtCursor(_ text: String) -> Bool {
        guard let tv = editor, tv.window != nil else { return false }
        let ns = tv.string as NSString
        let sel = tv.selectedRange()
        let atLineStart = sel.location == 0 || ns.substring(with: NSRange(location: sel.location - 1, length: 1)) == "\n"
        tv.insertText((atLineStart ? "" : "\n") + text + "\n", replacementRange: sel)
        return true
    }
}

extension MediaLibrary {
    /// Copies the files on a background queue (a large video from another disk or from iCloud can
    /// take a while) and hands their Markdown lines to `done` on the main queue: empty if none was added.
    static func importFilesInBackground(_ urls: [URL], then done: @escaping @MainActor ([String]) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let lines = importFiles(urls)
            DispatchQueue.main.async { done(lines) }
        }
    }
}

/// Read mode: the note's Markdown rendered as a finished document. Checkboxes tick, links open,
/// photos open full size and videos play (Quick Look). Photos and videos can be dropped in, and
/// photos, videos or text pasted.
struct MarkdownReader: NSViewRepresentable {
    var text: String
    var onToggleTask: (Int) -> Void
    /// Photos or videos dropped on the page, or whatever is pasted: append it to the note.
    var onAppend: (String) -> Void
    var focusOnAppear = false

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSScrollView {
        let storage = NSTextStorage()
        let layout = NSLayoutManager()
        storage.addLayoutManager(layout)
        let container = NSTextContainer(size: NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
        container.widthTracksTextView = true
        layout.addTextContainer(container)

        let tv = ReaderTextView(frame: .zero, textContainer: container)
        tv.minSize = .zero
        tv.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude)
        tv.isVerticallyResizable = true
        tv.isHorizontallyResizable = false
        tv.autoresizingMask = [.width]
        tv.isEditable = false
        tv.isSelectable = true
        tv.drawsBackground = false
        tv.textContainerInset = NSSize(width: 34, height: 24)
        tv.linkTextAttributes = [.foregroundColor: Palette.ink, .underlineStyle: NSUnderlineStyle.single.rawValue, .cursor: NSCursor.pointingHand]
        tv.registerForDraggedTypes([.fileURL, .png, .tiff])
        tv.onToggleTask = onToggleTask
        tv.onAppend = onAppend

        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.autohidesScrollers = true
        scroll.documentView = tv

        context.coordinator.textView = tv
        context.coordinator.render(text)
        context.coordinator.observe()

        if focusOnAppear {
            DispatchQueue.main.async { tv.window?.makeFirstResponder(tv) }
        }
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let tv = context.coordinator.textView else { return }
        tv.onToggleTask = onToggleTask
        tv.onAppend = onAppend
        guard text != context.coordinator.rendered else { return }
        let previous = context.coordinator.rendered ?? ""
        let origin = scroll.contentView.bounds.origin
        context.coordinator.render(text)
        if text.count > previous.count, text.hasPrefix(previous.trimmingCharacters(in: .newlines)) {
            // Something was added at the end (a paste, a drop, a photo): show it.
            tv.scrollRangeToVisible(NSRange(location: tv.textStorage?.length ?? 0, length: 0))
        } else {
            // Keep the reader where it was (e.g. after ticking a checkbox).
            scroll.contentView.scroll(to: origin)
            scroll.reflectScrolledClipView(scroll.contentView)
        }
    }

    final class Coordinator {
        weak var textView: ReaderTextView?
        var rendered: String?
        private var token: NSObjectProtocol?

        func render(_ text: String) {
            rendered = text
            textView?.textStorage?.setAttributedString(MarkdownRenderer.render(text))
        }

        /// Video posters arrive after the first render; redraw when one lands.
        func observe() {
            token = NotificationCenter.default.addObserver(forName: MediaCache.didLoad, object: nil, queue: .main) { [weak self] _ in
                guard let self, let text = self.rendered else { return }
                self.render(text)
            }
        }

        deinit {
            if let token { NotificationCenter.default.removeObserver(token) }
        }
    }
}

/// Keeps lines at a comfortable reading length on wide windows.
private func readableInset(for width: CGFloat) -> CGFloat { max(34, (width - 760) / 2) }

final class ReaderTextView: NSTextView, QLPreviewPanelDataSource, QLPreviewPanelDelegate {
    var onToggleTask: ((Int) -> Void)?
    var onAppend: ((String) -> Void)?
    private var previewURL: URL?

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        let side = readableInset(for: newSize.width)
        if abs(textContainerInset.width - side) > 0.5 { textContainerInset = NSSize(width: side, height: 24) }
    }

    /// The character under the pointer, only when the pointer is actually on its glyph.
    private func character(at event: NSEvent) -> Int? {
        guard let layout = layoutManager, let container = textContainer, let storage = textStorage, storage.length > 0 else { return nil }
        let p = convert(event.locationInWindow, from: nil)
        let local = NSPoint(x: p.x - textContainerOrigin.x, y: p.y - textContainerOrigin.y)
        var fraction: CGFloat = 0
        let glyph = layout.glyphIndex(for: local, in: container, fractionOfDistanceThroughGlyph: &fraction)
        let rect = layout.boundingRect(forGlyphRange: NSRange(location: glyph, length: 1), in: container)
        guard rect.insetBy(dx: -3, dy: -3).contains(local) else { return nil }
        let index = layout.characterIndexForGlyph(at: glyph)
        return index < storage.length ? index : nil
    }

    override func mouseDown(with event: NSEvent) {
        if let i = character(at: event), let storage = textStorage {
            if let line = storage.attribute(.docketTaskLine, at: i, effectiveRange: nil) as? Int {
                Haptics.select()
                onToggleTask?(line)
                return
            }
            if let url = storage.attribute(.docketMediaURL, at: i, effectiveRange: nil) as? URL {
                showPreview(url)
                return
            }
        }
        super.mouseDown(with: event)
    }

    // MARK: Quick Look (photos full size, videos play)

    private func showPreview(_ url: URL) {
        previewURL = url
        window?.makeFirstResponder(self)
        guard let panel = QLPreviewPanel.shared() else { return }
        if panel.isVisible {
            // The panel may still belong to another reader (a different note, or before Read → Edit → Read).
            panel.updateController()
            panel.reloadData()
        } else {
            panel.makeKeyAndOrderFront(nil)
        }
    }

    override func acceptsPreviewPanelControl(_ panel: QLPreviewPanel!) -> Bool { previewURL != nil }

    override func beginPreviewPanelControl(_ panel: QLPreviewPanel!) {
        panel.dataSource = self
        panel.delegate = self
    }

    override func endPreviewPanelControl(_ panel: QLPreviewPanel!) {
        // Leave the panel alone if another reader has already taken it over.
        guard panel.dataSource === self else { return }
        panel.dataSource = nil
        panel.delegate = nil
    }

    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int { previewURL == nil ? 0 : 1 }

    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> QLPreviewItem! { previewURL as NSURL? }

    // MARK: Copy

    /// Plain text copies as it reads: the renderer's line separators (U+2028) become real line breaks,
    /// and the stand-in characters for checkboxes, photos, videos and rules are left out.
    override func writeSelection(to pboard: NSPasteboard, type: NSPasteboard.PasteboardType) -> Bool {
        // NSTextView asks for the legacy NSStringPboardType rather than .string.
        guard type == .string || type.rawValue == "NSStringPboardType", let storage = textStorage else {
            return super.writeSelection(to: pboard, type: type)
        }
        let source = storage.string as NSString
        let text = selectedRanges.map { source.substring(with: $0.rangeValue) }.joined(separator: "\n")
        return pboard.setString(text.replacingOccurrences(of: "\u{2028}", with: "\n")
            .replacingOccurrences(of: "\u{FFFC}\t", with: "")
            .replacingOccurrences(of: "\u{FFFC}", with: "")
            .replacingOccurrences(of: "\u{200B}", with: ""), forType: .string)
    }

    // MARK: Paste and drop

    override func validateUserInterfaceItem(_ item: NSValidatedUserInterfaceItem) -> Bool {
        if item.action == #selector(paste(_:)) {
            let pb = NSPasteboard.general
            return MediaLibrary.pasteboardHasMedia(pb) || pb.string(forType: .string)?.isEmpty == false
        }
        return super.validateUserInterfaceItem(item)
    }

    /// ⌘V while reading adds what's on the clipboard to the end of the note (Markdown shows formatted).
    override func paste(_ sender: Any?) {
        let pb = NSPasteboard.general
        let files = MediaLibrary.mediaFileURLs(on: pb)
        if !files.isEmpty {
            appendFiles(files)
        } else if let lines = MediaLibrary.importFromPasteboard(pb) {
            onAppend?(lines.joined(separator: "\n\n"))
        } else if let text = pb.string(forType: .string), !text.isEmpty {
            onAppend?(text)
        }
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        MediaLibrary.mediaFileURLs(on: sender.draggingPasteboard).isEmpty ? super.draggingEntered(sender) : .copy
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        MediaLibrary.mediaFileURLs(on: sender.draggingPasteboard).isEmpty ? super.draggingUpdated(sender) : .copy
    }

    /// NSTextView turns every drop away while it isn't editable; photos and videos are welcome here.
    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
        MediaLibrary.mediaFileURLs(on: sender.draggingPasteboard).isEmpty ? super.prepareForDragOperation(sender) : true
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let files = MediaLibrary.mediaFileURLs(on: sender.draggingPasteboard)
        guard !files.isEmpty else { return super.performDragOperation(sender) }
        appendFiles(files)
        return true
    }

    /// Copies the files without holding up the app, then adds them to the end of this view's note.
    private func appendFiles(_ files: [URL]) {
        let onAppend = onAppend
        MediaLibrary.importFilesInBackground(files) { lines in
            guard !lines.isEmpty else {
                NSSound.beep()
                return
            }
            onAppend?(lines.joined(separator: "\n\n"))
        }
    }
}
