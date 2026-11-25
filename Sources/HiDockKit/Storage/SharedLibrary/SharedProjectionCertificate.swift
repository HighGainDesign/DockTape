// © 2026 High Gain Design. All rights reserved.
import Foundation

public enum SharedProjectionError: Error, Equatable, Sendable {
    case notReady, invalidCertificate, differentLibrary
}
public struct SharedProjectionVote: Codable, Hashable, Sendable {
    public let writer: UUID
    public let revision: String
    public let cohort: String
    public init(writer: UUID, revision: String, cohort: String) {
        self.writer = writer
        self.revision = revision
        self.cohort = cohort
    }
}

/// Construction only proposes retirement. Actual owner-file votes must be
/// durably recorded under coordinated current-state validation before certify.
public struct SharedProjectionProposal: Sendable {
    public let state: SharedEntityState
    public let membership: SharedLibraryMembership
    public var revision: String { try! SharedStateFingerprint.of(state) }
    public var cohort: String { membership.fingerprint }
    public init(state: SharedEntityState, membership: SharedLibraryMembership) throws {
        guard membership.pendingWriters.isEmpty, !membership.hasConcurrentEnrollment,
            membership.cohort.allSatisfy({ membership.mayEdit($0) })
        else { throw SharedProjectionError.notReady }
        let writers = Set(state.fields.values.flatMap(\.causalContext).map(\.writer))
            .union(state.compaction?.context.map(\.writer) ?? [])
        guard writers.isSubset(of: membership.cohort) else { throw SharedProjectionError.notReady }
        let context = try SharedGenerationCompaction.proposed(for: state)
        // Every semantic mutation writes lifecycle last. Entity-wide allocation
        // makes that register an independently checkable bound for retired dots.
        guard context.context == (state.fields["$lifecycle"]?.causalContext ?? []) else {
            throw SharedProjectionError.invalidCertificate
        }
        self.state = try state.compacting(context)
        self.membership = membership
    }
    public func certify(votes: [SharedProjectionVote]) throws -> SharedProjectionCertificate {
        let certificate = SharedProjectionCertificate(
            state: state, membership: membership,
            votes: votes.sorted { $0.writer.uuidString < $1.writer.uuidString })
        try certificate.validate(binding: membership)
        return certificate
    }
}

/// The current common view, not a history of every save. While newer local
/// generations compete, this payload remains the same on newly arriving Macs.
/// The membership proof binds consent to this library and stable writer cohort.
public struct SharedProjectionCertificate: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let state: SharedEntityState
    public let membership: SharedLibraryMembership
    public let votes: [SharedProjectionVote]
    public var revision: String { try! SharedStateFingerprint.of(state) }
    public var fingerprint: String { try! SharedStateFingerprint.of(self) }
    init(state: SharedEntityState, membership: SharedLibraryMembership, votes: [SharedProjectionVote]) {
        schemaVersion = 1
        self.state = state
        self.membership = membership
        self.votes = votes
    }
    public func validate(binding: SharedLibraryMembership) throws {
        guard membership.libraryID == binding.libraryID, membership.founder == binding.founder,
            membership.bootstrapFingerprint == binding.bootstrapFingerprint
        else { throw SharedProjectionError.differentLibrary }
        _ = try binding.merged(with: membership)
        guard schemaVersion == 1, membership.pendingWriters.isEmpty, !membership.hasConcurrentEnrollment,
            membership.cohort.allSatisfy({ membership.mayEdit($0) }), state.conflicts.isEmpty,
            state.lifecycle == .alive || state.lifecycle == .deleted,
            let context = state.compaction,
            context.transcript == state.currentDocument(for: .transcript)?.id,
            context.summary == state.currentDocument(for: .summary)?.id,
            context.context == (state.fields["$lifecycle"]?.causalContext ?? []),
            Set(context.context.map(\.writer)).isSubset(of: membership.cohort),
            try state.compacting(context) == state,
            votes.count == membership.cohort.count, Set(votes.map(\.writer)) == membership.cohort,
            votes == votes.sorted(by: { $0.writer.uuidString < $1.writer.uuidString }),
            votes.allSatisfy({ $0.revision == revision && $0.cohort == membership.fingerprint })
        else {
            throw SharedProjectionError.invalidCertificate
        }
    }
    private enum CodingKeys: String, CodingKey { case schemaVersion, state, membership, votes }
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
        guard schemaVersion == 1 else { throw SharedLibraryRepositoryError.unsupportedSchema(schemaVersion) }
        state = try container.decode(SharedEntityState.self, forKey: .state)
        membership = try container.decode(SharedLibraryMembership.self, forKey: .membership)
        votes = try container.decode([SharedProjectionVote].self, forKey: .votes)
        try validate(binding: membership)
    }
}
