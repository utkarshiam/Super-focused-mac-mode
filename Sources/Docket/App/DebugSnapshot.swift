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
        // Same size every run (the stress step shrinks it, and the frame is autosaved), same Settings page.
        d.mainWindow.setContentSize(NSSize(width: 1220, height: 780))
        UserDefaults.standard.set(SettingsView.Tab.general.rawValue, forKey: SettingsView.tabKey)
        d.app.compactRows = false

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
            // Compact rows, multi-select, search, AI planning, Slack & Gmail, delegation, slipping, celebration.
            ("30-compact", {
                d.app.selection = .calendar
                d.app.selectedTaskID = nil
                d.app.compactRows = true
            }),
            ("31-compact-detail", { d.app.selectedTaskID = firstTask()?.id }),
            ("32-multiselect", {
                d.app.compactRows = false
                let ids = d.store.timeline(keeping: [], now: d.app.clock).compactMap { $0.item.task?.id }
                d.app.selectedTaskID = ids.first
                d.app.selectedTaskIDs = Set(ids.prefix(3))
            }),
            ("33-search", {
                d.app.selectionBeforeSearch = .calendar
                d.app.searchText = "board"
                d.app.selection = .search
            }),
            ("34-ai-plan", {
                d.app.searchText = ""
                d.app.selection = .calendar
                d.app.aiPlanner = AIPlannerRequest(
                    text: "Board meeting Thursday 10am. Deck done by Wednesday, dry run with Sam before that. Book flights to NYC for the offsite.",
                    drafts: [
                        TaskDraft(title: "Finish the board deck", due: day(3), estimateMinutes: 120, priority: .high, listName: "Work",
                                  subtasks: ["Update the metrics", "Write the ask", "Send to Sam for review"], reason: "Due before Thursday's board meeting"),
                        TaskDraft(title: "Dry run the deck with Sam", due: day(2, hour: 15), dueHasTime: true, estimateMinutes: 45,
                                  priority: .medium, listName: "Work", reason: "Before the deck is final"),
                        TaskDraft(title: "Board meeting", due: day(4, hour: 10), dueHasTime: true, estimateMinutes: 90, priority: .high, listName: "Work"),
                        TaskDraft(title: "Book flights to NYC for the offsite", estimateMinutes: 20, listName: "Personal", reason: "No date given"),
                    ])
            }),
            ("35-inbox-slack", {
                d.app.aiPlanner = nil
                UserDefaults.standard.set(TaskSource.Kind.slack.rawValue, forKey: SuggestionsView.tabKey)
                let files = sampleAttachments(in: dir)
                Integrations.shared.debugSeed(imageFile: files.image, documentFile: files.document, now: Date())
                d.app.selection = .suggestions
            }),
            ("35b-inbox-email", { UserDefaults.standard.set(TaskSource.Kind.gmail.rawValue, forKey: SuggestionsView.tabKey) }),
            ("35c-inbox-all", { UserDefaults.standard.set("all", forKey: SuggestionsView.tabKey) }),
            ("35d-menubar-messages", { d.debugShowMenuBarPanel() }),
            ("36-waiting", {
                var sow = TaskItem(title: "Get the signed SOW back from Northwind")
                sow.waitingOn = "Priya"
                sow.dueDate = day(2)
                d.store.addTask(sow)
                var plan = TaskItem(title: "Feedback on the hiring plan")
                plan.waitingOn = "Sam"
                plan.scheduledDate = day(1)
                d.store.addTask(plan)
                d.app.selection = .waiting
            }),
            ("37-slipping", {
                var late = TaskItem(title: "Write the hiring plan")
                late.dueDate = day(-2)
                late.postponeCount = 4
                late.estimateMinutes = 60
                let added = d.store.addTask(late)
                d.app.selection = .calendar
                d.app.selectedTaskID = added.id
            }),
            ("38-celebration", {
                d.app.selectedTaskID = nil
                UserDefaults.standard.removeObject(forKey: DayClear.lastCelebratedKey)
                Celebration.shared.dayCleared(app: d.app)
            }),
            ("39-settings-ai", {
                UserDefaults.standard.set(SettingsView.Tab.ai.rawValue, forKey: SettingsView.tabKey)
                d.showSettings()
            }),
            ("40-settings-connections", { UserDefaults.standard.set(SettingsView.Tab.connections.rawValue, forKey: SettingsView.tabKey) }),
            // The setup guide from scratch: nothing connected yet.
            ("41-setup-fresh", {
                Integrations.shared.disconnectSlack()
                Integrations.shared.disconnectGmail()
            }),
            ("18-pickers-light", {
                NSApp.windows.first { $0.title == "Docket Settings" }?.close()
                UserDefaults.standard.set(SettingsView.Tab.general.rawValue, forKey: SettingsView.tabKey)
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
        // DOCKET_SNAPSHOT_STEP slows the walk-through (seconds per screen) so animations settle before capture.
        let step = max(1.6, Double(ProcessInfo.processInfo.environment["DOCKET_SNAPSHOT_STEP"] ?? "") ?? 1.6)
        // Capture a little past halfway, so animations have settled and the capture (screencapture takes a
        // moment to start) is done before the next step changes the screen.
        let settle = min(step - 0.7, max(0.9, step * 0.55))
        var delay = 1.2
        for (name, action) in steps + interactive {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                if ProcessInfo.processInfo.environment["DOCKET_SNAPSHOT_TRACE"] != nil { note("step \(name) begin: \(stamp())") }
                action()
                if ProcessInfo.processInfo.environment["DOCKET_SNAPSHOT_TRACE"] != nil { note("step \(name) end:   \(stamp())") }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + delay + settle) {
                let panel = NSApp.windows.first { ($0 is FloatingPanel || $0.title == "Docket Settings" || $0.title == galleryTitle) && $0.isVisible }
                capture(panel ?? d.mainWindow, to: dir.appendingPathComponent("\(name).png"))
            }
            delay += step
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

    /// Neutral sample attachments for the inbox screenshots: a small bar chart and a CSV, made here so the
    /// published screenshots contain nothing that isn't ours.
    static func sampleAttachments(in dir: URL) -> (image: URL?, document: URL?) {
        let imageURL = dir.appendingPathComponent("q3-revenue-chart.png")
        let size = NSSize(width: 960, height: 600)
        let image = NSImage(size: size, flipped: false) { rect in
            NSColor(srgbRed: 0.984, green: 0.984, blue: 0.976, alpha: 1).setFill()
            rect.fill()
            let values: [CGFloat] = [0.38, 0.46, 0.52, 0.61, 0.70, 0.83]
            let barWidth: CGFloat = 96, gap: CGFloat = 44, base: CGFloat = 70
            for (i, v) in values.enumerated() {
                let x = 90 + CGFloat(i) * (barWidth + gap)
                let bar = NSRect(x: x, y: base, width: barWidth, height: (rect.height - 160) * v)
                (i == values.count - 1 ? NSColor(srgbRed: 0.055, green: 0.055, blue: 0.047, alpha: 1)
                                       : NSColor(srgbRed: 0.80, green: 0.79, blue: 0.76, alpha: 1)).setFill()
                NSBezierPath(roundedRect: bar, xRadius: 10, yRadius: 10).fill()
            }
            NSColor(srgbRed: 0.88, green: 0.87, blue: 0.84, alpha: 1).setFill()
            NSRect(x: 60, y: base - 2, width: rect.width - 120, height: 2).fill()
            return true
        }
        if let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
           let png = rep.representation(using: .png, properties: [:]) {
            try? png.write(to: imageURL)
        }
        let csvURL = dir.appendingPathComponent("Q3 board numbers.csv")
        try? "Metric,Q2,Q3\nARR,$1.20M,$1.66M\nCustomers,41,57\nNet retention,112%,118%\n".write(to: csvURL, atomically: true, encoding: .utf8)
        return (FileManager.default.fileExists(atPath: imageURL.path) ? imageURL : nil, csvURL)
    }

    /// Start of the day `offset` days from today, optionally at an hour.
    static func day(_ offset: Int, hour: Int? = nil) -> Date {
        let cal = Calendar.current
        let d = cal.date(byAdding: .day, value: offset, to: cal.startOfDay(for: Date()))!
        return hour.flatMap { cal.date(bySettingHour: $0, minute: 0, second: 0, of: d) } ?? d
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
        // The window alone (panels are solid now), so nothing else on screen ever ends up in a screenshot.
        shot.arguments = ["-x", "-o", "-l\(window.windowNumber)", url.deletingPathExtension().path + "-screen.png"]
        try? shot.run()
        // A sheet (Plan with AI, Connect…) is its own window: save it on its own too.
        if let sheet = window.attachedSheet {
            let sheetShot = Process()
            sheetShot.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
            sheetShot.arguments = ["-x", "-o", "-l\(sheet.windowNumber)", url.deletingPathExtension().path + "-sheet.png"]
            try? sheetShot.run()
        }
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
