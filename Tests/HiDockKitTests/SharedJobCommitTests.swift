// © 2026 High Gain Design. All rights reserved.
import XCTest
@testable import HiDockKit

final class SharedJobCommitTests: XCTestCase {
    private var roots: [URL] = []
    override func tearDown() { for root in roots { try? FileManager.default.removeItem(at: root) } }
    private func fixture() async throws -> (SharedLibraryCoordinator, SharedEntityIdentity) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        roots.append(directory)
        let root = directory.appendingPathComponent("library")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("synthetic input".utf8).write(to: root.appendingPathComponent("Meeting.mp3"))
        let coordinator = SharedLibraryCoordinator(root: root, writerID: UUID(), witnessDirectory: directory.appendingPathComponent("local"))
        let manifest = try await coordinator.enable()
        return (coordinator, manifest.references.first { $0.entity.kind == .recording }!.entity)
    }
    func testOldOrdinaryReviewCannotRestoreAnObservedDeletion() async throws {
        let (coordinator, entity) = try await fixture()
        let old = try await coordinator.read(entity)
        _ = try await coordinator.edit(.init(base: old, changes: [.delete]))
        do { _ = try await coordinator.edit(.init(base: old, changes: [.assign(field: "metadata.mode", value: .text("Mee"))])); XCTFail("Stale edit must not restore") }
        catch SharedEntityError.deletedOrConflictedLifecycle {}
        let after = try await coordinator.read(entity)
        XCTAssertEqual(after.state.lifecycle, .deleted)
    }
    func testKnownDeletionRequiresExplicitRestoreBeforeOrdinaryEditing() async throws {
        let (coordinator, entity) = try await fixture()
        let initial = try await coordinator.read(entity)
        let deleted = try await coordinator.edit(.init(base: initial, changes: [.delete]))
        do { _ = try await coordinator.edit(.init(base: deleted, changes: [.assign(field: "metadata.mode", value: .text("Mee"))])); XCTFail("Known deletion requires restore") }
        catch SharedEntityError.deletedOrConflictedLifecycle {}
        let restored = try await coordinator.edit(.init(base: try await coordinator.read(entity), changes: [.restore]))
        XCTAssertEqual(restored.state.lifecycle, .alive)
    }
    func testJobCannotConsumeAnAudioReplacementBetweenValidationAndWrite() async throws {
        let (coordinator, entity) = try await fixture()
        let token = try await coordinator.pinJob(entity)
        let document = try SharedDocument(id: UUID(), json: Data("{\"text\":\"Old input result\"}".utf8))
        do {
            _ = try await coordinator.commitJob(token, document: document, component: .transcript, beforeCommit: {
                let current = try await coordinator.read(entity)
                _ = try await coordinator.edit(.init(base: current, changes: [.assign(field: "audioFingerprint", value: .text(String(repeating: "a", count: 64)))]))
            })
            XCTFail("Required input changed")
        } catch SharedLibraryCoordinatorError.staleJob {}
        let after = try await coordinator.read(entity)
        XCTAssertNil(after.state.currentDocument(for: .transcript))
    }
    func testFinishingJobDuringCommitPreparationRevokesItsWrite() async throws {
        let (coordinator, entity) = try await fixture()
        let token = try await coordinator.pinJob(entity)
        let document = try SharedDocument(id: UUID(), json: Data("{}".utf8))
        do {
            _ = try await coordinator.commitJob(token, document: document, component: .transcript, beforeCommit: { await coordinator.finishJob(token) })
            XCTFail("Finished job must not publish")
        } catch SharedLibraryCoordinatorError.staleJob {}
        let after = try await coordinator.read(entity)
        XCTAssertNil(after.state.currentDocument(for: .transcript))
    }
    func testValidJobReturnsItsAcceptedGeneration() async throws {
        let (coordinator, entity) = try await fixture()
        let token = try await coordinator.pinJob(entity)
        let document = try SharedDocument(id: UUID(), json: Data("{}".utf8))
        let accepted = try await coordinator.commitJob(token, document: document, component: .transcript)
        XCTAssertEqual(accepted.state.currentDocument(for: .transcript)?.id, document.id)
        await coordinator.finishJob(token)
    }
    func testPeerInputArrivingDuringCommitPreparationIsNotIgnored() async throws {
        let (coordinator, entity) = try await fixture()
        let peer = SharedLibraryCoordinator(root: coordinator.root, writerID: UUID(), witnessDirectory: coordinator.root.deletingLastPathComponent().appendingPathComponent("peer-local"))
        try await peer.requestEnrollment(requestID: UUID(), label: "Peer")
        try await coordinator.refresh(); try await peer.refresh(); try await coordinator.refresh()
        let token = try await coordinator.pinJob(entity)
        let document = try SharedDocument(id: UUID(), json: Data("{}".utf8))
        do {
            _ = try await coordinator.commitJob(token, document: document, component: .transcript, beforeCommit: {
                let view = try await peer.read(entity)
                _ = try await peer.edit(.init(base: view, changes: [.assign(field: "audioFingerprint", value: .text(String(repeating: "b", count: 64)))]))
            })
            XCTFail("Peer changed required input")
        } catch SharedLibraryCoordinatorError.staleJob {}
        let after = try await coordinator.read(entity)
        XCTAssertNil(after.state.currentDocument(for: .transcript))
    }

    func testJobCannotResolveCompetingOutputGenerationsWithoutReview() async throws {
        let (coordinator, entity) = try await fixture()
        let peer = SharedLibraryCoordinator(root: coordinator.root, writerID: UUID(), witnessDirectory: coordinator.root.deletingLastPathComponent().appendingPathComponent("peer-local"))
        try await peer.requestEnrollment(requestID: UUID(), label: "Peer")
        try await coordinator.refresh(); try await peer.refresh(); try await coordinator.refresh()
        guard case .ready(let manifest) = try await LegacyLibraryBootstrap(root: coordinator.root, writerID: coordinator.writerID).publishedManifest() else { return XCTFail("Ready fixture") }
        let repository = SharedLibraryRepository(root: coordinator.root, writerID: peer.writerID, manifest: manifest)
        let offline = try await repository.load(entity: entity)
        let first = try SharedDocument(id: UUID(), json: Data("{\"text\":\"First\"}".utf8))
        let second = try SharedDocument(id: UUID(), json: Data("{\"text\":\"Second\"}".utf8))
        _ = try await coordinator.edit(.init(base: try await coordinator.read(entity), changes: [.generation(first, component: .transcript)]))
        _ = try await repository.commit(.init(base: offline, changes: [.generation(second, component: .transcript)]))
        let token = try await coordinator.pinJob(entity)
        let replacement = try SharedDocument(id: UUID(), json: Data("{}".utf8))
        do { _ = try await coordinator.commitJob(token, document: replacement, component: .transcript); XCTFail("Jobs cannot resolve a generation conflict") }
        catch SharedLibraryCoordinatorError.staleJob {}
        let current = try await coordinator.read(entity)
        XCTAssertEqual(Set(current.state.generationValues(for: .transcript).map(\.id)), [first.id, second.id])
    }

    func testConditionalRepositoryBindingCannotReadOutsideLibraryWithWitnessEnabled() async throws {
        let (coordinator, entity) = try await fixture()
        guard case .ready(let manifest) = try await LegacyLibraryBootstrap(root: coordinator.root, writerID: coordinator.writerID).publishedManifest() else { return XCTFail("Ready fixture") }
        let repository = SharedLibraryRepository(root: coordinator.root, writerID: coordinator.writerID, manifest: manifest,
            witness: SharedOwnerWitness(directory: coordinator.root.deletingLastPathComponent().appendingPathComponent("local"), libraryID: manifest.libraryID, writerID: coordinator.writerID))
        let base = try await repository.load(entity: entity)
        let outside = coordinator.root.deletingLastPathComponent().appendingPathComponent("outside.json")
        try Data("{}".utf8).write(to: outside)
        do {
            _ = try await repository.commit(.init(base: base, changes: [], validation: { _ in }, bindings: [.init(file: outside, validate: { _ in true })]))
            XCTFail("Witness route must validate related read boundaries")
        } catch SharedLibraryRepositoryError.invalidPath {}
    }

}
