// © 2026 High Gain Design. All rights reserved.
import Foundation

/// A displayed deletion scope, not permission to remove any files.
/// Cleanup requires a separate current Pending Folders review.
public struct SharedFolderDeletionRequestReview: Sendable {
    public struct Member: Sendable {
        public let path: String
        public let kind: SharedEntityKind
    }
    public let path: String
    public let members: [Member]
    public var value: SharedFieldValue { .document(document) }
    let base: SharedLibraryViewSnapshot
    let document: SharedDocument
}
