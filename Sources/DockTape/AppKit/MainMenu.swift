// © 2026 High Gain Design. All rights reserved.

import AppKit
import HiDockKit

@objc protocol MainMenuActions {
    func showSettings(_ sender: Any?)
    func transcribe(_ sender: Any?)
    func summarizeTemplate(_ sender: NSMenuItem)
    func importFromDevice(_ sender: Any?)
    func rename(_ sender: Any?)
    func revealInFinder(_ sender: Any?)
    func deleteRecording(_ sender: Any?)
    func mergeRecordings(_ sender: Any?)
    func find(_ sender: Any?)
    func showAllRecordings(_ sender: Any?)
    func showDevice(_ sender: Any?)
    func showPreviousTab(_ sender: Any?)
    func showNextTab(_ sender: Any?)
    func toolbarIconOnly(_ sender: Any?)
    func toolbarTextOnly(_ sender: Any?)
    func toolbarIconAndText(_ sender: Any?)
    func playPauseMenu(_ sender: Any?)
    func stop(_ sender: Any?)
    func increaseSpeed(_ sender: Any?)
    func decreaseSpeed(_ sender: Any?)
    func resetSpeed(_ sender: Any?)
    func syncAll(_ sender: Any?)
    func refreshDevice(_ sender: Any?)
    func deviceInfo(_ sender: Any?)
}

enum MainMenu {
    static func build(appState: AppState) -> NSMenu {
        let mainMenu = NSMenu()

        // App menu
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "About DockTape", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Settings...", action: #selector(MainMenuActions.showSettings(_:)), keyEquivalent: ",")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide DockTape", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        let hideOthers = NSMenuItem(title: "Hide Others", action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h")
        hideOthers.keyEquivalentModifierMask = [.command, .option]
        appMenu.addItem(hideOthers)
        appMenu.addItem(withTitle: "Show All", action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit DockTape", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        let appMenuItem = NSMenuItem()
        appMenuItem.submenu = appMenu
        mainMenu.addItem(appMenuItem)

        // File menu
        let fileMenu = NSMenu(title: "File")
        addItem(fileMenu, "Transcribe", action: #selector(MainMenuActions.transcribe(_:)), key: "t", modifiers: [.command, .shift])

        // Summarize submenu — populated dynamically via NSMenuDelegate on MainWindowController
        let summarizeMenu = NSMenu(title: "Summarize")
        let summarizeItem = NSMenuItem(title: "Summarize", action: nil, keyEquivalent: "")
        summarizeItem.submenu = summarizeMenu
        fileMenu.addItem(summarizeItem)

        fileMenu.addItem(.separator())
        addItem(fileMenu, "Import from Device", action: #selector(MainMenuActions.importFromDevice(_:)), key: "i", modifiers: [.command, .shift])
        fileMenu.addItem(.separator())
        addItem(fileMenu, "Merge Selected Recordings\u{2026}", action: #selector(MainMenuActions.mergeRecordings(_:)), key: "m", modifiers: [.command, .shift])
        fileMenu.addItem(.separator())
        addItem(fileMenu, "Rename...", action: #selector(MainMenuActions.rename(_:)), key: "\r", modifiers: [])
        addItem(fileMenu, "Reveal in Finder", action: #selector(MainMenuActions.revealInFinder(_:)), key: "r", modifiers: [.command, .shift])
        fileMenu.addItem(.separator())
        let deleteItem = NSMenuItem(title: "Delete", action: #selector(MainMenuActions.deleteRecording(_:)), keyEquivalent: "\u{8}")
        deleteItem.keyEquivalentModifierMask = .command
        fileMenu.addItem(deleteItem)
        let fileMenuItem = NSMenuItem()
        fileMenuItem.submenu = fileMenu
        mainMenu.addItem(fileMenuItem)

        // Edit menu
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        editMenu.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editMenu.addItem(.separator())
        addItem(editMenu, "Find...", action: #selector(MainMenuActions.find(_:)), key: "f", modifiers: .command)
        let editMenuItem = NSMenuItem()
        editMenuItem.submenu = editMenu
        mainMenu.addItem(editMenuItem)

        // View menu
        let viewMenu = NSMenu(title: "View")
        addItem(viewMenu, "Toggle Sidebar", action: #selector(NSSplitViewController.toggleSidebar(_:)), key: "s", modifiers: [.command, .control])
        viewMenu.addItem(.separator())
        addItem(viewMenu, "Show All Recordings", action: #selector(MainMenuActions.showAllRecordings(_:)), key: "1", modifiers: .command)
        addItem(viewMenu, "Show Device", action: #selector(MainMenuActions.showDevice(_:)), key: "2", modifiers: .command)
        viewMenu.addItem(.separator())
        addItem(viewMenu, "Show Previous Tab", action: #selector(MainMenuActions.showPreviousTab(_:)), key: "[", modifiers: [.command, .shift])
        addItem(viewMenu, "Show Next Tab", action: #selector(MainMenuActions.showNextTab(_:)), key: "]", modifiers: [.command, .shift])
        viewMenu.addItem(.separator())
        let densityMenu = NSMenu(title: "Toolbar Style")
        densityMenu.addItem(withTitle: "Icon Only", action: #selector(MainMenuActions.toolbarIconOnly(_:)), keyEquivalent: "")
        densityMenu.addItem(withTitle: "Text Only", action: #selector(MainMenuActions.toolbarTextOnly(_:)), keyEquivalent: "")
        densityMenu.addItem(withTitle: "Icon and Text", action: #selector(MainMenuActions.toolbarIconAndText(_:)), keyEquivalent: "")
        let densityItem = NSMenuItem(title: "Toolbar Style", action: nil, keyEquivalent: "")
        densityItem.submenu = densityMenu
        viewMenu.addItem(densityItem)
        let viewMenuItem = NSMenuItem()
        viewMenuItem.submenu = viewMenu
        mainMenu.addItem(viewMenuItem)

        // Playback menu
        let playbackMenu = NSMenu(title: "Playback")
        addItem(playbackMenu, "Play", action: #selector(MainMenuActions.playPauseMenu(_:)), key: "p", modifiers: .command)
        addItem(playbackMenu, "Stop", action: #selector(MainMenuActions.stop(_:)), key: ".", modifiers: .command)
        playbackMenu.addItem(.separator())
        addItem(playbackMenu, "Increase Speed", action: #selector(MainMenuActions.increaseSpeed(_:)), key: "]", modifiers: .command)
        addItem(playbackMenu, "Decrease Speed", action: #selector(MainMenuActions.decreaseSpeed(_:)), key: "[", modifiers: .command)
        addItem(playbackMenu, "Reset Speed", action: #selector(MainMenuActions.resetSpeed(_:)), key: "\\", modifiers: .command)
        let playbackMenuItem = NSMenuItem()
        playbackMenuItem.submenu = playbackMenu
        mainMenu.addItem(playbackMenuItem)

        // Device menu
        let deviceMenu = NSMenu(title: "Device")
        addItem(deviceMenu, "Sync All", action: #selector(MainMenuActions.syncAll(_:)), key: "d", modifiers: [.command, .shift])
        addItem(deviceMenu, "Refresh Device", action: #selector(MainMenuActions.refreshDevice(_:)), key: "", modifiers: [])
        deviceMenu.addItem(.separator())
        addItem(deviceMenu, "Device Info...", action: #selector(MainMenuActions.deviceInfo(_:)), key: "i", modifiers: .command)
        let deviceMenuItem = NSMenuItem()
        deviceMenuItem.submenu = deviceMenu
        mainMenu.addItem(deviceMenuItem)

        // Window menu
        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowMenu.addItem(withTitle: "Zoom", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        windowMenu.addItem(.separator())
        windowMenu.addItem(withTitle: "Bring All to Front", action: #selector(NSApplication.arrangeInFront(_:)), keyEquivalent: "")
        let windowMenuItem = NSMenuItem()
        windowMenuItem.submenu = windowMenu
        mainMenu.addItem(windowMenuItem)
        NSApp.windowsMenu = windowMenu

        return mainMenu
    }

    private static func addItem(_ menu: NSMenu, _ title: String, action: Selector, key: String, modifiers: NSEvent.ModifierFlags) {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.keyEquivalentModifierMask = modifiers
        menu.addItem(item)
    }
}
