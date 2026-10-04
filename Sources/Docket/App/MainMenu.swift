import AppKit

enum MainMenu {
    @MainActor
    static func build(target: AppDelegate) -> NSMenu {
        let main = NSMenu()

        func item(_ title: String, _ action: Selector?, _ key: String = "", _ mods: NSEvent.ModifierFlags = .command, tag: Int = 0, toDelegate: Bool = true) -> NSMenuItem {
            let i = NSMenuItem(title: title, action: action, keyEquivalent: key)
            i.keyEquivalentModifierMask = mods
            i.tag = tag
            if toDelegate { i.target = target }
            return i
        }

        func submenu(_ title: String, _ items: [NSMenuItem]) -> NSMenuItem {
            let menu = NSMenu(title: title)
            items.forEach(menu.addItem)
            let holder = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            holder.submenu = menu
            main.addItem(holder)
            return holder
        }

        // App
        let services = NSMenuItem(title: "Services", action: nil, keyEquivalent: "")
        let servicesMenu = NSMenu()
        services.submenu = servicesMenu
        NSApp.servicesMenu = servicesMenu
        _ = submenu("Docket", [
            item("About Docket", #selector(NSApplication.orderFrontStandardAboutPanel(_:)), toDelegate: false),
            .separator(),
            item("Settings…", #selector(AppDelegate.showSettingsAction(_:)), ","),
            .separator(),
            services,
            .separator(),
            item("Hide Docket", #selector(NSApplication.hide(_:)), "h", toDelegate: false),
            item("Hide Others", #selector(NSApplication.hideOtherApplications(_:)), "h", [.command, .option], toDelegate: false),
            item("Show All", #selector(NSApplication.unhideAllApplications(_:)), toDelegate: false),
            .separator(),
            item("Quit Docket", #selector(NSApplication.terminate(_:)), "q", toDelegate: false),
        ])

        // File
        _ = submenu("File", [
            item("New Task", #selector(AppDelegate.newTask(_:)), "n"),
            item("New Note", #selector(AppDelegate.newNote(_:)), "n", [.command, .shift]),
            item("New Note from Clipboard", #selector(AppDelegate.newNoteFromClipboard(_:)), "v", [.command, .option]),
            item("Today's Daily Note", #selector(AppDelegate.dailyNote(_:)), "d"),
            item("Quick Capture…", #selector(AppDelegate.quickCaptureAction(_:))),
            .separator(),
            item("Import Data…", #selector(AppDelegate.importData(_:))),
            item("Export Data…", #selector(AppDelegate.exportData(_:))),
            .separator(),
            item("Close Window", #selector(NSWindow.performClose(_:)), "w", toDelegate: false),
        ])

        // Edit — standard responder-chain actions so text fields get copy/paste/undo.
        let find = NSMenu(title: "Find")
        for (title, key, tag, mods) in [("Find…", "f", 1, NSEvent.ModifierFlags.command), ("Find Next", "g", 2, .command),
                                        ("Find Previous", "g", 3, [.command, .shift])] {
            find.addItem(item(title, #selector(NSTextView.performFindPanelAction(_:)), key, mods, tag: tag, toDelegate: false))
        }
        let findHolder = NSMenuItem(title: "Find", action: nil, keyEquivalent: "")
        findHolder.submenu = find
        _ = submenu("Edit", [
            item("Undo", Selector(("undo:")), "z", toDelegate: false),
            item("Redo", Selector(("redo:")), "z", [.command, .shift], toDelegate: false),
            .separator(),
            item("Cut", #selector(NSText.cut(_:)), "x", toDelegate: false),
            item("Copy", #selector(NSText.copy(_:)), "c", toDelegate: false),
            item("Paste", #selector(NSText.paste(_:)), "v", toDelegate: false),
            item("Paste and Match Style", #selector(NSTextView.pasteAsPlainText(_:)), "v", [.command, .option, .shift], toDelegate: false),
            item("Delete", #selector(NSText.delete(_:)), toDelegate: false),
            item("Select All", #selector(NSText.selectAll(_:)), "a", toDelegate: false),
            .separator(),
            findHolder,
        ])

        // Task
        let priority = NSMenu(title: "Priority")
        for p in Priority.allCases.reversed() {
            priority.addItem(item(p.label, #selector(AppDelegate.setPriority(_:)), p == .none ? "" : "\(5 - p.rawValue)", [.command, .control], tag: p.rawValue))
        }
        let priorityHolder = NSMenuItem(title: "Priority", action: nil, keyEquivalent: "")
        priorityHolder.submenu = priority
        _ = submenu("Task", [
            item("Mark as Done", #selector(AppDelegate.completeSelected(_:)), "\r"),
            item("Do Today", #selector(AppDelegate.planToday(_:)), "t"),
            item("Move to Tomorrow", #selector(AppDelegate.planTomorrow(_:)), "t", [.command, .option]),
            item("Start Focus Session", #selector(AppDelegate.focusSelected(_:)), "f", [.command, .shift]),
            item("Move Up in Day", #selector(AppDelegate.moveSelectedUp(_:)), String(Character(UnicodeScalar(NSUpArrowFunctionKey)!)), [.command, .option]),
            item("Move Down in Day", #selector(AppDelegate.moveSelectedDown(_:)), String(Character(UnicodeScalar(NSDownArrowFunctionKey)!)), [.command, .option]),
            priorityHolder,
            .separator(),
            item("Delete Task", #selector(AppDelegate.deleteSelected(_:)), "\u{8}"),
        ])

        // Go
        let places = ["Calendar", "Inbox", "Notes", "Important", "All Tasks", "Completed", "Insights"]
        var goItems = places.enumerated().map { i, name in item(name, #selector(AppDelegate.go(_:)), "\(i + 1)", tag: i) }
        goItems += [
            .separator(),
            item("Jump to…", #selector(AppDelegate.commandPalette(_:)), "k"),
            item("Hide Sidebar", #selector(AppDelegate.toggleSidebar(_:)), "s", [.command, .control]),
            .separator(),
            item("Enter Full Screen", #selector(NSWindow.toggleFullScreen(_:)), "f", [.command, .control], toDelegate: false),
        ]
        _ = submenu("Go", goItems)

        // Window
        let window = submenu("Window", [
            item("Minimize", #selector(NSWindow.performMiniaturize(_:)), "m", toDelegate: false),
            item("Zoom", #selector(NSWindow.performZoom(_:)), toDelegate: false),
            .separator(),
            item("Docket", #selector(AppDelegate.showMainWindowAction(_:)), "0"),
            .separator(),
            item("Bring All to Front", #selector(NSApplication.arrangeInFront(_:)), toDelegate: false),
        ])
        NSApp.windowsMenu = window.submenu

        // Help
        let help = submenu("Help", [
            item("Docket Guide & Quick-Add Cheat Sheet", #selector(AppDelegate.showGuide(_:))),
        ])
        NSApp.helpMenu = help.submenu

        return main
    }
}
