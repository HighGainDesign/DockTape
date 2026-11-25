// © 2026 High Gain Design. All rights reserved.
import XCTest
@testable import HiDockKit

final class SharedLibraryMembershipTests: XCTestCase {
    private let a = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
    private let b = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
    private let c = UUID(uuidString: "00000000-0000-0000-0000-000000000003")!
    private let library = UUID(uuidString: "10000000-0000-0000-0000-000000000001")!

    private func initial() -> SharedLibraryMembership {
        .init(libraryID: library, founder: a, bootstrapFingerprint: "bootstrap")
    }
    private func certificate(_ state: SharedLibraryMembership, checkpoint: String = "checkpoint") throws -> SharedMembershipCertificate {
        let proposal = try state.proposal(checkpoint: checkpoint)
        return try state.certify(proposal, votes: state.requiredVoters(for: proposal).map {
            SharedMembershipVote(writer: $0, proposal: proposal.fingerprint, checkpoint: checkpoint)
        })
    }
    func testNewWriterRequiresAllExistingWritersAndItsOwnCheckpointVote() throws {
        var state = initial()
        try state.requestJoin(.init(writer: b, label: "Second Mac"))
        XCTAssertTrue(state.mayEdit(a))
        XCTAssertFalse(state.mayEdit(b))
        let proposal = try state.proposal(checkpoint: "ready")
        XCTAssertThrowsError(try state.certify(proposal, votes: [.init(writer: a, proposal: proposal.fingerprint, checkpoint: "ready")]))
        XCTAssertThrowsError(try state.certify(proposal, votes: [
            .init(writer: a, proposal: proposal.fingerprint, checkpoint: "ready"),
            .init(writer: b, proposal: proposal.fingerprint, checkpoint: "old")]))
        try state.accept(certificate(state, checkpoint: "ready"))
        XCTAssertTrue(state.mayEdit(b))
        let decoded = try JSONDecoder().decode(SharedLibraryMembership.self, from: JSONEncoder().encode(state))
        XCTAssertTrue(decoded.mayEdit(b), "An admitted writer can restart/edit offline; no timeout")
    }
    func testConcurrentEnrollmentFrontiersSuspendNewWritersUntilUnionIsAcknowledged() throws {
        var left = initial(), right = initial()
        try left.requestJoin(.init(writer: b, label: "B"))
        try right.requestJoin(.init(writer: c, label: "C"))
        try left.accept(certificate(left))
        try right.accept(certificate(right))
        var joined = try left.merged(with: right)
        XCTAssertTrue(joined.mayEdit(a))
        XCTAssertFalse(joined.mayEdit(b))
        XCTAssertFalse(joined.mayEdit(c))
        XCTAssertEqual(joined.requiredVoters(for: try joined.proposal(checkpoint: "joined")), [a,b,c])
        try joined.accept(certificate(joined, checkpoint: "joined"))
        XCTAssertTrue(joined.mayEdit(b))
        XCTAssertTrue(joined.mayEdit(c))
        XCTAssertEqual(try joined.merged(with: left), joined, "Old membership delivery cannot reopen enrollment")
    }
    func testDeletedAudioRequiresExactStateAndCohortAndNoPendingWork() throws {
        var membership = initial()
        try membership.requestJoin(.init(writer: b, label: "B"))
        try membership.accept(certificate(membership))
        var entity = SharedEntityState(id: UUID(), kind: .recording)
        try entity.assign(field: "title", value: .text("Meeting"), writer: a)
        try entity.delete(writer: a)
        let revision = try SharedStateFingerprint.of(entity)
        let approvals = [a,b].map { SharedRemovalAcknowledgment(writer: $0, entity: entity.id,
            revision: revision, cohort: membership.fingerprint) }
        XCTAssertFalse(membership.mayRemoveAudio(entity, acknowledgments: Array(approvals.prefix(1)), hasPendingWork: false))
        XCTAssertFalse(membership.mayRemoveAudio(entity, acknowledgments: approvals, hasPendingWork: true))
        XCTAssertTrue(membership.mayRemoveAudio(entity, acknowledgments: approvals, hasPendingWork: false))
        var old = entity
        try old.restore(writer: b)
        XCTAssertFalse(membership.mayRemoveAudio(old, acknowledgments: approvals, hasPendingWork: false))
        try membership.requestJoin(.init(writer: c, label: "C"))
        XCTAssertFalse(membership.mayRemoveAudio(entity, acknowledgments: approvals, hasPendingWork: false))
    }
    func testStaleProposalCannotConsumeNewJoinAndWriterIDCannotBeReused() throws {
        var membership = initial()
        let request = SharedMembershipRequest(writer: b, label: "B")
        try membership.requestJoin(request)
        let approved = try certificate(membership)
        XCTAssertThrowsError(try membership.requestJoin(.init(writer: b, label: "Clone")))
        try membership.requestJoin(.init(writer: c, label: "C"))
        XCTAssertThrowsError(try membership.accept(approved))
        XCTAssertFalse(membership.mayEdit(b))
    }
    func testMalformedCertificateAndDifferentLibraryAreRejectedOnMergeAndDecode() throws {
        let one = initial()
        let other = SharedLibraryMembership(libraryID: UUID(), founder: a, bootstrapFingerprint: "bootstrap")
        XCTAssertThrowsError(try one.merged(with: other))
        var state = initial()
        try state.requestJoin(.init(writer: b, label: "B"))
        try state.accept(certificate(state))
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(state)) as? [String: Any])
        object["founder"] = c.uuidString
        XCTAssertThrowsError(try JSONDecoder().decode(SharedLibraryMembership.self, from: JSONSerialization.data(withJSONObject: object)))
    }
}
