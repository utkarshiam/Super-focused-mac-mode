import AppKit
import SwiftUI

/// Development aid: with DOCKET_SNAPSHOT_DIR set, Docket walks through its main screens,
/// writes a PNG of each, and quits. Used to check layouts without clicking around.
@MainActor
enum DebugSnapshot {
    static var directory: URL? {
        guard let path = ProcessInfo.processInfo.environment["DOCKET_SNAPSHOT_DIR"], !path.isEmpty else { return nil }
        return URL(fileURLWithPath: path, isDirectory: true)
    }

    static var isActive: Bool { directory != nil }

    static func note(_ line: String) {
        guard let dir = directory else { return }
        let url = dir.appendingPathComponent("results.txt")
        let old = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        try? (old + line + "\n").write(to: url, atomically: true, encoding: .utf8)
    }

    static func runIfRequested(_ d: AppDelegate) {
        guard let dir = directory else { return }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        d.showMainWindow()
        // Same size every run (the stress step shrinks it, and the frame is autosaved).
        d.mainWindow.setContentSize(NSSize(width: 1220, height: 780))

        let firstTask = { d.store.todayTasks().first { $0.estimateMinutes ?? 0 > 2 } ?? d.store.tasks.first }
        let steps: [(String, () -> Void)] = [
            ("1-calendar", { d.app.selection = .calendar }),
            ("2-today-detail", { d.app.selectedTaskID = firstTask()?.id }),
            ("3-month", { d.app.calendarMode = .month }),
            ("4-list", {
                d.app.calendarMode = .agenda
                if let l = d.store.lists.first { d.app.selection = .list(l.id) }
            }),
            ("5-notes", {
                d.app.selection = .notes
                d.app.selectedNoteID = d.store.notes.first { $0.body.contains("Action items") }?.id
            }),
            ("6-notes-guide", { d.app.selectedNoteID = d.store.notes.first { $0.isPinned }?.id }),
            ("7-insights", { d.app.selection = .insights }),
            ("8-palette", {
                d.app.selection = .calendar
                d.app.showPalette = true
            }),
        ]

        let log = note
        func describe(_ title: String) -> String {
            guard let t = d.store.tasks.first(where: { $0.title == title }) else { return "MISSING \(title)" }
            return "OK \(t.title) | due=\(t.dueDate.map { Fmt.due($0, hasTime: t.dueHasTime) } ?? "-") est=\(t.estimateMinutes ?? 0) prio=\(t.priority.label) list=\(d.store.list(t.listID)?.name ?? "Inbox") planned=\(t.scheduledDate != nil) reminders=\(t.reminders.map { ($0.isAlarm ? "alarm" : "notify") + "\($0.trigger)" })"
        }

        let interactive: [(String, () -> Void)] = [
            // Type into the main window's quick-add bar.
            ("11-quickadd-typing", {
                d.app.showPalette = false
                d.app.selection = .calendar
                d.app.selectedTaskID = nil
                d.app.focusQuickAdd += 1
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { type("Call investor tomorrow 10am 30m !!", into: d.mainWindow) }
            }),
            ("12-quickadd-saved", {
                type("\r", into: d.mainWindow)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { log("main quick add: " + describe("Call investor")) }
            }),
            // Global quick capture panel.
            ("13-capture-typing", {
                d.app.showQuickCapture()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    if let panel = NSApp.windows.first(where: { $0 is QuickCapturePanel && $0.isVisible }) {
                        type("Board prep fri 3pm 90m !!! #work @alarm15", into: panel)
                    } else {
                        log("capture panel: NOT VISIBLE")
                    }
                }
            }),
            ("14-capture-saved", {
                if let panel = NSApp.windows.first(where: { $0 is QuickCapturePanel && $0.isVisible }) {
                    log("capture panel key=\(panel.isKeyWindow)")
                    type("\r", into: panel)
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { log("capture: " + describe("Board prep")) }
            }),
            ("15-menubar", { d.debugShowMenuBarPanel() }),
            ("16-settings", { d.showSettings() }),
            ("21-read-mode", {
                NSApp.windows.first { $0.title == "Docket Settings" }?.close()
                d.app.selection = .notes
                let id = d.store.addNote(body: showcaseMarkdown()).id
                d.app.noteModes[id] = .read
                d.app.selectedNoteID = id
            }),
            ("21b-read-middle", { scrollReader(in: d.mainWindow, to: "Focus on the two") }),
            ("21c-read-bottom", { scrollReader(in: d.mainWindow, to: nil) }),
            ("22-read-no-sidebar", {
                d.app.sidebarVisible = false
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { scrollReader(in: d.mainWindow, to: "Revenue grew") }
            }),
            ("23-edit-mode", {
                if let id = d.app.selectedNoteID { d.app.noteModes[id] = .edit }
            }),
            ("24-calendar-no-sidebar", {
                d.app.selection = .calendar
            }),
            ("25-sidebar-back", { d.app.sidebarVisible = true }),
            // The detail panel in the smallest window, with everything long: list, tags, repeat rule, linked note.
            ("26-detail-stress", {
                d.app.selection = .calendar
                let list = d.store.addList(name: "Personal finance and investments", color: .green, icon: "banknote")
                let note = d.store.addNote(body: "# Meeting — Wednesday, 30 September with the leadership team\n\nNotes.")
                let cal = Calendar.current
                var t = TaskItem(title: "Prepare the investor update deck for the board")
                t.dueDate = cal.date(bySettingHour: 10, minute: 30, second: 0, of: cal.date(byAdding: .day, value: 2, to: Date())!)
                t.dueHasTime = true
                t.estimateMinutes = 90
                t.priority = .urgent
                t.listID = list.id
                t.tags = ["fundraising", "board", "q4-planning", "investor-relations", "follow-ups"]
                t.recurrence = Recurrence(frequency: .weekly, interval: 2, weekdays: [2, 3, 5, 6])
                t.linkedNoteID = note.id
                t.reminders = [Reminder(trigger: .beforeDue(minutes: 15), isAlarm: true),
                               Reminder(trigger: .absolute(cal.date(byAdding: .day, value: 1, to: t.dueDate!)!))]
                let added = d.store.addTask(t)
                d.mainWindow.setContentSize(NSSize(width: 980, height: 720))
                d.app.selectedTaskID = added.id
            }),
            ("27-detail-stress-bottom", { scrollDetail(in: d.mainWindow) }),
            ("28-detail-default-size", { d.mainWindow.setContentSize(NSSize(width: 1220, height: 780)) }),
            ("18-pickers-light", {
                NSApp.windows.first { $0.title == "Docket Settings" }?.close()
                showGallery(appearance: .aqua)
            }),
            ("19-pickers-dark", { showGallery(appearance: .darkAqua) }),
            ("20-settings-pages", { showGallery(appearance: .aqua, settings: d) }),
            ("17-other-appearance", {
                NSApp.windows.first { $0.title == galleryTitle }?.close()
                d.app.showPalette = false
                NSApp.windows.first { $0.title == "Docket Settings" }?.close()
                let dark = NSApp.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
                NSApp.appearance = NSAppearance(named: dark ? .aqua : .darkAqua)
                d.app.selection = .calendar
                d.app.selectedTaskID = firstTask()?.id
            }),
        ]

        let t0 = ProcessInfo.processInfo.systemUptime
        func stamp() -> String {
            let t = String(format: "%.2f", ProcessInfo.processInfo.systemUptime - t0)
            let key = NSApp.keyWindow.map { "\(Swift.type(of: $0))" } ?? "none"
            let responder = NSApp.keyWindow?.firstResponder.map { "\(Swift.type(of: $0))" } ?? "-"
            return "t=\(t) active=\(NSApp.isActive) key=\(key) responder=\(responder) palette=\(d.app.showPalette) front=\(NSWorkspace.shared.frontmostApplication?.localizedName ?? "?")"
        }
        var delay = 1.2
        for (name, action) in steps + interactive {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                if ProcessInfo.processInfo.environment["DOCKET_SNAPSHOT_TRACE"] != nil { note("step \(name) begin: \(stamp())") }
                action()
                if ProcessInfo.processInfo.environment["DOCKET_SNAPSHOT_TRACE"] != nil { note("step \(name) end:   \(stamp())") }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + delay + 0.9) {
                let panel = NSApp.windows.first { ($0 is FloatingPanel || $0.title == "Docket Settings" || $0.title == galleryTitle) && $0.isVisible }
                capture(panel ?? d.mainWindow, to: dir.appendingPathComponent("\(name).png"))
            }
            delay += 1.6
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            d.alarms.test()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + delay + 1.2) {
            if let panel = NSApp.windows.first(where: { $0 is NSPanel && $0.isVisible }) {
                capture(panel, to: dir.appendingPathComponent("10-alarm.png"))
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                d.alarms.dismiss()
                NSApp.terminate(nil)
            }
        }
    }

    /// A note exercising every rendered element, with sample media from DOCKET_SNAPSHOT_MEDIA ("photo:video").
    static func showcaseMarkdown() -> String {
        var media = ""
        if let spec = ProcessInfo.processInfo.environment["DOCKET_SNAPSHOT_MEDIA"] {
            let urls = spec.split(separator: ":").map { URL(fileURLWithPath: String($0)) }
            media = MediaLibrary.importFiles(urls).joined(separator: "\n\n")
        }
        return """
        # Q4 board update

        Revenue grew **38%** quarter on quarter, driven by *enterprise* deals. Full numbers in the [deck](https://example.com), raw data at https://docket.app/q4.

        ## Highlights
        - Closed 3 enterprise logos
        - Hired 4 engineers
          - 2 senior backend
          - 2 mobile
        - Burn down 12%

        ## Next steps
        1. Finalise pricing
        1. Ship onboarding v2
        1. Board pre-read by Friday

        - [ ] Send pre-read to the board
        - [x] Book the room

        > Focus on the two things that move revenue. Everything else waits.

        | Metric | Q3 | Q4 |
        |:-------|---:|---:|
        | ARR | $1.2M | $1.66M |
        | Customers | 41 | 57 |

        ---

        ```swift
        let growth = (1.66 - 1.2) / 1.2
        ```

        \(media)
        """
    }

    /// Scrolls the Read-mode page to some text (or to the end) so long notes can be checked.
    static func scrollReader(in window: NSWindow, to text: String?) {
        func find(_ v: NSView) -> ReaderTextView? {
            if let r = v as? ReaderTextView { return r }
            for sub in v.subviews { if let r = find(sub) { return r } }
            return nil
        }
        guard let root = window.contentView, let reader = find(root) else { return }
        if let text {
            let range = (reader.string as NSString).range(of: text)
            if range.location != NSNotFound {
                reader.scrollRangeToVisible(range)
                // Put the anchor near the top rather than the bottom of the viewport.
                if let clip = reader.enclosingScrollView?.contentView,
                   let rect = reader.layoutManager.map({ $0.boundingRect(forGlyphRange: $0.glyphRange(forCharacterRange: range, actualCharacterRange: nil), in: reader.textContainer!) }) {
                    clip.scroll(to: NSPoint(x: 0, y: max(0, rect.minY - 40)))
                    reader.enclosingScrollView?.reflectScrolledClipView(clip)
                }
            }
        } else {
            reader.scrollToEndOfDocument(nil)
        }
    }

    /// Scrolls the rightmost scroll view (the task detail panel) to its end.
    static func scrollDetail(in window: NSWindow) {
        func all(_ v: NSView) -> [NSScrollView] { ((v as? NSScrollView).map { [$0] } ?? []) + v.subviews.flatMap(all) }
        guard let root = window.contentView,
              let scroll = all(root).max(by: { $0.convert($0.bounds, to: nil).minX < $1.convert($1.bounds, to: nil).minX }),
              let doc = scroll.documentView else { return }
        let clip = scroll.contentView
        clip.scroll(to: NSPoint(x: 0, y: doc.isFlipped ? max(0, doc.frame.height - clip.bounds.height) : 0))
        scroll.reflectScrolledClipView(clip)
    }

    static let galleryTitle = "Docket Component Gallery"
    private static var gallery: NSWindow?

    /// Popover contents can't be opened from here, so they're laid out side by side in a window.
    static func showGallery(appearance: NSAppearance.Name, settings d: AppDelegate? = nil) {
        let w = gallery ?? {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1320, height: 640), styleMask: [.titled], backing: .buffered, defer: false)
            w.title = galleryTitle
            w.isReleasedWhenClosed = false
            gallery = w
            return w
        }()
        w.appearance = NSAppearance(named: appearance)
        w.backgroundColor = Palette.paper
        if let d {
            // All four Settings pages at once (the tabs can't be clicked from here).
            w.setContentSize(NSSize(width: 1280, height: 1000))
            w.contentView = NSHostingView(rootView: Grid(horizontalSpacing: 1, verticalSpacing: 1) {
                GridRow {
                    GeneralSettings().frame(width: 620, height: 490)
                    AlertSettings().frame(width: 620, height: 490)
                }
                GridRow {
                    PlannerSettings().frame(width: 620, height: 490)
                    DataSettings().frame(width: 620, height: 490)
                }
            }
            .background(Color.hair)
            .environmentObject(d.store)
            .environmentObject(d.app)
            .environmentObject(d.alarms)
            .environmentObject(d.calendarService)
            .environmentObject(d.notifications)
            .tint(Color.ink))
        } else {
            w.setContentSize(NSSize(width: 1320, height: 640))
            w.contentView = NSHostingView(rootView: ComponentGallery())
        }
        w.center()
        w.orderFrontRegardless()
    }

    static func capture(_ window: NSWindow, to url: URL) {
        guard let view = window.contentView?.superview ?? window.contentView,
              let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
        // Real on-screen pixels (vibrancy and AppKit-backed lists don't show up in cacheDisplay).
        let shot = Process()
        shot.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        if window is FloatingPanel, let primary = NSScreen.screens.first {
            // Translucent panels: capture the screen area so the blurred background is included.
            let f = window.frame.insetBy(dx: -24, dy: -24)
            let rect = "\(Int(f.minX)),\(Int(primary.frame.height - f.maxY)),\(Int(f.width)),\(Int(f.height))"
            shot.arguments = ["-x", "-R\(rect)", url.deletingPathExtension().path + "-screen.png"]
        } else {
            shot.arguments = ["-x", "-o", "-l\(window.windowNumber)", url.deletingPathExtension().path + "-screen.png"]
        }
        try? shot.run()
        // Also record the window number so the shell can use `screencapture -l` if needed.
        let ids = dirFile(url.deletingLastPathComponent())
        let line = "\(url.lastPathComponent) \(window.windowNumber)\n"
        if let h = try? FileHandle(forWritingTo: ids) {
            h.seekToEndOfFile()
            h.write(line.data(using: .utf8)!)
            try? h.close()
        } else {
            try? line.write(to: ids, atomically: true, encoding: .utf8)
        }
    }

    /// Posts synthetic key presses to a window (no Accessibility permission needed for our own windows).
    static func type(_ text: String, into window: NSWindow) {
        for ch in text {
            let chars = String(ch)
            let code: UInt16 = chars == "\r" ? 36 : 0
            for type in [NSEvent.EventType.keyDown, .keyUp] {
                if let e = NSEvent.keyEvent(with: type, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                            windowNumber: window.windowNumber, context: nil, characters: chars,
                                            charactersIgnoringModifiers: chars, isARepeat: false, keyCode: code) {
                    NSApp.postEvent(e, atStart: false)
                }
            }
        }
    }

    private static func dirFile(_ dir: URL) -> URL { dir.appendingPathComponent("windows.txt") }
}

/// Snapshot-only: the popovers' contents, framed like popovers.
private struct ComponentGallery: View {
    private static let cal = Calendar.current
    @State private var deadline: Date? = cal.date(bySettingHour: 17, minute: 0, second: 0, of: Date())
    @State private var deadlineHasTime = true
    @State private var plan: Date? = cal.date(byAdding: .day, value: 1, to: cal.startOfDay(for: Date()))
    @State private var reminder: Date? = cal.date(byAdding: .hour, value: 2, to: Date())

    var body: some View {
        HStack(alignment: .top, spacing: 20) {
            framed(DatePopover(date: $deadline, hasTime: $deadlineHasTime, allowsTime: true, title: "Deadline", close: {}))
            framed(DatePopover(date: $plan, hasTime: .constant(false), allowsTime: false, title: "Do on", close: {}))
            framed(DatePopover(date: $reminder, hasTime: .constant(true), allowsTime: true, title: "Remind me at", timeRequired: true,
                               confirmLabel: "Add reminder", close: {}, onConfirm: {}))
            framed(CustomRepeatEditor(initial: Recurrence(frequency: .weekly, weekdays: [2, 4]), onSave: { _ in }))
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color.paper)
    }

    private func framed<V: View>(_ v: V) -> some View {
        v.clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.hairStrong))
            .shadow(color: .black.opacity(0.12), radius: 12, y: 4)
    }
}
