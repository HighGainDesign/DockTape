// © 2026 High Gain Design. All rights reserved.
import XCTest
@testable import HiDockKit

final class SharedProjectionCertificateTests: XCTestCase {
    private let a = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
    private let b = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
    private let library = UUID(uuidString: "10000000-0000-0000-0000-000000000001")!
    private func initial() -> SharedLibraryMembership {
        .init(libraryID: library, founder: a, bootstrapFingerprint: "bootstrap")
    }
    private func membership() throws -> SharedLibraryMembership {
        var group = initial()
        try group.requestJoin(.init(writer: b, label: "Second Mac"))
        let proposal = try group.proposal(checkpoint: "enrollment-checkpoint")
        let votes = [a, b].map {
            SharedMembershipVote(writer: $0, proposal: proposal.fingerprint, checkpoint: "enrollment-checkpoint")
        }
        try group.accept(group.certify(proposal, votes: votes))
        return group
    }
    private func state() throws -> SharedEntityState {
        var state = SharedEntityState(id: UUID(), kind: .recording)
        try state.assignGeneration(
            SharedDocument(id: UUID(), json: Data("{\"text\":\"Common view\"}".utf8)), component: .transcript, writer: a
        )
        return state
    }
    func testCertificateRequiresEveryWriterAndExactCandidateAndCohort() throws {
        let group = try membership()
        let proposal = try SharedProjectionProposal(state: state(), membership: group)
        let vote = SharedProjectionVote(writer: a, revision: proposal.revision, cohort: proposal.cohort)
        XCTAssertThrowsError(try proposal.certify(votes: [vote]))
        XCTAssertThrowsError(
            try proposal.certify(votes: [vote, .init(writer: b, revision: "old", cohort: proposal.cohort)]))
        XCTAssertThrowsError(
            try proposal.certify(votes: [vote, .init(writer: b, revision: proposal.revision, cohort: "old cohort")]))
        let certificate = try proposal.certify(votes: [
            vote, .init(writer: b, revision: proposal.revision, cohort: proposal.cohort),
        ])
        try certificate.validate(binding: initial())
        XCTAssertEqual(
            certificate.state.currentDocument(for: .transcript)?.json, Data("{\"text\":\"Common view\"}".utf8))
        let decoded = try JSONDecoder().decode(
            SharedProjectionCertificate.self, from: JSONEncoder().encode(certificate))
        XCTAssertEqual(certificate, decoded)
    }
    func testPendingJoinConflictsAndUnknownWriterPreventCheckpointConsent() throws {
        var group = initial()
        try group.requestJoin(.init(writer: b, label: "Second Mac"))
        XCTAssertThrowsError(try SharedProjectionProposal(state: state(), membership: group))
        let admitted = try membership()
        var unknown = try state()
        try unknown.assign(field: "title", value: .text("Unknown writer"), writer: UUID())
        XCTAssertThrowsError(try SharedProjectionProposal(state: unknown, membership: admitted))
        var first = try state()
        var second = first
        try first.assign(field: "title", value: .text("Alpha"), writer: a)
        try second.assign(field: "title", value: .text("Beta"), writer: b)
        XCTAssertThrowsError(try SharedProjectionProposal(state: first.merged(with: second), membership: admitted))
    }
    func testConfirmedPayloadRemainsACommonViewWhenLaterGenerationsCompete() throws {
        let common = try state()
        let group = try membership()
        let proposal = try SharedProjectionProposal(state: common, membership: group)
        let certificate = try proposal.certify(
            votes: [a, b].map { .init(writer: $0, revision: proposal.revision, cohort: proposal.cohort) })
        var left = certificate.state
        var right = certificate.state
        try left.assignGeneration(
            SharedDocument(id: UUID(), json: Data("{\"text\":\"Left\"}".utf8)), component: .transcript, writer: a)
        try right.assignGeneration(
            SharedDocument(id: UUID(), json: Data("{\"text\":\"Right\"}".utf8)), component: .transcript, writer: b)
        let conflict = try left.merged(with: right)
        XCTAssertNil(conflict.currentDocument(for: .transcript))
        XCTAssertEqual(
            certificate.state.currentDocument(for: .transcript)?.json, Data("{\"text\":\"Common view\"}".utf8))
        XCTAssertThrowsError(try SharedProjectionProposal(state: conflict, membership: group))
    }
    func testForgedRetirementFloorIsRejectedEvenWithRecomputedMatchingVoteHashes() throws {
        let proposal = try SharedProjectionProposal(state: state(), membership: initial())
        let certificate = try proposal.certify(votes: [
            .init(writer: a, revision: proposal.revision, cohort: proposal.cohort)
        ])
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(certificate)) as? [String: Any])
        var stateObject = try XCTUnwrap(object["state"] as? [String: Any])
        var context = try XCTUnwrap(stateObject["compaction"] as? [String: Any])
        var rows = try XCTUnwrap(context["context"] as? [[String: Any]])
        rows[0]["counter"] = 999999
        context["context"] = rows
        stateObject["compaction"] = context
        let forged = try JSONDecoder().decode(
            SharedEntityState.self, from: JSONSerialization.data(withJSONObject: stateObject))
        object["state"] = stateObject
        object["votes"] = [
            ["writer": a.uuidString, "revision": try SharedStateFingerprint.of(forged), "cohort": proposal.cohort]
        ]
        XCTAssertThrowsError(
            try JSONDecoder().decode(
                SharedProjectionCertificate.self, from: JSONSerialization.data(withJSONObject: object))
        ) { error in
            XCTAssertEqual(error as? SharedProjectionError, .invalidCertificate)
        }
    }

    func testAnotherLibraryCannotUseTheCertificateAsRetirementAuthority() throws {
        let proposal = try SharedProjectionProposal(state: state(), membership: initial())
        let certificate = try proposal.certify(votes: [
            .init(writer: a, revision: proposal.revision, cohort: proposal.cohort)
        ])
        let other = SharedLibraryMembership(libraryID: UUID(), founder: a, bootstrapFingerprint: "bootstrap")
        XCTAssertThrowsError(try certificate.validate(binding: other))
    }
}
