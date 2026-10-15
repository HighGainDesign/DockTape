// © 2026 High Gain Design. All rights reserved.
import Foundation

/// Consent is bound to the displayed folder, accepted intent and exact cohort.
public struct SharedFolderOperationReview: Identifiable, Sendable {
    public enum Purpose: String, Sendable { case create, rename, delete }
    public var id: UUID { base.state.id }
    public let name: String
    public let purpose: Purpose
    public let paths: [String]
    public let waitingForMacs: [String]
    public let hasActiveWork: Bool
    public let needsReplanning: Bool
    public let canAcknowledge: Bool
    public let canResume: Bool
    let base: SharedLibraryViewSnapshot
    let cohort: String
    public var isDeletionRequest: Bool { deletionRequest }
    let deletionRequest: Bool
    let operation: SharedLibraryOperation?
    let intentWriter: UUID?
}
