import AppKit
import SwiftUI

/// Plain-text Markdown editor with live styling (headings, lists, checkboxes, bold, code, #tags),
/// clickable "- [ ]" checkboxes, list continuation on Return, and "Create Task from Selection".
struct MarkdownEditor: NSViewRepresentable {
    @Binding var text: String
    var onCreateTask: (String) -> Void
    var focusOnAppear = false
    /// Lets the pane insert photos, videos and PDFs at the cursor.
    var bridge: NoteBridge?
    /// A whole Markdown document was pasted into an empty note (the pane switches to Read).
    var onPastedDocument: (() -> Void)?
    /// Media that finishes copying after this editor has closed goes to the end of the note.
    var onAppend: ((String) -> Void)?

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let storage = NSTextStorage()
        let layout = NSLayoutManager()
        storage.addLayoutManager(layout)
        let container = NSTextContainer(size: NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
        container.widthTracksTextView = true
        layout.addTextContainer(container)

        let tv = MarkdownTextView(frame: .zero, textContainer: container)
        tv.minSize = .zero
        tv.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude)
        tv.isVerticallyResizable = true
        tv.isHorizontallyResizable = false
        tv.autoresizingMask = [.width]
        tv.isRichText = false
        tv.importsGraphics = false
        tv.allowsUndo = true
        tv.usesFindBar = true
        tv.isIncrementalSearchingEnabled = true
        tv.isAutomaticQuoteSubstitutionEnabled = false
        tv.isAutomaticDashSubstitutionEnabled = false
        tv.isAutomaticLinkDetectionEnabled = true
        tv.drawsBackground = false
        tv.linkTextAttributes = [.foregroundColor: Palette.ink, .underlineStyle: NSUnderlineStyle.single.rawValue, .cursor: NSCursor.pointingHand]
        tv.textContainerInset = NSSize(width: 34, height: 22)
        tv.font = MarkdownStyler.baseFont
        tv.typingAttributes = MarkdownStyler.baseAttributes
        tv.insertionPointColor = Palette.ink
        tv.delegate = context.coordinator
        storage.delegate = context.coordinator
        tv.onCreateTask = { onCreateTask($0) }
        tv.onPastedDocument = onPastedDocument
        tv.onAppend = onAppend
        tv.updateDragTypeRegistration()
        tv.string = text
        bridge?.editor = tv

        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.autohidesScrollers = true
        scroll.documentView = tv
        context.coordinator.textView = tv

        if focusOnAppear {
            DispatchQueue.main.async { tv.window?.makeFirstResponder(tv) }
        }
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.parent = self
        context.coordinator.textView?.onPastedDocument = onPastedDocument
        context.coordinator.textView?.onAppend = onAppend
        if let tv = context.coordinator.textView { bridge?.editor = tv }
        guard let tv = context.coordinator.textView, tv.string != text else { return }
        // External change (e.g. a linked task was completed): keep the caret where it was.
        let selection = tv.selectedRange()
        tv.string = text
        let length = (text as NSString).length
        tv.setSelectedRange(NSRange(location: min(selection.location, length), length: 0))
    }

    final class Coordinator: NSObject, NSTextViewDelegate, NSTextStorageDelegate {
        var parent: MarkdownEditor
        weak var textView: MarkdownTextView?

        init(_ parent: MarkdownEditor) { self.parent = parent }

        func textDidChange(_ notification: Notification) {
            guard let tv = notification.object as? NSTextView else { return }
            parent.text = tv.string
        }

        func textStorage(_ storage: NSTextStorage, didProcessEditing mask: NSTextStorageEditActions, range: NSRange, changeInLength: Int) {
            guard mask.contains(.editedCharacters) else { return }
            MarkdownStyler.style(storage)
        }

        func textView(_ tv: NSTextView, doCommandBy selector: Selector) -> Bool {
            switch selector {
            case #selector(NSResponder.insertNewline(_:)): return continueList(tv)
            case #selector(NSResponder.insertTab(_:)): return indent(tv, by: 1)
            case #selector(NSResponder.insertBacktab(_:)): return indent(tv, by: -1)
            default: return false
            }
        }

        /// Indent, then the marker with its trailing space and optional box ("- ", "3. [ ] "),
        /// the bullet or number token, and the number's digits.
        private static let listPrefix = try! NSRegularExpression(pattern: #"^(\s*)(([-*+]|(\d{1,9})[.)]) (?:\[[ xX]\] )?)"#)

        private func currentLine(_ tv: NSTextView) -> (range: NSRange, text: String)? {
            let ns = tv.string as NSString
            let sel = tv.selectedRange()
            guard sel.length == 0 else { return nil }
            var range = ns.lineRange(for: NSRange(location: sel.location, length: 0))
            var line = ns.substring(with: range)
            if line.hasSuffix("\n") {
                line.removeLast()
                range.length -= 1
            }
            return (range, line)
        }

        private func continueList(_ tv: NSTextView) -> Bool {
            guard let (range, line) = currentLine(tv) else { return false }
            let ns = line as NSString
            guard let m = Self.listPrefix.firstMatch(in: line, range: NSRange(location: 0, length: ns.length)) else { return false }
            let indent = ns.substring(with: m.range(at: 1))
            let marker = ns.substring(with: m.range(at: 2))
            let content = ns.substring(from: m.range.length).trimmingCharacters(in: .whitespaces)

            if content.isEmpty {
                // Return on an empty item ends the list.
                tv.insertText("", replacementRange: NSRange(location: range.location, length: m.range.length))
                return true
            }
            var token = ns.substring(with: m.range(at: 3))
            if m.range(at: 4).location != NSNotFound, let n = Int(ns.substring(with: m.range(at: 4))) {
                token = "\(n + 1)" + String(token.dropFirst(String(n).count))
            }
            // A task item continues as a fresh, unticked task.
            let next = token + (marker.contains("[") ? " [ ] " : " ")
            tv.insertText("\n" + indent + next, replacementRange: tv.selectedRange())
            return true
        }

        private func indent(_ tv: NSTextView, by direction: Int) -> Bool {
            guard let (range, line) = currentLine(tv),
                  Self.listPrefix.firstMatch(in: line, range: NSRange(location: 0, length: (line as NSString).length)) != nil else { return false }
            let caret = tv.selectedRange().location
            if direction > 0 {
                tv.insertText("  ", replacementRange: NSRange(location: range.location, length: 0))
                tv.setSelectedRange(NSRange(location: caret + 2, length: 0))
            } else {
                let spaces = line.prefix { $0 == " " }.count
                let remove = min(2, spaces)
                guard remove > 0 else { return true }
                tv.insertText("", replacementRange: NSRange(location: range.location, length: remove))
                tv.setSelectedRange(NSRange(location: max(range.location, caret - remove), length: 0))
            }
            return true
        }
    }
}

final class MarkdownTextView: NSTextView {
    var onCreateTask: ((String) -> Void)?
    var onPastedDocument: (() -> Void)?
    var onAppend: ((String) -> Void)?
    private static let checkbox = try! NSRegularExpression(pattern: #"^(\s*+(?:>\s*+)*+(?:[-*+]|\d{1,9}[.)])\s+)(\[[ xX]\])"#)
    private static let markdownSyntax = try! NSRegularExpression(
        pattern: #"(?m)^(#{1,6}\s|\s*[-*+]\s|\s*\d+[.)]\s|>\s?|```|\|.*\|)|\*\*[^*]+\*\*|\[[^\]]+\]\([^)]+\)"#)

    /// Keep lines at a comfortable reading length on wide windows (same as Read mode).
    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        let side = max(34, (newSize.width - 760) / 2)
        if abs(textContainerInset.width - side) > 0.5 { textContainerInset = NSSize(width: side, height: 22) }
    }

    /// Photos, videos and PDFs paste in as attachments (a Markdown line of their own); a whole Markdown
    /// document pasted into an empty note flips the note to its formatted view.
    override func paste(_ sender: Any?) {
        let pb = NSPasteboard.general
        let files = MediaLibrary.mediaFileURLs(on: pb)
        if !files.isEmpty {
            insertFiles(files, replacing: selectedRange())
            return
        }
        if let lines = MediaLibrary.importFromPasteboard(pb) {
            insertOnOwnLine(lines.joined(separator: "\n\n"), at: selectedRange())
            return
        }
        let wasEmpty = string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        super.paste(sender)
        if wasEmpty, let pasted = pb.string(forType: .string), looksLikeMarkdownDocument(pasted) {
            onPastedDocument?()
        }
    }

    private func looksLikeMarkdownDocument(_ text: String) -> Bool {
        let ns = text as NSString
        return text.contains("\n") && Self.markdownSyntax.firstMatch(in: text, range: NSRange(location: 0, length: ns.length)) != nil
    }

    private func insertOnOwnLine(_ text: String, at range: NSRange) {
        let ns = string as NSString
        let atLineStart = range.location == 0 || ns.substring(with: NSRange(location: range.location - 1, length: 1)) == "\n"
        insertText((atLineStart ? "" : "\n") + text + "\n", replacementRange: range)
    }

    /// Copies the files without holding up the app, then puts them where they were pasted.
    private func insertFiles(_ files: [URL], replacing range: NSRange) {
        insertWhenReady(replacing: range) { MediaLibrary.importFilesInBackground(files, then: $0) }
    }

    /// Runs `start` (which copies media in the background) and puts the Markdown lines it produces
    /// where they were pasted or dropped. If the user carried on meanwhile, nothing is replaced, they
    /// go in at the same offset, and the caret stays where the user is typing.
    private func insertWhenReady(replacing range: NSRange, _ start: (@escaping @MainActor ([String]) -> Void) -> Void) {
        let original = string
        let onAppend = onAppend
        start { [weak self] lines in
            guard !lines.isEmpty else {
                NSSound.beep()
                return
            }
            let snippet = lines.joined(separator: "\n\n")
            guard let self, self.window != nil else {
                // The editor closed meanwhile (another note, or Read mode).
                onAppend?(snippet)
                return
            }
            let caret = self.selectedRange()
            guard self.string != original || caret != range else {
                self.insertOnOwnLine(snippet, at: range)
                return
            }
            let ns = self.string as NSString
            let length = ns.length
            let location = min(range.location, length)
            // Never inside a character such as an emoji.
            let target = location < length ? ns.rangeOfComposedCharacterSequence(at: location).location : location
            self.insertOnOwnLine(snippet, at: NSRange(location: target, length: 0))
            let added = (self.string as NSString).length - length
            self.setSelectedRange(NSRange(location: caret.location >= target ? caret.location + added : caret.location, length: caret.length))
        }
    }

    /// Text drops work as usual; photos, videos and PDFs (files, files promised by Photos or a browser,
    /// image data, links to media on the web) are taken too.
    override func updateDragTypeRegistration() {
        super.updateDragTypeRegistration()
        let types = Set(registeredDraggedTypes)
        registerForDraggedTypes(registeredDraggedTypes + MediaLibrary.dropTypes.filter { !types.contains($0) })
    }

    /// The text view only registers its own (text) types once it's in a window.
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil { updateDragTypeRegistration() }
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        MediaLibrary.dropHasMedia(sender.draggingPasteboard) ? .copy : super.draggingEntered(sender)
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard MediaLibrary.dropHasMedia(sender.draggingPasteboard) else { return super.draggingUpdated(sender) }
        // Show where it will land.
        let index = characterIndexForInsertion(at: convert(sender.draggingLocation, from: nil))
        setSelectedRange(NSRange(location: index, length: 0))
        return .copy
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let pb = sender.draggingPasteboard
        guard MediaLibrary.dropHasMedia(pb) else { return super.performDragOperation(sender) }
        let index = characterIndexForInsertion(at: convert(sender.draggingLocation, from: nil))
        window?.makeFirstResponder(self)
        insertWhenReady(replacing: NSRange(location: index, length: 0)) { MediaLibrary.importDrop(pb, then: $0) }
        return true
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let index = characterIndexForInsertion(at: point)
        let ns = string as NSString
        if ns.length > 0 {
            let lineRange = ns.lineRange(for: NSRange(location: min(index, ns.length - 1), length: 0))
            let line = ns.substring(with: lineRange)
            if let m = Self.checkbox.firstMatch(in: line, range: NSRange(location: 0, length: (line as NSString).length)) {
                let box = NSRange(location: lineRange.location + m.range(at: 2).location, length: m.range(at: 2).length)
                if index >= box.location, index <= box.location + box.length {
                    let checked = (line as NSString).substring(with: m.range(at: 2)) != "[ ]"
                    let replacement = checked ? "[ ]" : "[x]"
                    if shouldChangeText(in: box, replacementString: replacement) {
                        textStorage?.replaceCharacters(in: box, with: replacement)
                        didChangeText()
                    }
                    return
                }
            }
        }
        super.mouseDown(with: event)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard window?.firstResponder === self,
              event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command else {
            return super.performKeyEquivalent(with: event)
        }
        switch event.charactersIgnoringModifiers {
        case "b": wrapSelection("**"); return true
        case "i": wrapSelection("*"); return true
        default: return super.performKeyEquivalent(with: event)
        }
    }

    private func wrapSelection(_ marker: String) {
        let range = selectedRange()
        let selected = (string as NSString).substring(with: range)
        insertText(marker + selected + marker, replacementRange: range)
        if selected.isEmpty {
            setSelectedRange(NSRange(location: range.location + marker.count, length: 0))
        }
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = super.menu(for: event) ?? NSMenu()
        let text = taskCandidate()
        if !text.isEmpty {
            let item = NSMenuItem(title: selectedRange().length > 0 ? "Create Task from Selection" : "Create Task from This Line",
                                  action: #selector(createTask(_:)), keyEquivalent: "")
            item.target = self
            menu.insertItem(item, at: 0)
            menu.insertItem(.separator(), at: 1)
        }
        return menu
    }

    private func taskCandidate() -> String {
        let ns = string as NSString
        var text: String
        if selectedRange().length > 0 {
            text = ns.substring(with: selectedRange())
        } else if ns.length > 0 {
            let caret = min(selectedRange().location, ns.length - 1)
            text = ns.substring(with: ns.lineRange(for: NSRange(location: max(0, caret), length: 0)))
        } else {
            return ""
        }
        text = text.replacingOccurrences(of: #"^\s*((?:[-*+]|\d+[.)])\s+(\[[ xX]\]\s+)?|#+\s+)"#, with: "", options: .regularExpression)
        return text.split(separator: "\n").first.map(String.init)?.trimmingCharacters(in: .whitespaces) ?? ""
    }

    @objc private func createTask(_ sender: Any?) {
        let text = taskCandidate()
        if !text.isEmpty { onCreateTask?(text) }
    }
}

enum MarkdownStyler {
    static let baseFont = NSFont.systemFont(ofSize: 15)
    static let paragraph: NSParagraphStyle = {
        let p = NSMutableParagraphStyle()
        p.lineSpacing = 3.5
        p.paragraphSpacing = 3
        return p
    }()

    static var baseAttributes: [NSAttributedString.Key: Any] {
        [.font: baseFont, .foregroundColor: Palette.ink, .paragraphStyle: paragraph]
    }

    private static func re(_ p: String, _ o: NSRegularExpression.Options = []) -> NSRegularExpression {
        try! NSRegularExpression(pattern: p, options: o)
    }

    private static let heading = re(#"^(#{1,6})\s+.*$"#, .anchorsMatchLines)
    private static let checked = re(#"^(\s*+(?:>\s*+)*+(?:[-*+]|\d{1,9}[.)])\s+\[[xX]\])(.*)$"#, .anchorsMatchLines)
    private static let unchecked = re(#"^(\s*+(?:>\s*+)*+(?:[-*+]|\d{1,9}[.)])\s+\[ \])"#, .anchorsMatchLines)
    private static let bullet = re(#"^(\s*(?:[-*+]|\d+[.)]))\s"#, .anchorsMatchLines)
    private static let quote = re(#"^>\s?.*$"#, .anchorsMatchLines)
    private static let rule = re(#"^(-{3,}|\*{3,})\s*$"#, .anchorsMatchLines)
    private static let bold = re(#"(\*\*|__)(?=\S)(.+?)(?<=\S)\1"#)
    private static let italic = re(#"(?<![\*\w])([*_])(?=\S)([^*_\n]+?)(?<=\S)\1(?![\*\w])"#)
    private static let code = re(#"`[^`\n]+`"#)
    private static let fence = re(#"^```.*?^```\s*$"#, [.anchorsMatchLines, .dotMatchesLineSeparators])
    private static let tag = re(#"(?<=^|\s)#[\p{L}][\p{L}\p{N}_\-/]*"#, .anchorsMatchLines)
    private static let link = re(#"\[([^\]]+)\]\(([^)\s]+)\)"#)

    static func style(_ storage: NSTextStorage) {
        let s = storage.string
        let full = NSRange(location: 0, length: (s as NSString).length)
        storage.setAttributes(baseAttributes, range: full)

        // Ink and paper: structure in ink, syntax marks in ink3, nothing coloured.
        let secondary = Palette.ink2
        let tertiary = Palette.ink3
        let accent = Palette.ink

        heading.enumerateMatches(in: s, range: full) { m, _, _ in
            guard let m else { return }
            let level = m.range(at: 1).length
            let size: CGFloat = [30, 22, 18, 16, 15, 15][level - 1]
            let kern: CGFloat = [-0.7, -0.4, -0.3, -0.2, 0, 0][level - 1]
            let p = NSMutableParagraphStyle()
            p.lineSpacing = 2
            p.paragraphSpacingBefore = level <= 2 ? 12 : 8
            p.paragraphSpacing = 4
            storage.addAttributes([.font: NSFont.systemFont(ofSize: size, weight: level <= 2 ? .bold : .semibold), .paragraphStyle: p, .kern: kern], range: m.range)
            storage.addAttribute(.foregroundColor, value: tertiary, range: m.range(at: 1))
        }
        bullet.enumerateMatches(in: s, range: full) { m, _, _ in
            guard let m else { return }
            storage.addAttribute(.foregroundColor, value: accent, range: m.range(at: 1))
        }
        unchecked.enumerateMatches(in: s, range: full) { m, _, _ in
            guard let m else { return }
            storage.addAttributes([.foregroundColor: accent, .font: NSFont.monospacedSystemFont(ofSize: 13.5, weight: .semibold)], range: m.range(at: 1))
        }
        checked.enumerateMatches(in: s, range: full) { m, _, _ in
            guard let m else { return }
            storage.addAttributes([.foregroundColor: secondary, .font: NSFont.monospacedSystemFont(ofSize: 13.5, weight: .semibold)], range: m.range(at: 1))
            storage.addAttributes([.foregroundColor: secondary, .strikethroughStyle: NSUnderlineStyle.single.rawValue], range: m.range(at: 2))
        }
        quote.enumerateMatches(in: s, range: full) { m, _, _ in
            guard let m else { return }
            let italicFont = NSFontManager.shared.convert(baseFont, toHaveTrait: .italicFontMask)
            storage.addAttributes([.foregroundColor: secondary, .font: italicFont], range: m.range)
        }
        rule.enumerateMatches(in: s, range: full) { m, _, _ in
            guard let m else { return }
            storage.addAttribute(.foregroundColor, value: tertiary, range: m.range)
        }
        bold.enumerateMatches(in: s, range: full) { m, _, _ in
            guard let m else { return }
            let current = storage.attribute(.font, at: m.range.location, effectiveRange: nil) as? NSFont ?? baseFont
            storage.addAttribute(.font, value: NSFontManager.shared.convert(current, toHaveTrait: .boldFontMask), range: m.range)
            storage.addAttribute(.foregroundColor, value: tertiary, range: NSRange(location: m.range.location, length: 2))
            storage.addAttribute(.foregroundColor, value: tertiary, range: NSRange(location: NSMaxRange(m.range) - 2, length: 2))
        }
        italic.enumerateMatches(in: s, range: full) { m, _, _ in
            guard let m else { return }
            let current = storage.attribute(.font, at: m.range.location, effectiveRange: nil) as? NSFont ?? baseFont
            storage.addAttribute(.font, value: NSFontManager.shared.convert(current, toHaveTrait: .italicFontMask), range: m.range)
        }
        tag.enumerateMatches(in: s, range: full) { m, _, _ in
            guard let m else { return }
            storage.addAttributes([.foregroundColor: secondary, .font: NSFont.systemFont(ofSize: 14, weight: .semibold)], range: m.range)
        }
        link.enumerateMatches(in: s, range: full) { m, _, _ in
            guard let m else { return }
            storage.addAttribute(.foregroundColor, value: tertiary, range: m.range)
            storage.addAttributes([.foregroundColor: Palette.ink, .underlineStyle: NSUnderlineStyle.single.rawValue], range: m.range(at: 1))
            if let url = URL(string: (s as NSString).substring(with: m.range(at: 2))) {
                storage.addAttribute(.link, value: url, range: m.range(at: 1))
            }
        }
        let codeAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: 13, weight: .medium),
            .backgroundColor: Palette.fill,
            .foregroundColor: Palette.ink,
        ]
        code.enumerateMatches(in: s, range: full) { m, _, _ in
            guard let m else { return }
            storage.addAttributes(codeAttrs, range: m.range)
        }
        fence.enumerateMatches(in: s, range: full) { m, _, _ in
            guard let m else { return }
            storage.addAttributes([
                .font: NSFont.monospacedSystemFont(ofSize: 13, weight: .regular),
                .backgroundColor: Palette.fill,
                .foregroundColor: Palette.ink,
            ], range: m.range)
        }
    }
}
