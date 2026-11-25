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
    private actor FirstVisit {
        var count = 0
        func once() -> Bool { count += 1; return count == 1 }
        func next() -> Int { count += 1; return count }
    }
    func testJobPreparationSurvivesMaintenanceWithoutChangingItsSelectedInput() async throws {
        let (coordinator, entity) = try await fixture()
        let transcript = Transcript(recordingFilename: "Meeting.mp3", transcriptionModel: "fixture", hasSpeakerLabels: false,
            segments: [.init(startTime: 0, endTime: 1, text: "Selected input")])
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        let original = try await coordinator.read(entity)
        _ = try await coordinator.edit(.init(base: original, changes: [.generation(try SharedDocument(id: UUID(), json: encoder.encode(transcript)), component: .transcript)]))
        let before = try await coordinator.read(entity)
        let stage = FirstVisit()
        let token = try await coordinator.pinJob(entity, input: .transcript, output: .summary, beforeLease: {
            guard await stage.once() else { return }
            let witness = SharedOwnerWitness(directory: coordinator.root.deletingLastPathComponent().appendingPathComponent("local"), libraryID: before.libraryID, writerID: coordinator.writerID)
            let checkpoint = try witness.checkpointFingerprint()
            try await coordinator.refresh()
            let after = try await coordinator.read(entity)
            XCTAssertEqual(after.state.fields["$lifecycle"], before.state.fields["$lifecycle"])
            XCTAssertEqual(after.state.currentDocument(for: .transcript), before.state.currentDocument(for: .transcript))
            XCTAssertNotEqual(try witness.checkpointFingerprint(), checkpoint, "Actual maintenance advances the checkpoint without changing the job input")
        })
        let selected = try await coordinator.transcriptForJob(token, filename: "Meeting.mp3")
        XCTAssertEqual(selected?.plainText(), "Selected input")
        await coordinator.finishJob(token)
    }

    func testPreparationRetryDoesNotAcceptChangedInputOrLifecycle() async throws {
        for restore in [false, true] {
            let (coordinator, entity) = try await fixture()
            let stage = FirstVisit()
            do {
                _ = try await coordinator.pinJob(entity, output: .transcript, beforeLease: {
                    guard await stage.once() else { return }
                    let current = try await coordinator.read(entity)
                    if restore {
                        let deleted = try await coordinator.edit(.init(base: current, changes: [.delete]))
                        _ = try await coordinator.edit(.init(base: deleted, changes: [.restore]))
                    } else {
                        _ = try await coordinator.edit(.init(base: current, changes: [.assign(field: "audioFingerprint", value: .text(String(repeating: "a", count: 64)))]))
                    }
                })
                XCTFail("Maintenance retry cannot retarget a changed input or a restored lifecycle")
            } catch SharedLibraryCoordinatorError.staleJob {}
            let visits = await stage.count
            XCTAssertEqual(visits, 1, "Changed semantic input/lifecycle is rejected before another lease attempt")
        }
    }
    func testPreparationProofRetriesAreBoundedDuringUnrelatedEdits() async throws {
        let (coordinator, entity) = try await fixture()
        try await coordinator.createSharedFolder(named: "Unrelated")
        let folders = try await coordinator.snapshots(kinds: [.folder])
        let folder = try XCTUnwrap(folders.first)
        let other = SharedEntityIdentity(id: folder.state.id, kind: .folder)
        let original = try await coordinator.read(entity)
        let stage = FirstVisit()
        do {
            _ = try await coordinator.pinJob(entity, output: .transcript, beforeLease: {
                let index = await stage.next()
                let current = try await coordinator.read(other)
                _ = try await coordinator.edit(.init(base: current, changes: [.assign(field: "name", value: .text("Unrelated " + String(index)))]))
            })
            XCTFail("Continually invalidated physical preparation must stop")
        } catch SharedLibraryCoordinatorError.staleJob {}
        let visits = await stage.count
        XCTAssertEqual(visits, 3)
        let after = try await coordinator.read(entity)
        XCTAssertEqual(after.state, original.state, "Retries cannot edit or retarget the selected recording")
    }
    func testCancelledPreparationDoesNotRetryOrPinAJob() async throws {
        let (coordinator, entity) = try await fixture()
        let stage = FirstVisit()
        do {
            _ = try await coordinator.pinJob(entity, beforeLease: { _ = await stage.next(); throw CancellationError() })
            XCTFail("Cancelled preparation must not succeed")
        } catch is CancellationError {}
        let visits = await stage.count
        XCTAssertEqual(visits, 1)
    }

    func testPreparationRetryDoesNotRetargetUnfingerprintedLegacyAudio() async throws {
        let (coordinator, entity) = try await fixture()
        let stage = FirstVisit()
        let audio = coordinator.root.appendingPathComponent("Meeting.mp3")
        let token = try await coordinator.pinJob(entity, output: .transcript, audioURL: audio, beforeLease: {
            guard await stage.once() else { return }
            try await coordinator.refresh()
            try Data("Different external audio".utf8).write(to: audio, options: .atomic)
        })
        let result = try SharedDocument(id: UUID(), json: Data("{}".utf8))
        do { _ = try await coordinator.commitJob(token, document: result, component: .transcript); XCTFail("Preparation retry must retain the original physical input binding") }
        catch SharedLibraryCoordinatorError.staleJob {}
        await coordinator.finishJob(token)
        let after = try await coordinator.read(entity)
        XCTAssertNil(after.state.currentDocument(for: .transcript))
    }

    func testPreparationRetryRejectsAncestorNameChangeBeforeMaterialization() async throws {
        let (coordinator, entity) = try await fixture()
        try await coordinator.createSharedFolder(named: "One")
        let moved = try await coordinator.relocateRecording(filename: "Meeting.mp3", toFolder: "One", changeFolder: true)
        XCTAssertEqual(moved.result, .complete)
        let folders = try await coordinator.snapshots(kinds: [.folder])
        let folder = try XCTUnwrap(folders.first { $0.state.value(for: "name") == .text("One") })
        let parent = SharedEntityIdentity(id: folder.state.id, kind: .folder)
        let audio = coordinator.root.appendingPathComponent("One/Meeting.mp3")
        let stage = FirstVisit()
        do {
            let token = try await coordinator.pinJob(entity, audioURL: audio, beforeLease: {
                guard await stage.once() else { return }
                let current = try await coordinator.read(parent)
                _ = try await coordinator.edit(.init(base: current, changes: [.assign(field: "name", value: .text("Two"))]))
            })
            await coordinator.finishJob(token)
            XCTFail("A changed ancestor must invalidate the originally selected audio path")
        } catch SharedLibraryCoordinatorError.staleJob {}
        XCTAssertTrue(FileManager.default.fileExists(atPath: audio.path), "Semantic edit does not materialize a file move")
        XCTAssertFalse(FileManager.default.fileExists(atPath: coordinator.root.appendingPathComponent("Two/Meeting.mp3").path))
    }

    func testAncestorChangeBeforeWitnessCaptureInvalidatesPathProof() async throws {
        let (coordinator, entity) = try await fixture()
        try await coordinator.createSharedFolder(named: "One")
        let moved = try await coordinator.relocateRecording(filename: "Meeting.mp3", toFolder: "One", changeFolder: true)
        XCTAssertEqual(moved.result, .complete)
        let folders = try await coordinator.snapshots(kinds: [.folder])
        let folder = try XCTUnwrap(folders.first { $0.state.value(for: "name") == .text("One") })
        let parent = SharedEntityIdentity(id: folder.state.id, kind: .folder)
        let stage = FirstVisit()
        do {
            let token = try await coordinator.pinJob(entity,
                audioURL: coordinator.root.appendingPathComponent("One/Meeting.mp3"), afterPathValidation: {
                    guard await stage.once() else { return }
                    let current = try await coordinator.read(parent)
                    _ = try await coordinator.edit(.init(base: current, changes: [.assign(field: "name", value: .text("Two"))]))
                }, beforeLease: {})
            await coordinator.finishJob(token)
            XCTFail("The path's ancestor evidence must survive through lease acquisition")
        } catch SharedLibraryCoordinatorError.staleJob {}
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
