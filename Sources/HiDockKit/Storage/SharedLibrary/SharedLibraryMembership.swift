// © 2026 High Gain Design. All rights reserved.
import CryptoKit
import Foundation

public enum SharedMembershipError: Error, Equatable, Sendable {
    case differentLibrary, reusedWriter, invalidCertificate, staleProposal, incompleteVotes
}

public enum SharedStateFingerprint {
    public static func of<Value: Encodable>(_ value: Value) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return SHA256.hash(data: try encoder.encode(value)).map { String(format: "%02x", $0) }.joined()
    }
}

public struct SharedMembershipRequest: Codable, Hashable, Sendable {
    public let writer: UUID
    public let requestID: UUID
    public let label: String
    public init(writer: UUID, requestID: UUID = UUID(), label: String) {
        self.writer = writer
        self.requestID = requestID
        self.label = label
    }
}

public struct SharedMembershipProposal: Codable, Hashable, Sendable {
    public let foundation: String
    public let parents: [String]
    public let requests: [SharedMembershipRequest]
    public let checkpoint: String
    public var fingerprint: String { try! SharedStateFingerprint.of(self) }
}

public struct SharedMembershipVote: Codable, Hashable, Sendable {
    public let writer: UUID
    public let proposal: String
    public let checkpoint: String
    public init(writer: UUID, proposal: String, checkpoint: String) {
        self.writer = writer
        self.proposal = proposal
        self.checkpoint = checkpoint
    }
}

public struct SharedMembershipCertificate: Codable, Hashable, Sendable {
    public let proposal: SharedMembershipProposal
    public let votes: [SharedMembershipVote]
    public var fingerprint: String { try! SharedStateFingerprint.of(self) }
}

public struct SharedRemovalAcknowledgment: Codable, Hashable, Sendable {
    public let writer: UUID
    public let entity: UUID
    public let revision: String
    public let cohort: String
    public init(writer: UUID, entity: UUID, revision: String, cohort: String) {
        self.writer = writer
        self.entity = entity
        self.revision = revision
        self.cohort = cohort
    }
}

/// Admission certificates retain membership changes, not per-edit history.
/// Every vote names an exact proposal and an acquired content checkpoint.
/// Concurrent admissions remain separate frontiers until all affected writers
/// acknowledge a union certificate. No missing writer expires by wall clock.
public struct SharedLibraryMembership: Codable, Equatable, Sendable {
    public let libraryID: UUID
    public let founder: UUID
    public let bootstrapFingerprint: String
    private var requests: [SharedMembershipRequest] = []
    private var certificates: [SharedMembershipCertificate] = []

    public init(libraryID: UUID, founder: UUID, bootstrapFingerprint: String) {
        self.libraryID = libraryID
        self.founder = founder
        self.bootstrapFingerprint = bootstrapFingerprint
    }

    private struct FoundationIdentity: Encodable {
        let library: UUID
        let founder: UUID
        let bootstrap: String
    }
    private var foundation: String {
        try! SharedStateFingerprint.of(
            FoundationIdentity(library: libraryID, founder: founder, bootstrap: bootstrapFingerprint))
    }
    private var heads: [SharedMembershipCertificate] {
        let consumed = Set(certificates.flatMap { $0.proposal.parents })
        return certificates.filter { !consumed.contains($0.fingerprint) }
    }
    private func members(of certificate: SharedMembershipCertificate) -> Set<UUID> {
        var result: Set<UUID> = [founder]
        result.formUnion(certificate.proposal.requests.map(\.writer))
        for parent in certificate.proposal.parents {
            if let previous = certificates.first(where: { $0.fingerprint == parent }) {
                result.formUnion(members(of: previous))
            }
        }
        return result
    }
    public func label(for writer: UUID) -> String {
        if writer == founder { return "Original Mac" }
        return requests.first(where: { $0.writer == writer })?.label ?? "Another Mac"
    }
    public var cohort: Set<UUID> { heads.reduce(into: Set([founder])) { $0.formUnion(members(of: $1)) } }
    public var pendingWriters: Set<UUID> { Set(requests.map(\.writer)).subtracting(cohort) }
    public var hasConcurrentEnrollment: Bool { heads.count > 1 }
    public var fingerprint: String {
        struct Cohort: Encodable {
            let foundation: String
            let heads: [String]
            let pending: [SharedMembershipRequest]
        }
        return try! SharedStateFingerprint.of(
            Cohort(
                foundation: foundation, heads: heads.map(\.fingerprint).sorted(),
                pending: requests.filter { pendingWriters.contains($0.writer) }))
    }
    public func mayEdit(_ writer: UUID) -> Bool {
        if writer == founder { return true }
        return !heads.isEmpty && heads.allSatisfy { members(of: $0).contains(writer) }
    }

    public mutating func requestJoin(_ request: SharedMembershipRequest) throws {
        guard request.writer != founder else { throw SharedMembershipError.reusedWriter }
        if let existing = requests.first(where: { $0.writer == request.writer }) {
            guard existing == request else { throw SharedMembershipError.reusedWriter }
            return
        }
        requests.append(request)
        normalize()
    }

    public func proposal(checkpoint: String) throws -> SharedMembershipProposal {
        guard !checkpoint.isEmpty, !pendingWriters.isEmpty || hasConcurrentEnrollment else {
            throw SharedMembershipError.invalidCertificate
        }
        return .init(
            foundation: foundation, parents: heads.map(\.fingerprint).sorted(),
            requests: requests.filter { pendingWriters.contains($0.writer) }, checkpoint: checkpoint)
    }
    public func requiredVoters(for proposal: SharedMembershipProposal) -> Set<UUID> {
        var result: Set<UUID> = [founder]
        for parent in proposal.parents {
            if let previous = certificates.first(where: { $0.fingerprint == parent }) {
                result.formUnion(members(of: previous))
            }
        }
        result.formUnion(proposal.requests.map(\.writer))
        return result
    }
    public func certify(_ proposal: SharedMembershipProposal, votes: [SharedMembershipVote]) throws
        -> SharedMembershipCertificate
    {
        guard proposal == (try self.proposal(checkpoint: proposal.checkpoint)) else {
            throw SharedMembershipError.staleProposal
        }
        let certificate = SharedMembershipCertificate(
            proposal: proposal, votes: votes.sorted { $0.writer.uuidString < $1.writer.uuidString })
        try validate(certificate, known: Set(certificates.map(\.fingerprint)))
        return certificate
    }
    public mutating func accept(_ certificate: SharedMembershipCertificate) throws {
        guard certificate.proposal == (try proposal(checkpoint: certificate.proposal.checkpoint)) else {
            throw SharedMembershipError.staleProposal
        }
        try validate(certificate, known: Set(certificates.map(\.fingerprint)))
        if !certificates.contains(certificate) {
            certificates.append(certificate)
            normalize()
        }
    }

    public func merged(with other: Self) throws -> Self {
        guard libraryID == other.libraryID, founder == other.founder, bootstrapFingerprint == other.bootstrapFingerprint
        else {
            throw SharedMembershipError.differentLibrary
        }
        var result = self
        for request in other.requests { try result.requestJoin(request) }
        for certificate in other.certificates where !result.certificates.contains(certificate) {
            result.certificates.append(certificate)
        }
        result.normalize()
        try result.validateAll()
        return result
    }

    /// Apply locally proposed additions after rejoining this writer's latest
    /// file. Observed certificates in base are safe to copy; a newly created
    /// certificate must still name the current frontier and pending requests.
    func rebased(from base: Self, onto latest: Self) throws -> Self {
        var result = try latest.merged(with: base)
        for request in requests where !base.requests.contains(request) { try result.requestJoin(request) }
        for certificate in certificates
        where !base.certificates.contains(certificate) && !result.certificates.contains(certificate) {
            try result.accept(certificate)
        }
        return result
    }

    public func mayRemoveAudio(
        _ entity: SharedEntityState, acknowledgments: [SharedRemovalAcknowledgment], hasPendingWork: Bool
    ) -> Bool {
        guard entity.lifecycle == .deleted, entity.conflicts.isEmpty, !hasPendingWork,
            pendingWriters.isEmpty, !hasConcurrentEnrollment,
            let revision = try? SharedStateFingerprint.of(entity)
        else { return false }
        let approved = Set(
            acknowledgments.filter { $0.entity == entity.id && $0.revision == revision && $0.cohort == fingerprint }
                .map(\.writer))
        return cohort.isSubset(of: approved)
    }

    private mutating func normalize() {
        requests.sort { $0.writer.uuidString < $1.writer.uuidString }
        certificates.sort { $0.fingerprint < $1.fingerprint }
    }
    private func validate(_ certificate: SharedMembershipCertificate, known: Set<String>) throws {
        let proposal = certificate.proposal
        guard proposal.foundation == foundation, !proposal.checkpoint.isEmpty,
            proposal.parents == Array(Set(proposal.parents)).sorted(), Set(proposal.parents).isSubset(of: known),
            proposal.requests == proposal.requests.sorted(by: { $0.writer.uuidString < $1.writer.uuidString }),
            Set(proposal.requests.map(\.writer)).count == proposal.requests.count,
            proposal.requests.allSatisfy({ requests.contains($0) }),
            certificate.votes == certificate.votes.sorted(by: { $0.writer.uuidString < $1.writer.uuidString })
        else {
            throw SharedMembershipError.invalidCertificate
        }
        guard certificate.votes.count == requiredVoters(for: proposal).count,
            Set(certificate.votes.map(\.writer)) == requiredVoters(for: proposal),
            certificate.votes.allSatisfy({ $0.proposal == proposal.fingerprint && $0.checkpoint == proposal.checkpoint }
            )
        else {
            throw SharedMembershipError.incompleteVotes
        }
    }
    private func validateAll() throws {
        guard !bootstrapFingerprint.isEmpty, Set(requests.map(\.writer)).count == requests.count,
            !requests.contains(where: { $0.writer == founder }),
            Set(certificates.map(\.fingerprint)).count == certificates.count
        else { throw SharedMembershipError.invalidCertificate }
        // Validate topologically, before recursive membership evaluation, so
        // malformed cycles/missing ancestors cannot recurse or admit a writer.
        var known: Set<String> = []
        var remaining = certificates
        while !remaining.isEmpty {
            let ready = remaining.filter { Set($0.proposal.parents).isSubset(of: known) }
            guard !ready.isEmpty else { throw SharedMembershipError.invalidCertificate }
            for certificate in ready {
                try validate(certificate, known: known)
                known.insert(certificate.fingerprint)
            }
            remaining.removeAll { known.contains($0.fingerprint) }
        }
    }
    private enum CodingKeys: String, CodingKey { case libraryID, founder, bootstrapFingerprint, requests, certificates }
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        libraryID = try container.decode(UUID.self, forKey: .libraryID)
        founder = try container.decode(UUID.self, forKey: .founder)
        bootstrapFingerprint = try container.decode(String.self, forKey: .bootstrapFingerprint)
        requests = try container.decode([SharedMembershipRequest].self, forKey: .requests)
        certificates = try container.decode([SharedMembershipCertificate].self, forKey: .certificates)
        normalize()
        try validateAll()
    }
}
