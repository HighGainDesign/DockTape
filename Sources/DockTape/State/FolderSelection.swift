// © 2026 High Gain Design. All rights reserved.
import Foundation
import HiDockKit

/// Captured by a sidebar row/editor before any asynchronous action starts.
struct FolderSelection: Hashable, Identifiable {
    let name: String
    let reference: SharedFolderReference?
    let libraryBinding: UUID
    var id: Self { self }
}
