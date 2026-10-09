import AppKit
import Combine
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, NSMenuItemValidation {
    let store = Store()
    let app = AppState()
    let focus = FocusTimer()
    let alarms = AlarmService()
    let notifications = NotificationService.shared
    let calendarService = CalendarService.shared

    private(set) var mainWindow: NSWindow!
    private var settingsWindow: NSWindow?
    private var statusItem: StatusItemController!
    private var quickCapture: QuickCaptureController!
    private var cancellables = Set<AnyCancellable>()
    private var clockTimer: Timer?
    private var keyMonitor: Any?
    private var appliedPrefs = ""

    // MARK: Launch

    func applicationDidFinishLaunching(_ notification: Notification) {
        MediaLibrary.dataDirectory = store.persistence.directory
        // Only after a clean load: a fresh or recovered store doesn't hold the notes the photos belong to.
        if store.loadMessage == nil && !store.isFirstLaunch {
            let bodies = store.notes.map(\.body)
            DispatchQueue.global(qos: .utility).async { MediaLibrary.collectGarbage(noteBodies: bodies) }
        }

        focus.store = store
        focus.alarms = alarms
        // New-message notifications wait for a focus session to end.
        Integrations.shared.isFocusing = { [weak focus] in focus?.isActive ?? false }
        alarms.store = store
        alarms.app = app
        alarms.focus = focus

        app.showMainWindow = { [weak self] in self?.showMainWindow() }
        app.showSettings = { [weak self] in self?.showSettings() }
        app.showQuickCapture = { [weak self] in self?.quickCapture.toggle() }

        // Before any window reads a secret: screenshot mode never touches the secrets file or the network.
        if DebugSnapshot.isActive { Keychain.useInMemoryStore() } else { Integrations.shared.start(store: store, app: app) }

        // Docket doesn't use window tabs (this also keeps tab items out of the View menu).
        NSWindow.allowsAutomaticWindowTabbing = false
        NSApp.mainMenu = MainMenu.build(target: self)
        makeMainWindow()
        statusItem = StatusItemController(delegate: self)
        quickCapture = QuickCaptureController(delegate: self)
        HotKeyCenter.shared.action = { [weak self] in self?.quickCapture.toggle() }

        if !DebugSnapshot.isActive { notifications.setUp(store: store, app: app) }
        alarms.start()
        calendarService.start()

        // React to data changes: notifications, badge, menu bar count.
        store.objectWillChange
            .debounce(for: .milliseconds(400), scheduler: RunLoop.main)
            .sink { [weak self] _ in self?.dataChanged() }
            .store(in: &cancellables)
        focus.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.statusItem.refresh() }
            .store(in: &cancellables)
        // New messages put a dot on the menu bar icon; handling them takes it off.
        Integrations.shared.$newMessageIDs.combineLatest(Integrations.shared.$suggestions)
            .debounce(for: .milliseconds(200), scheduler: RunLoop.main)
            .sink { [weak self] _ in self?.statusItem.refresh() }
            .store(in: &cancellables)
        NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)
            .debounce(for: .milliseconds(300), scheduler: RunLoop.main)
            .sink { [weak self] _ in self?.applyPreferences() }
            .store(in: &cancellables)
        NotificationCenter.default.publisher(for: .NSCalendarDayChanged)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.minuteTick() }
            .store(in: &cancellables)
        NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didWakeNotification)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.minuteTick() }
            .store(in: &cancellables)

        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            self?.handleKey(event) == true ? nil : event
        }

        let timer = Timer(timeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.minuteTick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        clockTimer = timer

        applyPreferences(force: true)
        dataChanged()

        if !DebugSnapshot.isActive || ProcessInfo.processInfo.environment["DOCKET_SNAPSHOT_SHOW"] != nil {
            showMainWindow()
        }
        DebugSnapshot.runIfRequested(self)
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showMainWindow()
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationWillTerminate(_ notification: Notification) {
        focus.stop(markDone: false)
        alarms.persist()
        store.saveNow()
    }

    /// The main window's keys, never while typing. Arrows move through tasks and notes (⇧ grows the
    /// selection), ⌘A selects every open task in view, Return opens or closes the details, Esc drops a
    /// multi-selection and then closes the details, Delete removes the selected tasks, and t / m / w / x
    /// move them to today / tomorrow / next Monday or tick them off.
    private func handleKey(_ event: NSEvent) -> Bool {
        guard event.window === mainWindow, !app.showPalette, !(mainWindow.firstResponder is NSText) else { return false }
        let mods = event.modifierFlags.intersection([.command, .option, .control, .shift])
        let inTasks = app.selection.isTaskView
        let isArrow = event.keyCode == 125 || event.keyCode == 126
        let key = event.charactersIgnoringModifiers?.lowercased() ?? ""

        if mods == .command, key == "a" {
            return inTasks && app.selectAllVisible(in: store)
        }
        if mods == .shift, isArrow {
            return inTasks && app.extendSelection(by: event.keyCode == 125 ? 1 : -1, in: store)
        }
        guard mods.isEmpty else { return false }
        switch event.keyCode {
        case 125, 126: // down, up
            let delta = event.keyCode == 125 ? 1 : -1
            if app.selection == .notes {
                app.moveNoteSelection(by: delta, in: store)
                return true
            }
            return inTasks && app.moveSelection(by: delta, in: store)
        case 53: // esc
            if app.collapseSelection() { return true }
            guard app.selectedTaskID != nil else { return false }
            withAnimation(Motion.sheet) { app.selectedTaskID = nil }
            return true
        case 51, 117: // delete, forward delete
            // Deleting moves on to the next task, so a held key would run down the list deleting each one.
            return inTasks && (event.isARepeat || app.deleteSelection(in: store))
        case 36, 76: // return, enter
            guard inTasks else { return false }
            // Holding Return doesn't flap the details open and shut.
            return event.isARepeat || app.toggleDetail(in: store)
        default:
            guard inTasks else { return false }
            let action: AppState.Triage
            switch key {
            case "t": action = .move(.today)
            case "m": action = .move(.tomorrow)
            case "w": action = .move(.nextWeek)
            case "x": action = .done
            default: return false
            }
            // One press, one change: a held key mustn't run on down the list, ticking off task after task.
            return event.isARepeat || app.triage(action, in: store)
        }
    }

    // MARK: Windows

    private func makeMainWindow() {
        let root = RootView()
            .environmentObject(store)
            .environmentObject(app)
            .environmentObject(focus)
            .environmentObject(alarms)
            .environmentObject(calendarService)
            .environmentObject(notifications)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1220, height: 780),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered, defer: false
        )
        window.title = "Docket"
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isReleasedWhenClosed = false
        window.tabbingMode = .disallowed
        window.minSize = NSSize(width: 980, height: 600)
        window.backgroundColor = Palette.paper
        let host = NSHostingView(rootView: root)
        host.sizingOptions = [.minSize]
        window.contentView = host
        let toggle = NSTitlebarAccessoryViewController()
        toggle.layoutAttribute = .left
        let toggleHost = NSHostingView(rootView: SidebarToggle().environmentObject(app))
        toggleHost.frame = NSRect(x: 0, y: 0, width: 40, height: 28)
        toggle.view = toggleHost
        window.addTitlebarAccessoryViewController(toggle)
        window.center()
        window.setFrameAutosaveName("DocketMainWindow")
        window.delegate = self
        mainWindow = window
        store.undoManager = window.undoManager
    }

    func showMainWindow() {
        if Prefs.hideDockIcon { NSApp.setActivationPolicy(.regular) }
        mainWindow.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func windowWillClose(_ notification: Notification) {
        guard (notification.object as? NSWindow) === mainWindow, Prefs.hideDockIcon else { return }
        // Menu-bar-only mode: drop the Dock icon again once the window is gone.
        DispatchQueue.main.async { NSApp.setActivationPolicy(.accessory) }
    }

    func showSettings() {
        if settingsWindow == nil {
            let view = SettingsView()
                .environmentObject(store)
                .environmentObject(app)
                .environmentObject(alarms)
                .environmentObject(calendarService)
                .environmentObject(notifications)
            let w = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 620, height: 560),
                styleMask: [.titled, .closable],
                backing: .buffered, defer: false
            )
            w.title = "Docket Settings"
            w.isReleasedWhenClosed = false
            w.contentView = NSHostingView(rootView: view)
            w.center()
            settingsWindow = w
        }
        notifications.refreshStatus()
        settingsWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    // MARK: Reactions

    private func dataChanged() {
        notifications.reschedule()
        updateBadge()
        statusItem.refresh()
    }

    private func minuteTick() {
        // After midnight, a month view still sitting on "today" follows the date.
        let previousDay = Calendar.current.startOfDay(for: app.clock)
        app.clock = Date()
        if app.selectedDay == previousDay { app.selectedDay = Calendar.current.startOfDay(for: app.clock) }
        calendarService.refresh()
        updateBadge()
        statusItem.refresh()
    }

    private func updateBadge() {
        guard Prefs.dockBadge else {
            NSApp.dockTile.badgeLabel = nil
            return
        }
        let count = store.todayTasks().count
        NSApp.dockTile.badgeLabel = count > 0 ? "\(count)" : nil
    }

    private func applyPreferences(force: Bool = false) {
        let signature = [
            "\(Prefs.hotkeyEnabled)", Prefs.hotkeyPreset.rawValue, "\(Prefs.showMenuBar)", "\(Prefs.menuBarShowsCount)",
            "\(Prefs.dockBadge)", "\(Prefs.hideDockIcon)", "\(Prefs.briefingEnabled)", "\(Prefs.briefingMinutes)",
            "\(Prefs.allDayHour)", "\(Prefs.useCalendar)", "\(Prefs.workdayStart)", "\(Prefs.workdayEnd)", Prefs.alarmSound.rawValue,
            Prefs.appearance.rawValue,
        ].joined(separator: "|")
        guard force || signature != appliedPrefs else { return }
        appliedPrefs = signature

        // Every window (main, settings, menu bar dropdown, quick capture, alarm) inherits this.
        switch Prefs.appearance {
        case .system: NSApp.appearance = nil
        case .light: NSApp.appearance = NSAppearance(named: .aqua)
        case .dark: NSApp.appearance = NSAppearance(named: .darkAqua)
        }

        if Prefs.hotkeyEnabled {
            app.hotkeyRegistered = HotKeyCenter.shared.register(Prefs.hotkeyPreset)
        } else {
            HotKeyCenter.shared.unregister()
            app.hotkeyRegistered = false
        }
        statusItem.setVisible(Prefs.showMenuBar)
        statusItem.refresh()
        if Prefs.hideDockIcon {
            if !mainWindow.isVisible { NSApp.setActivationPolicy(.accessory) }
        } else {
            NSApp.setActivationPolicy(.regular)
        }
        calendarService.refresh()
        updateBadge()
        notifications.reschedule()
        app.clock = Date()
    }

    // MARK: Menu actions

    @objc func newTask(_ sender: Any?) {
        showMainWindow()
        // Search results have no quick-add field.
        if !app.selection.isTaskView || app.selection == .search { app.selection = .inbox }
        app.focusQuickAdd += 1
    }

    @objc func newNote(_ sender: Any?) {
        let note = store.addNote(body: "")
        app.reveal(note: note.id)
    }

    @objc func newNoteFromClipboard(_ sender: Any?) {
        app.newNoteFromClipboard(store)
    }

    @objc func dailyNote(_ sender: Any?) {
        app.reveal(note: store.dailyNote().id)
    }

    @objc func quickCaptureAction(_ sender: Any?) { quickCapture.toggle() }
    @objc func showSettingsAction(_ sender: Any?) { showSettings() }
    @objc func showMainWindowAction(_ sender: Any?) { showMainWindow() }
    @objc func toggleSidebar(_ sender: Any?) {
        showMainWindow()
        app.toggleSidebar()
    }

    @objc func commandPalette(_ sender: Any?) {
        showMainWindow()
        app.showPalette = true
    }

    /// ⌘F. In a note (editor or reader) it opens that note's find bar; anywhere else it puts the
    /// cursor in the sidebar search field, which searches every task and note.
    @objc func searchAction(_ sender: Any?) {
        if mainWindow.isKeyWindow, let textView = mainWindow.firstResponder as? NSTextView, !textView.isFieldEditor {
            let find = NSMenuItem(title: "", action: #selector(NSTextView.performFindPanelAction(_:)), keyEquivalent: "")
            find.tag = NSTextFinder.Action.showFindInterface.rawValue
            // A text view without a find bar can't search itself; search everything instead.
            if textView.validateUserInterfaceItem(find) {
                textView.performFindPanelAction(find)
                return
            }
        }
        showMainWindow()
        app.beginSearch()
    }

    @objc func toggleCompactRows(_ sender: Any?) {
        withAnimation(Motion.snappy) { app.compactRows.toggle() }
    }

    @objc func planWithAI(_ sender: Any?) {
        showMainWindow()
        // Already open: keep what's been typed there.
        if app.aiPlanner == nil { app.aiPlanner = AIPlannerRequest() }
    }

    @objc func go(_ sender: NSMenuItem) {
        // Same order as the Go menu (⌘1…⌘9).
        let targets: [SidebarItem] = [.calendar, .inbox, .notes, .important, .all, .completed, .insights, .waiting, .suggestions]
        guard targets.indices.contains(sender.tag) else { return }
        showMainWindow()
        app.selection = targets[sender.tag]
    }

    private var selectedTask: TaskItem? {
        guard app.selection.isTaskView, mainWindow.isKeyWindow else { return nil }
        return store.task(app.selectedTaskID)
    }

    /// Several tasks selected in the main window: Task menu commands apply to all of them.
    private var selectedTasks: [UUID]? {
        guard app.isMultiSelecting, app.selection.isTaskView, mainWindow.isKeyWindow else { return nil }
        let ids = app.actionTargets(in: store)
        return ids.isEmpty ? nil : ids
    }

    /// The tasks a Task menu item would act on, for validating it (cheap: no list order needed).
    private var menuTargets: [TaskItem] {
        guard app.selection.isTaskView, mainWindow.isKeyWindow else { return [] }
        guard app.isMultiSelecting else { return selectedTask.map { [$0] } ?? [] }
        return store.tasks.filter { app.selectedTaskIDs.contains($0.id) }
    }

    @objc func completeSelected(_ sender: Any?) {
        if let ids = selectedTasks {
            app.toggleDone(ids, in: store)
            app.deselectAll()
            return
        }
        guard let t = selectedTask else { return }
        app.toggle(t.id, in: store)
    }

    @objc func planToday(_ sender: Any?) {
        if let ids = selectedTasks { return app.plan(ids, on: Date(), in: store) }
        guard let t = selectedTask else { return }
        store.setScheduled(t.id, Date())
    }

    @objc func planTomorrow(_ sender: Any?) {
        if let ids = selectedTasks { return app.pushToTomorrow(ids, in: store) }
        guard let t = selectedTask else { return }
        store.pushToTomorrow(t.id)
    }

    @objc func focusSelected(_ sender: Any?) {
        guard !app.isMultiSelecting, let t = selectedTask else { return }
        focus.start(taskID: t.id, minutes: t.remainingMinutes > 0 ? t.remainingMinutes : Prefs.focusMinutes)
    }

    /// Edit ▸ Select All when no text is being edited: every open task in the view.
    @objc func selectAll(_ sender: Any?) {
        guard mainWindow.isKeyWindow, app.selectAllVisible(in: store) else { return NSSound.beep() }
    }

    @objc func moveSelectedUp(_ sender: Any?) { moveSelected(by: -1) }
    @objc func moveSelectedDown(_ sender: Any?) { moveSelected(by: 1) }

    private func moveSelected(by delta: Int) {
        guard !app.isMultiSelecting, let t = selectedTask else { return }
        let moved = withAnimation(Motion.gentle) { store.moveInDay(t.id, by: delta, now: app.clock) }
        if !moved {
            if store.dayList(containing: t.id, now: app.clock) == nil {
                app.showToast("Tasks with a time stay in time order")
            } else {
                NSSound.beep()
            }
        }
    }

    @objc func setPriority(_ sender: NSMenuItem) {
        guard let p = Priority(rawValue: sender.tag) else { return }
        if let ids = selectedTasks { return app.setPriority(p, for: ids, in: store) }
        guard let t = selectedTask else { return }
        store.mutateTask(t.id, undo: "Set Priority") { $0.priority = p }
    }

    @objc func deleteSelected(_ sender: Any?) {
        if let ids = selectedTasks {
            return app.delete(ids, in: store) { [weak self] in self?.app.deselectAll() }
        }
        guard let t = selectedTask else { return }
        store.deleteTasks([t.id])
        app.selectedTaskID = nil
    }

    @objc func exportData(_ sender: Any?) { DataTransfer.export(store: store) }
    @objc func importData(_ sender: Any?) { DataTransfer.import(store: store) }

    @objc func showGuide(_ sender: Any?) {
        let existing = store.notes.first { $0.body.hasPrefix("# Welcome to Docket") }
        app.reveal(note: (existing ?? store.addNote(body: NoteTemplate.guideBody)).id)
    }

    func debugShowMenuBarPanel() { statusItem.debugShow() }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        if item.action == #selector(toggleSidebar(_:)) {
            item.title = app.sidebarVisible ? "Hide Sidebar" : "Show Sidebar"
            return true
        }
        if item.action == #selector(toggleCompactRows(_:)) {
            item.state = app.compactRows ? .on : .off
            return true
        }
        switch item.action {
        case #selector(selectAll(_:)):
            // The month grid has no rows to select.
            return mainWindow.isKeyWindow && app.selection.isTaskView && !(app.selection == .calendar && app.calendarMode == .month)
        case #selector(moveSelectedUp(_:)), #selector(moveSelectedDown(_:)):
            return app.selection == .calendar && !app.isMultiSelecting && selectedTask.map { !$0.isCompleted } == true
        case #selector(focusSelected(_:)):
            return !app.isMultiSelecting && selectedTask != nil
        case #selector(completeSelected(_:)), #selector(planToday(_:)), #selector(planTomorrow(_:)),
             #selector(setPriority(_:)), #selector(deleteSelected(_:)):
            // With several tasks selected these act on all of them.
            let targets = menuTargets
            if item.action == #selector(completeSelected(_:)) {
                item.title = !targets.isEmpty && targets.allSatisfy(\.isCompleted) ? "Mark as Not Done" : "Mark as Done"
            }
            if item.action == #selector(setPriority(_:)) {
                let matching = targets.filter { $0.priority.rawValue == item.tag }.count
                item.state = targets.isEmpty || matching == 0 ? .off : (matching == targets.count ? .on : .mixed)
            }
            if item.action == #selector(deleteSelected(_:)) {
                item.title = targets.count > 1 ? "Delete \(targets.count) Tasks" : "Delete Task"
                // ⌘⌫ must keep deleting text while typing, never the task being edited.
                if mainWindow.firstResponder is NSText { return false }
            }
            return !targets.isEmpty
        default:
            return true
        }
    }
}
