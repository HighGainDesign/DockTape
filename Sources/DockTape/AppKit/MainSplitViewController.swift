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

        let sidebarHost = NSHostingController(rootView: SidebarView(state: appState))
        let sidebarItem = NSSplitViewItem(sidebarWithViewController: sidebarHost)
        sidebarItem.canCollapse = true
        sidebarItem.minimumThickness = 180
        sidebarItem.maximumThickness = 280
        addSplitViewItem(sidebarItem)

        let listHost = NSHostingController(rootView: RecordingListPane(state: appState))
        let listItem = NSSplitViewItem(contentListWithViewController: listHost)
        listItem.minimumThickness = 280
        addSplitViewItem(listItem)

        let detailHost = NSHostingController(rootView: DetailPane(state: appState))
        let detailItem = NSSplitViewItem(viewController: detailHost)
        detailItem.minimumThickness = 360
        addSplitViewItem(detailItem)

        splitView.dividerStyle = .thin
    }
}
