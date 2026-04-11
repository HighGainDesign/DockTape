// © 2026 High Gain Design. All rights reserved.

import AppKit
import SwiftUI
import HiDockKit

final class MainSplitViewController: NSSplitViewController {
    let appState: AppState

    init(appState: AppState) {
        self.appState = appState
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()

        // Sidebar
        let sidebarHost = NSHostingController(rootView: SidebarView(state: appState))
        sidebarHost.sizingOptions = .preferredContentSize
        let sidebarItem = NSSplitViewItem(sidebarWithViewController: sidebarHost)
        sidebarItem.canCollapse = true
        sidebarItem.minimumThickness = 180
        sidebarItem.maximumThickness = 280
        addSplitViewItem(sidebarItem)

        // Content list
        let listHost = NSHostingController(rootView: RecordingListPane(state: appState))
        listHost.sizingOptions = .preferredContentSize
        let listItem = NSSplitViewItem(contentListWithViewController: listHost)
        listItem.minimumThickness = 280
        listItem.holdingPriority = .defaultLow + 1
        addSplitViewItem(listItem)

        // Detail pane — lowest holding priority so it absorbs resize
        let detailHost = NSHostingController(rootView: DetailPane(state: appState))
        detailHost.sizingOptions = .preferredContentSize
        let detailItem = NSSplitViewItem(viewController: detailHost)
        detailItem.minimumThickness = 360
        detailItem.holdingPriority = .defaultLow
        addSplitViewItem(detailItem)

        splitView.dividerStyle = .thin
        splitView.isVertical = true
    }
}
