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
        alarms.store = store
        alarms.app = app
        alarms.focus = focus

        app.showMainWindow = { [weak self] in self?.showMainWindow() }
        app.showSettings = { [weak self] in self?.showSettings() }
        app.showQuickCapture = { [weak self] in self?.quickCapture.toggle() }

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

    /// Arrow keys move through tasks and notes, Esc closes the detail,
    /// Delete removes the selected task. Never while typing.
    private func handleKey(_ event: NSEvent) -> Bool {
        guard event.window === mainWindow, !app.showPalette, !(mainWindow.firstResponder is NSText) else { return false }
        let mods = event.modifierFlags.intersection([.command, .option, .control, .shift])
        guard mods.isEmpty else { return false }
        switch event.keyCode {
        case 125, 126: // down, up
            let delta = event.keyCode == 125 ? 1 : -1
            if app.selection == .notes {
                app.moveNoteSelection(by: delta, in: store)
            } else if app.selection.isTaskView {
                app.moveSelection(by: delta, in: store)
            } else {
                return false
            }
            return true
        case 53: // esc
            guard app.selectedTaskID != nil else { return false }
            withAnimation(Motion.sheet) { app.selectedTaskID = nil }
            return true
        case 51, 117: // delete, forward delete
            guard app.selection.isTaskView, let id = app.selectedTaskID else { return false }
            app.moveSelection(by: 1, in: store)
            if app.selectedTaskID == id { app.selectedTaskID = nil }
            withAnimation(Motion.base) { store.deleteTasks([id]) }
            return true
        default:
            return false
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
        if !app.selection.isTaskView { app.selection = .inbox }
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

    @objc func go(_ sender: NSMenuItem) {
        let targets: [SidebarItem] = [.calendar, .inbox, .notes, .important, .all, .completed, .insights]
        guard targets.indices.contains(sender.tag) else { return }
        showMainWindow()
        app.selection = targets[sender.tag]
    }

    private var selectedTask: TaskItem? {
        guard app.selection.isTaskView, mainWindow.isKeyWindow else { return nil }
        return store.task(app.selectedTaskID)
    }

    @objc func completeSelected(_ sender: Any?) {
        guard let t = selectedTask else { return }
        app.toggle(t.id, in: store)
    }

    @objc func planToday(_ sender: Any?) {
        guard let t = selectedTask else { return }
        store.setScheduled(t.id, Date())
    }

    @objc func planTomorrow(_ sender: Any?) {
        guard let t = selectedTask else { return }
        store.pushToTomorrow(t.id)
    }

    @objc func focusSelected(_ sender: Any?) {
        guard let t = selectedTask else { return }
        focus.start(taskID: t.id, minutes: t.remainingMinutes > 0 ? t.remainingMinutes : Prefs.focusMinutes)
    }

    @objc func moveSelectedUp(_ sender: Any?) { moveSelected(by: -1) }
    @objc func moveSelectedDown(_ sender: Any?) { moveSelected(by: 1) }

    private func moveSelected(by delta: Int) {
        guard let t = selectedTask else { return }
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
        guard let t = selectedTask, let p = Priority(rawValue: sender.tag) else { return }
        store.mutateTask(t.id, undo: "Set Priority") { $0.priority = p }
    }

    @objc func deleteSelected(_ sender: Any?) {
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
        switch item.action {
        case #selector(moveSelectedUp(_:)), #selector(moveSelectedDown(_:)):
            return app.selection == .calendar && selectedTask.map { !$0.isCompleted } == true
        case #selector(completeSelected(_:)), #selector(planToday(_:)), #selector(planTomorrow(_:)),
             #selector(focusSelected(_:)), #selector(setPriority(_:)), #selector(deleteSelected(_:)):
            if item.action == #selector(completeSelected(_:)) {
                item.title = selectedTask?.isCompleted == true ? "Mark as Not Done" : "Mark as Done"
            }
            if item.action == #selector(setPriority(_:)) {
                item.state = selectedTask?.priority.rawValue == item.tag ? .on : .off
            }
            // ⌘⌫ must keep deleting text while typing, never the task being edited.
            if item.action == #selector(deleteSelected(_:)), mainWindow.firstResponder is NSText { return false }
            return selectedTask != nil
        default:
            return true
        }
    }
}
