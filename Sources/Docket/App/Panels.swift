import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// A floating panel that can take keyboard input without activating Docket (like Spotlight),
/// and hides itself when it loses focus or Esc is pressed.
class FloatingPanel: NSPanel {
    var onHide: (() -> Void)?
    /// While true the panel stays up when another window takes the focus (a recording in progress, or the
    /// microphone permission prompt).
    var staysOpen: () -> Bool = { false }
    private(set) var lastHidden = Date.distantPast

    init(size: NSSize) {
        super.init(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: false
        )
        // Transparent window; the SwiftUI content draws a rounded material card and the shadow follows it.
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        isFloatingPanel = true
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        isMovableByWindowBackground = true
        animationBehavior = .utilityWindow
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func resignKey() {
        super.resignKey()
        if !staysOpen() { hide() }
    }

    override func cancelOperation(_ sender: Any?) { hide() }

    func hide() {
        guard isVisible else { return }
        lastHidden = Date()
        orderOut(nil)
        onHide?()
    }
}

/// Distinct type so the capture view's Tab shortcut only applies to its own panel.
final class QuickCapturePanel: FloatingPanel {}

// MARK: - Menu bar item

@MainActor
final class StatusItemController: NSObject {
    private weak var delegate: AppDelegate?
    private var item: NSStatusItem?
    /// Sized on every open to the screen it opens on (`MenuBarPanelLayout`).
    private let panel = FloatingPanel(size: NSSize(width: MenuBarPanelLayout.width, height: 540))
    private var clockTimer: Timer?

    init(delegate: AppDelegate) {
        self.delegate = delegate
        super.init()
    }

    /// Built fresh on every open so it always matches the current light/dark appearance
    /// (a hidden panel's SwiftUI content can miss appearance changes).
    /// The messages that are new show as new in this opening of the panel; then they count as seen.
    private func rebuildContent() {
        guard let delegate else { return }
        let integrations = Integrations.shared
        let newIDs = integrations.newMessageIDs
        panel.contentView = NSHostingView(rootView: MenuBarView(height: panel.frame.height, newMessageIDs: newIDs,
                                                                close: { [weak self] in self?.panel.hide() })
            .environmentObject(delegate.store)
            .environmentObject(delegate.app)
            .environmentObject(delegate.focus))
        integrations.markMessagesSeen()
    }

    func setVisible(_ visible: Bool) {
        if visible, item == nil {
            let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
            item.button?.target = self
            item.button?.action = #selector(clicked(_:))
            item.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
            item.button?.imagePosition = .imageLeading
            self.item = item
        } else if !visible, let item {
            NSStatusBar.system.removeStatusItem(item)
            self.item = nil
        }
    }

    func refresh() {
        guard let delegate, let button = item?.button else { return }
        let focus = delegate.focus
        let symbol: String
        var title = ""
        if focus.isActive {
            symbol = focus.isPaused ? "pause.circle" : "timer"
            title = focus.clock()
        } else {
            let overdue = delegate.store.overdueCount()
            symbol = overdue > 0 ? "checklist.unchecked" : "checklist"
            let count = delegate.store.todayTasks().count
            if Prefs.menuBarShowsCount, count > 0 { title = "\(count)" }
        }
        // A dot on the icon for messages that came in since the panel was last opened.
        let newMessages = Integrations.shared.newMessageCount
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: "Docket")
        image?.isTemplate = true
        button.image = newMessages > 0 ? image.map(Self.withDot) : image
        button.toolTip = newMessages > 0 ? "Docket · \(Fmt.plural(newMessages, "new message"))" : "Docket"
        button.attributedTitle = NSAttributedString(
            string: title.isEmpty ? "" : " " + title,
            attributes: [.font: NSFont.monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .medium)]
        )

        // Tick the menu bar clock only while a focus session is running.
        if focus.isActive, clockTimer == nil {
            let t = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.refresh() }
            }
            RunLoop.main.add(t, forMode: .common)
            clockTimer = t
        } else if !focus.isActive {
            clockTimer?.invalidate()
            clockTimer = nil
        }
    }

    @objc private func clicked(_ sender: NSStatusBarButton) {
        if NSApp.currentEvent?.type == .rightMouseUp {
            showContextMenu()
            return
        }
        if panel.isVisible {
            panel.hide()
        } else if Date().timeIntervalSince(panel.lastHidden) > 0.3 {
            // Clicking the icon makes the open panel resign key (hiding it) just before this runs.
            showPanel(below: sender)
        }
    }

    /// The full height of the screen the icon is on, under the icon.
    private func showPanel(below button: NSStatusBarButton) {
        guard let buttonWindow = button.window else { return }
        let anchor = buttonWindow.convertToScreen(button.convert(button.bounds, to: nil))
        guard let visible = (buttonWindow.screen ?? NSScreen.main)?.visibleFrame else { return }
        panel.setFrame(MenuBarPanelLayout.frame(visibleFrame: visible, anchorMidX: anchor.midX, anchorMinY: anchor.minY), display: false)
        delegate?.app.clock = Date()
        rebuildContent()
        panel.makeKeyAndOrderFront(nil)
        refresh()
    }

    /// Snapshot mode only: shows the dropdown even when the status item isn't on screen.
    func debugShow() {
        guard let visible = NSScreen.main?.visibleFrame else { return }
        let midX = visible.maxX - MenuBarPanelLayout.width / 2 - 20
        panel.setFrame(MenuBarPanelLayout.frame(visibleFrame: visible, anchorMidX: midX), display: false)
        rebuildContent()
        panel.makeKeyAndOrderFront(nil)
    }

    /// The icon with a small dot at its top right (cut out of the symbol, so it reads at menu bar size).
    private static func withDot(_ base: NSImage) -> NSImage {
        let size = NSSize(width: base.size.width + 3, height: base.size.height)
        let image = NSImage(size: size, flipped: false) { _ in
            base.draw(in: NSRect(x: 0, y: (size.height - base.size.height) / 2, width: base.size.width, height: base.size.height))
            let d: CGFloat = 6
            let dot = NSRect(x: size.width - d, y: size.height - d, width: d, height: d)
            NSGraphicsContext.current?.compositingOperation = .clear
            NSBezierPath(ovalIn: dot.insetBy(dx: -1.5, dy: -1.5)).fill()
            NSGraphicsContext.current?.compositingOperation = .sourceOver
            NSColor.black.setFill()
            NSBezierPath(ovalIn: dot).fill()
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "Docket, new messages"
        return image
    }

    private func showContextMenu() {
        guard let delegate, let item else { return }
        let menu = NSMenu()
        let open = NSMenuItem(title: "Open Docket", action: #selector(AppDelegate.showMainWindowAction(_:)), keyEquivalent: "")
        let capture = NSMenuItem(title: "Quick Capture", action: #selector(AppDelegate.quickCaptureAction(_:)), keyEquivalent: "")
        let record = NSMenuItem(title: "Record Voice Note", action: #selector(AppDelegate.recordVoiceNoteAction(_:)), keyEquivalent: "")
        let settings = NSMenuItem(title: "Settings…", action: #selector(AppDelegate.showSettingsAction(_:)), keyEquivalent: "")
        [open, capture, record, settings].forEach { $0.target = delegate; menu.addItem($0) }
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit Docket", action: #selector(NSApplication.terminate(_:)), keyEquivalent: ""))
        item.menu = menu
        item.button?.performClick(nil)
        item.menu = nil
    }
}

// MARK: - Quick capture

@MainActor
final class QuickCaptureController {
    private weak var delegate: AppDelegate?
    private let panel = QuickCapturePanel(size: NSSize(width: 640, height: VoiceCaptureLayout.base))
    /// The voice note under way, kept across openings so closing the panel never loses a recording.
    let voice: VoiceCaptureModel

    init(delegate: AppDelegate) {
        self.delegate = delegate
        voice = VoiceCaptureModel(intake: MemoryCenter.shared.voice)
        panel.level = .modalPanel
        panel.staysOpen = { [weak voice] in voice?.isBusy ?? false }
        panel.onHide = { [weak self] in self?.panelHidden() }
        voice.announce = { [weak delegate] outcome in
            guard let delegate else { return }
            let tasks = outcome.taskIDs.compactMap(delegate.store.task)
            if tasks.isEmpty {
                delegate.app.showToast("Your voice note is in Memory")
            } else {
                NotificationService.shared.deliverVoiceNote(outcome, tasks: tasks)
                delegate.app.showToast("\(VoiceText.headline(tasks: tasks.count)) from your voice note")
            }
        }
    }

    func toggle() {
        panel.isVisible ? panel.hide() : show()
    }

    /// Opens the panel recording (or on the voice note already under way).
    func record() {
        show()
        if !voice.isActive || voice.phase == .result { voice.start() }
    }

    /// Hidden by Esc, a click elsewhere or the shortcut: a recording is stopped and saved (never thrown
    /// away), a finished result is dismissed.
    private func panelHidden() {
        voice.isPresented = false
        switch voice.phase {
        case .recording: voice.stop()
        case .starting: voice.cancel()
        case .result, .failed: voice.reset()
        default: break
        }
    }

    /// Grows or shrinks the panel, keeping its top edge where it is.
    private func resize(to height: CGFloat) {
        var frame = panel.frame
        guard abs(frame.height - height) > 0.5 else { return }
        frame.origin.y += frame.height - height
        frame.size.height = height
        panel.setFrame(frame, display: true, animate: false)
    }

    func show() {
        guard let delegate else { return }
        // Fresh view each time so the field starts empty and focused.
        panel.contentView = NSHostingView(rootView: CapturePanelView(voice: voice, close: { [weak self] in self?.panel.hide() },
                                                                     resize: { [weak self] h in self?.resize(to: h) })
            .environmentObject(delegate.store)
            .environmentObject(delegate.app))
        voice.isPresented = true
        let screen = NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) } ?? NSScreen.main
        if let frame = screen?.visibleFrame {
            let height = voice.panelHeight
            panel.setFrame(NSRect(x: frame.midX - 320, y: frame.minY + frame.height * 0.68 + VoiceCaptureLayout.base - height,
                                  width: 640, height: height), display: false)
        }
        panel.makeKeyAndOrderFront(nil)
        // Put the cursor in the field now, not on the next SwiftUI update, so the first keystrokes
        // after the shortcut are never lost.
        if let host = panel.contentView {
            host.layoutSubtreeIfNeeded()
            if let field = Self.firstEditableField(in: host) { panel.makeFirstResponder(field) }
        }
    }

    private static func firstEditableField(in view: NSView) -> NSTextField? {
        if let field = view as? NSTextField, field.isEditable { return field }
        for sub in view.subviews {
            if let found = firstEditableField(in: sub) { return found }
        }
        return nil
    }
}

// MARK: - Import / export

@MainActor
enum DataTransfer {
    static func export(store: Store) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "Docket Backup \(Fmt.dayKey(Date())).json"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try store.exportData(to: url)
            // Photos and videos go in an "attachments" folder next to the file, as in a Markdown export.
            MediaLibrary.copyReferencedMedia(for: store.notes.map(\.body), to: url.deletingLastPathComponent())
        } catch {
            alert("Export failed", error.localizedDescription)
        }
    }

    static func exportNotes(store: Store) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Export Here"
        panel.message = "Choose a folder for your notes as Markdown files"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let n = try store.exportNotesAsMarkdown(to: url)
            NSWorkspace.shared.activateFileViewerSelecting([url])
            _ = n
        } catch {
            alert("Export failed", error.localizedDescription)
        }
    }

    static func `import`(store: Store) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.message = "Choose a Docket backup (.json)"
        guard panel.runModal() == .OK, let url = panel.url else { return }

        let choice = NSAlert()
        choice.messageText = "Import \(url.lastPathComponent)?"
        choice.informativeText = "Merge adds tasks and notes you don't already have. Replace swaps everything for the file's contents (you can undo with ⌘Z)."
        choice.addButton(withTitle: "Merge")
        choice.addButton(withTitle: "Replace")
        choice.addButton(withTitle: "Cancel")
        let response = choice.runModal()
        guard response != .alertThirdButtonReturn else { return }
        do {
            let n = try store.importData(from: url, replace: response == .alertSecondButtonReturn)
            MediaLibrary.restoreMissingMedia(for: store.notes.map(\.body), from: url.deletingLastPathComponent())
            alert("Import complete", "\(n) tasks and notes imported.")
        } catch {
            alert("Import failed", "That file doesn't look like a Docket backup.\n\n\(error.localizedDescription)")
        }
    }

    static func alert(_ title: String, _ message: String) {
        let a = NSAlert()
        a.messageText = title
        a.informativeText = message
        a.runModal()
    }
}
