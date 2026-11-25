// © 2026 High Gain Design. All rights reserved.
import Foundation

/// A complete semantic folder location, bound to the graph and cohort shown.
/// Choosing it grants no physical mutation or deletion permission.
public struct SharedFolderPathReview: Sendable {
    public let destination: String
    public let values: [String: SharedFieldValue]
    public var contextFingerprint: String { base.fingerprint + ":" + context + ":" + cohort }
    let base: SharedLibraryViewSnapshot
    let context: String
    let cohort: String
}

/// Physical consent is separate from choosing a semantic name/parent.
public struct SharedFolderReplanReview: Identifiable, Sendable {
    public var id: UUID { original.id }
    public let source: String
    public let destination: String
    public let files: [String]
    let original: SharedFolderOperationReview
    let inventory: SharedDirectoryInventory
    let operation: SharedLibraryOperation
    let localOperation: SharedLibraryOperation?
    let sourcePaths: [String]
    let graph: String
    let bindings: [SharedMaterializationBinding]
    /// Absent child slots and retained aliases bound through final commit.
    let absentChildPaths: [String]
    let scope: SharedDocument
    let reusesOperation: Bool
}
