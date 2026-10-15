// © 2026 High Gain Design. All rights reserved.
import Foundation

/// Consent is bound to the displayed folder, accepted intent and exact cohort.
public struct SharedFolderOperationReview: Identifiable, Sendable {
    public enum Purpose: String, Sendable { case create, rename, delete, retain }
    public var id: UUID { base.state.id }
    public let name: String
    public let purpose: Purpose
    public let paths: [String]
    public let waitingForMacs: [String]
    public let hasActiveWork: Bool
    public let needsReplanning: Bool
    public let canAcknowledge: Bool
    public let canResume: Bool
    public var canReplan: Bool {
        guard (purpose == .rename || purpose == .retain), needsReplanning, !hasActiveWork,
              base.state.lifecycle == .alive, base.state.value(for: "deletionRequest") == nil,
              base.state.fields["name"]?.isConflicted != true, base.state.fields["parent"]?.isConflicted != true,
              base.state.conflicts.allSatisfy({ ["physicalPath", "moveScope"].contains($0.field) }) else { return false }
        if case .moveDirectory? = operation?.steps.first { return true }
        if purpose == .retain, case .removeEmptyDirectory? = operation?.steps.first { return true }
        return false
    }
    let base: SharedLibraryViewSnapshot
    let cohort: String
    public var isDeletionRequest: Bool { deletionRequest }
    let deletionRequest: Bool
    let operation: SharedLibraryOperation?
    let intentWriter: UUID?
    let localOperation: SharedLibraryOperation?
}
