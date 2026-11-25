// © 2026 High Gain Design. All rights reserved.
import Foundation

/// A displayed folder identity. Its name remains an operation precondition,
/// so a reused path cannot retarget an action captured from an older catalog.
public struct SharedFolderReference: Hashable, Sendable {
    public let libraryID: UUID
    public let entityID: UUID
}
