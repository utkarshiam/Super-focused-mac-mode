import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// A floating panel that can take keyboard input without activating Docket (like Spotlight),
/// and hides itself when it loses focus or Esc is pressed.
class FloatingPanel: NSPanel {
    var onHide: (() -> Void)?
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
        hide()
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
    private let panel = FloatingPanel(size: NSSize(width: 370, height: 540))
    private var clockTimer: Timer?

    init(delegate: AppDelegate) {
        self.delegate = delegate
        super.init()
    }

    /// Built fresh on every open so it always matches the current light/dark appearance
    /// (a hidden panel's SwiftUI content can miss appearance changes).
    private func rebuildContent() {
        guard let delegate else { return }
        panel.contentView = NSHostingView(rootView: MenuBarView(close: { [weak self] in self?.panel.hide() })
            .environmentObject(delegate.store)
            .environmentObject(delegate.app)
            .environmentObject(delegate.focus))
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
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: "Docket")
        image?.isTemplate = true
        button.image = image
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

    private func showPanel(below button: NSStatusBarButton) {
        guard let buttonWindow = button.window else { return }
        let anchor = buttonWindow.convertToScreen(button.convert(button.bounds, to: nil))
        let screen = buttonWindow.screen ?? NSScreen.main
        let size = panel.frame.size
        var x = anchor.midX - size.width / 2
        if let frame = screen?.visibleFrame {
            x = min(max(x, frame.minX + 8), frame.maxX - size.width - 8)
        }
        panel.setFrameOrigin(NSPoint(x: x, y: anchor.minY - size.height - 6))
        delegate?.app.clock = Date()
        rebuildContent()
        panel.makeKeyAndOrderFront(nil)
    }

    /// Snapshot mode only: shows the dropdown even when the status item isn't on screen.
    func debugShow() {
        guard let frame = NSScreen.main?.visibleFrame else { return }
        panel.setFrameOrigin(NSPoint(x: frame.maxX - panel.frame.width - 20, y: frame.maxY - panel.frame.height - 6))
        rebuildContent()
        panel.makeKeyAndOrderFront(nil)
    }

    private func showContextMenu() {
        guard let delegate, let item else { return }
        let menu = NSMenu()
        let open = NSMenuItem(title: "Open Docket", action: #selector(AppDelegate.showMainWindowAction(_:)), keyEquivalent: "")
        let capture = NSMenuItem(title: "Quick Capture", action: #selector(AppDelegate.quickCaptureAction(_:)), keyEquivalent: "")
        let settings = NSMenuItem(title: "Settings…", action: #selector(AppDelegate.showSettingsAction(_:)), keyEquivalent: "")
        [open, capture, settings].forEach { $0.target = delegate; menu.addItem($0) }
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
    private let panel = QuickCapturePanel(size: NSSize(width: 640, height: 172))

    init(delegate: AppDelegate) {
        self.delegate = delegate
        panel.level = .modalPanel
    }

    func toggle() {
        panel.isVisible ? panel.hide() : show()
    }

    func show() {
        guard let delegate else { return }
        // Fresh view each time so the field starts empty and focused.
        panel.contentView = NSHostingView(rootView: QuickCaptureView(close: { [weak self] in self?.panel.hide() })
            .environmentObject(delegate.store)
            .environmentObject(delegate.app))
        let screen = NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) } ?? NSScreen.main
        if let frame = screen?.visibleFrame {
            let size = panel.frame.size
            panel.setFrameOrigin(NSPoint(x: frame.midX - size.width / 2, y: frame.minY + frame.height * 0.68))
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
