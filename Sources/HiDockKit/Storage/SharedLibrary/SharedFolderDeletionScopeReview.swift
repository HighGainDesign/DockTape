// © 2026 High Gain Design. All rights reserved.
import Foundation

/// An updated owned-child list. Accepting it grants no cleanup approval.
public struct SharedFolderDeletionScopeReview: Identifiable, Sendable {
    public struct Member: Sendable {
        public let path: String
        public let state: SharedEntityState
    }
    public var id: UUID { original.id }
    public let path: String
    public let members: [Member]
    let original: SharedFolderOperationReview
    let context: String
    let document: SharedDocument
    let receiptFile: URL
    let receiptFingerprint: String?
}
