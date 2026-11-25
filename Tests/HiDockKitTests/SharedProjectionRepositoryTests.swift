// © 2026 High Gain Design. All rights reserved.
import XCTest
@testable import HiDockKit

final class SharedProjectionRepositoryTests: XCTestCase {
    private var roots: [URL] = []
    private let a = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
    private let b = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
    private let entity = SharedEntityIdentity(
        id: UUID(uuidString: "10000000-0000-0000-0000-000000000001")!, kind: .recording)
    override func tearDown() {
        for root in roots { try? FileManager.default.removeItem(at: root) }
        roots = []
    }
    private func root() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        roots.append(url)
        return url
    }
    private func head(_ root: URL, _ writer: UUID) -> URL {
        root.appendingPathComponent(
            ".docktape/records/\(entity.id.uuidString.lowercased())/\(writer.uuidString.lowercased()).json")
    }
    private func deliver(_ source: URL, to target: URL) throws {
        try FileManager.default.createDirectory(
            at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(contentsOf: source).write(to: target, options: .atomic)
    }
    private func membership(_ manifest: SharedBootstrapManifest) throws -> SharedLibraryMembership {
        var group = SharedLibraryMembership(
            libraryID: manifest.libraryID, founder: a, bootstrapFingerprint: manifest.fingerprint)
        try group.requestJoin(.init(writer: b, label: "Second Mac"))
        let proposal = try group.proposal(checkpoint: "initial-content")
        try group.accept(
            group.certify(
                proposal,
                votes: [a, b].map { .init(writer: $0, proposal: proposal.fingerprint, checkpoint: "initial-content") }))
        return group
    }
    func testDurableVotesPublishCommonViewAndOldOwnerDeliveryCannotUndoIt() async throws {
        let left = try root()
        let right = try root()
        let manifest = try await LegacyLibraryBootstrap(root: left, writerID: a).enable()
        try FileManager.default.copyItem(
            at: left.appendingPathComponent(".docktape"), to: right.appendingPathComponent(".docktape"))
        let group = try membership(manifest)
        let one = SharedLibraryRepository(root: left, writerID: a, manifest: manifest)
        let two = SharedLibraryRepository(root: right, writerID: b, manifest: manifest)
        let initial = try await one.load(entity: entity)
        let doc = try SharedDocument(id: UUID(), json: Data("{\"text\":\"Common\"}".utf8))
        let edited = try await one.commit(.init(base: initial, changes: [.generation(doc, component: .transcript)]))
        let old = try Data(contentsOf: head(left, a))
        try deliver(head(left, a), to: head(right, a))
        let proposal = try SharedProjectionProposal(state: edited.state, membership: group)
        _ = try await one.acknowledgeProjection(proposal, base: edited)
        let incoming = try await two.load(entity: entity)
        _ = try await two.acknowledgeProjection(proposal, base: incoming)
        try deliver(head(right, b), to: head(left, b))
        let observed = try await one.load(entity: entity)
        let certificate = try proposal.certify(votes: Array(observed.projectionVotes.values))
        _ = try await one.publishProjection(certificate, base: observed, membership: group)
        try deliver(head(left, a), to: head(right, a))
        let accepted = try await two.load(entity: entity)
        _ = try await two.publishProjection(certificate, base: accepted, membership: group)
        try deliver(head(right, b), to: head(left, b))
        try old.write(to: head(left, a), options: .atomic)
        let restarted = SharedLibraryRepository(root: left, writerID: a, manifest: manifest)
        let replayed = try await restarted.load(entity: entity)
        XCTAssertEqual(
            replayed.projection?.state.currentDocument(for: .transcript)?.json, Data("{\"text\":\"Common\"}".utf8))
        XCTAssertEqual(replayed.state.compaction, certificate.state.compaction)
        XCTAssertTrue(replayed.state.conflicts.isEmpty)
        let before = try Data(contentsOf: head(right, b))
        let same = try await two.load(entity: entity)
        _ = try await two.publishProjection(certificate, base: same, membership: group)
        XCTAssertEqual(
            try Data(contentsOf: head(right, b)), before, "Publishing the same proof must not echo new revisions")
    }
    func testBareOrDifferentLibraryBindingCannotReadACompactedOwnerEnvelope() async throws {
        let directory = try root()
        let other = try root()
        let manifest = try await LegacyLibraryBootstrap(root: directory, writerID: a).enable()
        let foreign = try await LegacyLibraryBootstrap(root: other, writerID: a).enable()
        let repository = SharedLibraryRepository(root: directory, writerID: a, manifest: manifest)
        let first = try await repository.load(entity: entity)
        let accepted = try await repository.commit(
            .init(base: first, changes: [.assign(field: "title", value: .text("Common"))]))
        let group = SharedLibraryMembership(
            libraryID: manifest.libraryID, founder: a, bootstrapFingerprint: manifest.fingerprint)
        let proposal = try SharedProjectionProposal(state: accepted.state, membership: group)
        let voted = try await repository.acknowledgeProjection(proposal, base: accepted)
        let certificate = try proposal.certify(votes: Array(voted.projectionVotes.values))
        _ = try await repository.publishProjection(certificate, base: voted, membership: group)
        let bare = SharedLibraryRepository(root: directory, writerID: a)
        do {
            _ = try await bare.load(entity: entity)
            XCTFail()
        } catch { XCTAssertEqual(error as? SharedLibraryRepositoryError, .invalidEnvelope) }
        let wrong = SharedLibraryRepository(root: directory, writerID: a, manifest: foreign)
        do {
            _ = try await wrong.load(entity: entity)
            XCTFail()
        } catch { XCTAssertEqual(error as? SharedProjectionError, .differentLibrary) }
    }

    func testStaleVoteCannotAcknowledgeAChangedSameMacState() async throws {
        let directory = try root()
        let manifest = try await LegacyLibraryBootstrap(root: directory, writerID: a).enable()
        let repository = SharedLibraryRepository(root: directory, writerID: a, manifest: manifest)
        let empty = try await repository.load(entity: entity)
        let original = try await repository.commit(
            .init(base: empty, changes: [.assign(field: "title", value: .text("Original"))]))
        let group = SharedLibraryMembership(
            libraryID: manifest.libraryID, founder: a, bootstrapFingerprint: manifest.fingerprint)
        let proposal = try SharedProjectionProposal(state: original.state, membership: group)
        _ = try await repository.commit(
            .init(base: original, changes: [.assign(field: "title", value: .text("Newer"))]))
        let accepted = try Data(contentsOf: head(directory, a))
        do {
            _ = try await repository.acknowledgeProjection(proposal, base: original)
            XCTFail("Do not vote for a state replaced by another same-Mac process")
        } catch { XCTAssertEqual(error as? SharedLibraryRepositoryError, .staleRevision) }
        XCTAssertEqual(try Data(contentsOf: head(directory, a)), accepted)
    }
    func testPublishingOlderCommonProofRetainsALaterUserEditAndPendingJoinBlocksPublication() async throws {
        let directory = try root()
        let manifest = try await LegacyLibraryBootstrap(root: directory, writerID: a).enable()
        let repository = SharedLibraryRepository(root: directory, writerID: a, manifest: manifest)
        let empty = try await repository.load(entity: entity)
        let original = try await repository.commit(
            .init(base: empty, changes: [.assign(field: "title", value: .text("Common"))]))
        let group = SharedLibraryMembership(
            libraryID: manifest.libraryID, founder: a, bootstrapFingerprint: manifest.fingerprint)
        let proposal = try SharedProjectionProposal(state: original.state, membership: group)
        let voted = try await repository.acknowledgeProjection(proposal, base: original)
        let certificate = try proposal.certify(votes: Array(voted.projectionVotes.values))
        let newer = try await repository.commit(
            .init(base: voted, changes: [.assign(field: "title", value: .text("Later user edit"))]))
        let published = try await repository.publishProjection(certificate, base: newer, membership: group)
        XCTAssertEqual(published.state.value(for: "title"), .text("Later user edit"))
        XCTAssertEqual(published.projection?.state.value(for: "title"), .text("Common"))
        var changed = group
        try changed.requestJoin(.init(writer: b, label: "Pending Mac"))
        do {
            _ = try await repository.publishProjection(certificate, base: published, membership: changed)
            XCTFail()
        } catch { XCTAssertEqual(error as? SharedProjectionError, .notReady) }
    }
}
