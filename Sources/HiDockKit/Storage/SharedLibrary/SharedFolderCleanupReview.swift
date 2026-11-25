// © 2026 High Gain Design. All rights reserved.
import Foundation

/// Explicitly transitions a completed local rename to a new, unapproved
/// empty-directory cleanup. Saving never replaces the local rename receipt.
public struct SharedFolderCleanupReview: Identifiable, Sendable {
    public var id: UUID { original.id }
    public let path: String
    public let retainedPaths: [String]
    let original: SharedFolderOperationReview
    let context: String
    let previous: SharedLibraryOperation
    let inventory: SharedDirectoryInventory
    let receiptFile: URL
    let receiptFingerprint: String
}
