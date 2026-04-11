import AppKit
import SwiftUI
import HiDockKit

private extension NSToolbarItem.Identifier {
    static let sidebarTrackingSeparator = NSToolbarItem.Identifier("sidebarTrackingSeparator")
    static let trackingSeparator = NSToolbarItem.Identifier("trackingSeparator")
    static let sort = NSToolbarItem.Identifier("sort")
    static let filter = NSToolbarItem.Identifier("filter")
    static let playPause = NSToolbarItem.Identifier("playPause")
    static let transcribe = NSToolbarItem.Identifier("transcribe")
    static let summarize = NSToolbarItem.Identifier("summarize")
    static let importFile = NSToolbarItem.Identifier("importFile")
    static let delete = NSToolbarItem.Identifier("delete")
    static let refresh = NSToolbarItem.Identifier("refresh")
    static let search = NSToolbarItem.Identifier("search")
}

final class MainWindowController: NSWindowController, NSToolbarDelegate {
    let appState: AppState
    private let splitViewController: MainSplitViewController
    private var stateObservationTask: Task<Void, Never>?
    private var searchField: NSSearchField?
    private var isDeviceContext: Bool = false
    private var settingsWindow: NSWindow?

    init(appState: AppState) {
        self.appState = appState
        self.splitViewController = MainSplitViewController(appState: appState)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1100, height: 700),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "DockTape"
        window.titlebarAppearsTransparent = false
        window.titleVisibility = .hidden
        window.setFrameAutosaveName("MainWindow")
        window.minSize = NSSize(width: 960, height: 560)
        window.contentViewController = splitViewController
        window.titlebarSeparatorStyle = .automatic

        super.init(window: window)
        setupToolbar()
        setupMenuDelegates()
        startObservingState()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    deinit { stateObservationTask?.cancel() }

    /// Set this controller as NSMenuDelegate for all "Summarize" submenus in the menu bar.
    private func setupMenuDelegates() {
        guard let mainMenu = NSApp.mainMenu else { return }
        for item in mainMenu.items {
            if let submenu = item.submenu {
                for subItem in submenu.items {
                    if subItem.submenu?.title == "Summarize" {
                        subItem.submenu?.delegate = self
                    }
                }
            }
        }
    }

    private func setupToolbar() {
        let toolbar = NSToolbar(identifier: "MainToolbar")
        toolbar.delegate = self
        toolbar.displayMode = .iconAndLabel
        toolbar.allowsUserCustomization = false
        window?.toolbar = toolbar
    }

    // MARK: - NSToolbarDelegate

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier, willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        switch itemIdentifier {
        case .sidebarTrackingSeparator:
            return NSTrackingSeparatorToolbarItem(
                identifier: itemIdentifier,
                splitView: splitViewController.splitView,
                dividerIndex: 0 // between sidebar and content list
            )
        case .trackingSeparator:
            return NSTrackingSeparatorToolbarItem(
                identifier: itemIdentifier,
                splitView: splitViewController.splitView,
                dividerIndex: 1 // between content list and detail
            )
        case .sort:
            let item = NSMenuToolbarItem(itemIdentifier: itemIdentifier)
            item.label = "Sort"
            item.image = NSImage(systemSymbolName: "arrow.up.arrow.down", accessibilityDescription: "Sort")
            item.toolTip = "Sort recordings"
            item.isBordered = true
            item.showsIndicator = true
            item.menu = buildSortMenu()
            return item
        case .filter:
            let item = NSMenuToolbarItem(itemIdentifier: itemIdentifier)
            item.label = "Filter"
            item.image = NSImage(systemSymbolName: "line.3.horizontal.decrease.circle", accessibilityDescription: "Filter")
            item.toolTip = "Filter recordings"
            item.isBordered = true
            item.showsIndicator = true
            item.menu = buildFilterMenu()
            return item
        case .playPause:
            let item = NSToolbarItem(itemIdentifier: itemIdentifier)
            item.label = "Play"
            item.image = NSImage(systemSymbolName: "play.fill", accessibilityDescription: "Play")
            item.target = self
            item.action = #selector(playPause(_:))
            item.toolTip = "Play or pause the selected recording"
            item.isBordered = true
            return item
        case .transcribe:
            let item = NSToolbarItem(itemIdentifier: itemIdentifier)
            item.label = "Transcribe"
            item.image = NSImage(systemSymbolName: "text.quote", accessibilityDescription: "Transcribe")
            item.target = self
            item.action = #selector(transcribeAction(_:))
            item.toolTip = "Transcribe selected recording(s)"
            item.isBordered = true
            return item
        case .summarize:
            let item = NSMenuToolbarItem(itemIdentifier: itemIdentifier)
            item.label = "Summarize"
            item.image = NSImage(systemSymbolName: "sparkles", accessibilityDescription: "Summarize")
            item.toolTip = "Summarize with template"
            item.isBordered = true
            item.menu = buildSummarizeMenu()
            item.showsIndicator = true
            return item
        case .importFile:
            let item = NSToolbarItem(itemIdentifier: itemIdentifier)
            item.label = "Import"
            item.image = NSImage(systemSymbolName: "square.and.arrow.down", accessibilityDescription: "Import")
            item.target = self
            item.action = #selector(importAction(_:))
            item.toolTip = "Import selected file(s) from device"
            item.isBordered = true
            return item
        case .delete:
            let item = NSToolbarItem(itemIdentifier: itemIdentifier)
            item.label = "Delete"
            item.image = NSImage(systemSymbolName: "trash", accessibilityDescription: "Delete")
            item.target = self
            item.action = #selector(deleteAction(_:))
            item.toolTip = "Delete selected item(s)"
            item.isBordered = true
            return item
        case .refresh:
            let item = NSToolbarItem(itemIdentifier: itemIdentifier)
            item.label = "Refresh"
            item.image = NSImage(systemSymbolName: "arrow.clockwise", accessibilityDescription: "Refresh")
            item.target = self
            item.action = #selector(refreshAction(_:))
            item.toolTip = "Refresh from disk or device"
            item.isBordered = true
            return item
        case .search:
            let item = NSSearchToolbarItem(itemIdentifier: itemIdentifier)
            item.searchField.placeholderString = "Search"
            item.searchField.target = self
            item.searchField.action = #selector(searchChanged(_:))
            searchField = item.searchField
            return item
        default:
            return nil
        }
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        currentToolbarIdentifiers()
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        // Return the superset of all possible items so rebuild can insert any of them
        [.toggleSidebar, .sidebarTrackingSeparator, .sort, .filter, .trackingSeparator, .playPause, .transcribe, .summarize, .importFile, .delete, .refresh, .flexibleSpace, .search]
    }

    // MARK: - Toolbar Validation

    @objc func validateToolbarItem(_ item: NSToolbarItem) -> Bool {
        let isDevice = isDeviceContext
        let libraryCount = appState.library.selectedRecordings.count
        let deviceCount = appState.device.selectedDeviceFiles.count
        let hasSelection = isDevice ? deviceCount > 0 : libraryCount > 0
        let hasSingleSelection = isDevice ? deviceCount == 1 : libraryCount == 1

        switch item.itemIdentifier {
        case .playPause:
            let isPlaying = appState.playback.isPlaying
            item.label = isPlaying ? "Pause" : "Play"
            item.image = NSImage(systemSymbolName: isPlaying ? "pause.fill" : "play.fill", accessibilityDescription: isPlaying ? "Pause" : "Play")
            return !isDevice && (hasSingleSelection || appState.playback.playingFile != nil)
        case .transcribe:
            return !isDevice && hasSelection
        case .summarize:
            if !isDevice && hasSelection {
                let recs = appState.library.recordings.filter { appState.library.selectedRecordings.contains($0.filename) }
                return recs.contains { (appState.transcription.statuses[$0.filename] ?? .none) == .done }
            }
            return false
        case .importFile:
            return isDevice && hasSelection
        case .delete:
            return hasSelection
        case .refresh:
            return true
        default:
            return true
        }
    }

    // MARK: - Toolbar Actions

    @objc func playPause(_ sender: Any?) {
        if appState.playback.playingFile != nil {
            appState.playback.togglePlayPause()
        } else if appState.library.selectedRecordings.count == 1,
                  let filename = appState.library.selectedRecordings.first,
                  let rec = appState.library.recordings.first(where: { $0.filename == filename }) {
            appState.playRecording(rec)
        }
    }

    @objc func transcribeAction(_ sender: Any?) {
        let recs = selectedLibraryRecordings
        guard !recs.isEmpty else { return }
        Task { await appState.transcribeRecordings(recs) }
    }

    @objc func importAction(_ sender: Any?) {
        let files = appState.device.files.filter { appState.device.selectedDeviceFiles.contains($0.filename) }
        Task { for file in files { await appState.downloadFile(file) } }
    }

    @objc func deleteAction(_ sender: Any?) {
        if isDeviceContext {
            let files = appState.device.files.filter { appState.device.selectedDeviceFiles.contains($0.filename) }
            Task {
                for file in files { await appState.deleteFromDevice(file) }
                appState.device.selectedDeviceFiles.removeAll()
            }
        } else {
            let recs = selectedLibraryRecordings
            Task {
                for rec in recs { await appState.deleteLocalRecording(rec) }
                appState.library.selectedRecordings.removeAll()
            }
        }
    }

    @objc func refreshAction(_ sender: Any?) {
        if isDeviceContext {
            Task { await appState.device.refreshDevice() }
        } else {
            Task { await appState.refreshAll() }
        }
    }

    @objc func searchChanged(_ sender: NSSearchField) {
        appState.library.searchText = sender.stringValue
    }

    // MARK: - Summarize Menu

    private func buildSummarizeMenu() -> NSMenu {
        let menu = NSMenu(title: "Summarize")
        menu.delegate = self
        return menu
    }

    /// Rebuild summarize menu contents on open — picks up user-created templates at runtime.
    private func populateSummarizeMenu(_ menu: NSMenu) {
        menu.removeAllItems()

        let builtIn = TemplateStore.builtInDefaults
        if !builtIn.isEmpty {
            for template in builtIn {
                let item = NSMenuItem(title: template.name, action: #selector(summarizeWithTemplate(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = template
                menu.addItem(item)
            }
        }

        // Load user templates asynchronously — populate synchronously from cache
        Task { @MainActor in
            let userTemplates = await appState.templateStore.userCreatedTemplates()
            if !userTemplates.isEmpty {
                menu.addItem(.separator())
                let header = NSMenuItem(title: "My Templates", action: nil, keyEquivalent: "")
                header.isEnabled = false
                menu.addItem(header)
                for template in userTemplates {
                    let item = NSMenuItem(title: template.name, action: #selector(self.summarizeWithTemplate(_:)), keyEquivalent: "")
                    item.target = self
                    item.representedObject = template
                    menu.addItem(item)
                }
            }

            menu.addItem(.separator())
            let customItem = NSMenuItem(title: "Custom prompt...", action: #selector(self.summarizeCustomPrompt(_:)), keyEquivalent: "")
            customItem.target = self
            menu.addItem(customItem)
        }
    }

    @objc func summarizeWithTemplate(_ sender: NSMenuItem) {
        guard let template = sender.representedObject as? Template else { return }
        for rec in selectedLibraryRecordings {
            appState.summarizeWithTemplate(rec, template: template)
        }
    }

    @objc func summarizeCustomPrompt(_ sender: NSMenuItem) {
        appState.triggerCustomPrompt = true
    }

    // MARK: - Sort & Filter Menus

    private func buildSortMenu() -> NSMenu {
        let menu = NSMenu(title: "Sort")
        for sort in LibrarySort.allCases {
            let item = NSMenuItem(title: sort.rawValue, action: #selector(sortChanged(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = sort.rawValue
            menu.addItem(item)
        }
        return menu
    }

    @objc func sortChanged(_ sender: NSMenuItem) {
        guard let rawValue = sender.representedObject as? String else { return }
        UserDefaults.standard.set(rawValue, forKey: "librarySortBy")
    }

    private func buildFilterMenu() -> NSMenu {
        let menu = NSMenu(title: "Filter")

        let typeHeader = NSMenuItem(title: "Type", action: nil, keyEquivalent: "")
        typeHeader.isEnabled = false
        menu.addItem(typeHeader)

        let types: [(String, String)] = [("All", ""), ("Recording", "Rec"), ("Phone", "Pho"), ("Meeting", "Mee"), ("WIP", "Wip")]
        for (title, mode) in types {
            let item = NSMenuItem(title: title, action: #selector(filterModeChanged(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = mode
            menu.addItem(item)
        }

        menu.addItem(.separator())

        let dateHeader = NSMenuItem(title: "Date", action: nil, keyEquivalent: "")
        dateHeader.isEnabled = false
        menu.addItem(dateHeader)

        for period in TimePeriod.allCases {
            let item = NSMenuItem(title: period.rawValue, action: #selector(filterPeriodChanged(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = period.rawValue
            menu.addItem(item)
        }

        return menu
    }

    @objc func filterModeChanged(_ sender: NSMenuItem) {
        guard let mode = sender.representedObject as? String else { return }
        UserDefaults.standard.set(mode, forKey: "libraryFilterMode")
    }

    @objc func filterPeriodChanged(_ sender: NSMenuItem) {
        guard let rawValue = sender.representedObject as? String else { return }
        UserDefaults.standard.set(rawValue, forKey: "libraryFilterPeriod")
    }

    // MARK: - Helpers

    var selectedLibraryRecordings: [RecordingMetadata] {
        appState.library.recordings.filter { appState.library.selectedRecordings.contains($0.filename) }
    }

    // MARK: - State Observation

    private func startObservingState() {
        func observe() {
            withObservationTracking {
                _ = self.appState.selectedView
                _ = self.appState.library.selectedRecordings.count
                _ = self.appState.device.selectedDeviceFiles.count
                _ = self.appState.playback.isPlaying
                _ = self.appState.playback.playingFile
            } onChange: {
                Task { @MainActor [weak self] in
                    self?.updateToolbarContext()
                    observe()
                }
            }
        }
        stateObservationTask = Task { @MainActor in observe() }
    }

    private func updateToolbarContext() {
        let shouldBeDevice: Bool
        switch appState.selectedView {
        case .device: shouldBeDevice = true
        default: shouldBeDevice = false
        }

        guard shouldBeDevice != isDeviceContext else {
            window?.toolbar?.validateVisibleItems()
            return
        }
        isDeviceContext = shouldBeDevice
        rebuildToolbarItems()
    }

    private func rebuildToolbarItems() {
        guard let toolbar = window?.toolbar else { return }
        while toolbar.items.count > 0 {
            toolbar.removeItem(at: 0)
        }
        let identifiers = currentToolbarIdentifiers()
        for (index, id) in identifiers.enumerated() {
            toolbar.insertItem(withItemIdentifier: id, at: index)
        }
    }

    private func currentToolbarIdentifiers() -> [NSToolbarItem.Identifier] {
        var ids: [NSToolbarItem.Identifier] = [.flexibleSpace, .toggleSidebar, .sidebarTrackingSeparator, .sort, .filter, .trackingSeparator]
        if isDeviceContext {
            ids += [.importFile, .delete, .refresh]
        } else {
            ids += [.playPause, .transcribe, .summarize, .delete, .refresh]
        }
        ids += [.flexibleSpace, .search]
        return ids
    }
}

// MARK: - Menu Actions (responder chain)

extension MainWindowController: MainMenuActions {}

// MARK: - NSMenuDelegate (dynamic summarize menu)

extension MainWindowController: NSMenuDelegate {
    func menuNeedsUpdate(_ menu: NSMenu) {
        if menu.title == "Summarize" {
            populateSummarizeMenu(menu)
        }
    }
}

extension MainWindowController: NSMenuItemValidation {
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        let hasLibrarySelection = !appState.library.selectedRecordings.isEmpty
        let hasSingleLibrarySelection = appState.library.selectedRecordings.count == 1
        let hasDeviceSelection = !appState.device.selectedDeviceFiles.isEmpty
        let isPlaying = appState.playback.playingFile != nil

        switch menuItem.action {
        case #selector(MainMenuActions.transcribe(_:)): return hasLibrarySelection
        case #selector(MainMenuActions.summarizeTemplate(_:)): return hasLibrarySelection
        case #selector(MainMenuActions.importFromDevice(_:)): return hasDeviceSelection
        case #selector(MainMenuActions.rename(_:)): return hasSingleLibrarySelection
        case #selector(MainMenuActions.revealInFinder(_:)): return hasLibrarySelection
        case #selector(MainMenuActions.deleteRecording(_:)): return hasLibrarySelection || hasDeviceSelection
        case #selector(MainMenuActions.playPauseMenu(_:)):
            menuItem.title = appState.playback.isPlaying ? "Pause" : "Play"
            return isPlaying || hasSingleLibrarySelection
        case #selector(MainMenuActions.stop(_:)),
             #selector(MainMenuActions.increaseSpeed(_:)),
             #selector(MainMenuActions.decreaseSpeed(_:)),
             #selector(MainMenuActions.resetSpeed(_:)):
            return isPlaying
        case #selector(MainMenuActions.showDevice(_:)): return appState.device.isConnected
        case #selector(MainMenuActions.showPreviousTab(_:)):
            return DetailTab.allCases.firstIndex(of: appState.selectedDetailTab).map { $0 > 0 } ?? false
        case #selector(MainMenuActions.showNextTab(_:)):
            let tabs = DetailTab.allCases
            return tabs.firstIndex(of: appState.selectedDetailTab).map { $0 < tabs.count - 1 } ?? false
        case #selector(MainMenuActions.syncAll(_:)):
            return appState.device.isConnected && !appState.device.isSyncing
        case #selector(MainMenuActions.refreshDevice(_:)),
             #selector(MainMenuActions.deviceInfo(_:)):
            return appState.device.isConnected
        default: return true
        }
    }

    // Menu action methods
    @objc func showSettings(_ sender: Any?) {
        if let existing = settingsWindow, existing.isVisible {
            existing.makeKeyAndOrderFront(nil)
            return
        }
        let hostingController = NSHostingController(rootView: SettingsView(state: appState))
        let win = NSWindow(contentViewController: hostingController)
        win.title = "Settings"
        win.styleMask = [.titled, .closable]
        win.setContentSize(NSSize(width: 450, height: 400))
        win.center()
        win.makeKeyAndOrderFront(nil)
        settingsWindow = win
    }

    @objc func transcribe(_ sender: Any?) { transcribeAction(sender) }
    @objc func summarizeTemplate(_ sender: NSMenuItem) { summarizeWithTemplate(sender) }
    @objc func importFromDevice(_ sender: Any?) { importAction(sender) }
    @objc func rename(_ sender: Any?) { appState.triggerRename = true }
    @objc func revealInFinder(_ sender: Any?) {
        guard let rec = selectedLibraryRecordings.first else { return }
        appState.library.revealInFinder(rec)
    }
    @objc func deleteRecording(_ sender: Any?) { deleteAction(sender) }
    @objc func find(_ sender: Any?) { appState.library.isSearchFocused = true }
    @objc func showAllRecordings(_ sender: Any?) { appState.selectedView = .allRecordings }
    @objc func showDevice(_ sender: Any?) {
        guard appState.device.isConnected else { return }
        appState.selectedView = .device
    }
    @objc func showPreviousTab(_ sender: Any?) {
        let tabs = DetailTab.allCases
        if let idx = tabs.firstIndex(of: appState.selectedDetailTab), idx > 0 {
            appState.selectedDetailTab = tabs[idx - 1]
        }
    }
    @objc func showNextTab(_ sender: Any?) {
        let tabs = DetailTab.allCases
        if let idx = tabs.firstIndex(of: appState.selectedDetailTab), idx < tabs.count - 1 {
            appState.selectedDetailTab = tabs[idx + 1]
        }
    }
    @objc func toolbarIconOnly(_ sender: Any?) { window?.toolbar?.displayMode = .iconOnly }
    @objc func toolbarTextOnly(_ sender: Any?) { window?.toolbar?.displayMode = .labelOnly }
    @objc func toolbarIconAndText(_ sender: Any?) { window?.toolbar?.displayMode = .iconAndLabel }
    @objc func playPauseMenu(_ sender: Any?) { playPause(sender) }
    @objc func stop(_ sender: Any?) { appState.playback.stop() }
    @objc func increaseSpeed(_ sender: Any?) {
        let speeds = PlaybackState.speeds
        if let idx = speeds.firstIndex(of: appState.playback.rate), idx + 1 < speeds.count {
            appState.playback.setRate(speeds[idx + 1])
        }
    }
    @objc func decreaseSpeed(_ sender: Any?) {
        let speeds = PlaybackState.speeds
        if let idx = speeds.firstIndex(of: appState.playback.rate), idx > 0 {
            appState.playback.setRate(speeds[idx - 1])
        }
    }
    @objc func resetSpeed(_ sender: Any?) { appState.playback.setRate(1.0) }
    @objc func syncAll(_ sender: Any?) { Task { await appState.syncAll() } }
    @objc func refreshDevice(_ sender: Any?) { Task { await appState.device.refreshDevice() } }
    @objc func deviceInfo(_ sender: Any?) { appState.device.showDeviceInfo = true }
}
