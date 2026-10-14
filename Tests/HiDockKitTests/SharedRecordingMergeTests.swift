// © 2026 High Gain Design. All rights reserved.
import XCTest
@testable import HiDockKit

final class SharedRecordingMergeTests: XCTestCase {
    private var roots: [URL] = []
    override func tearDown() { for root in roots { try? FileManager.default.removeItem(at: root) } }
    private func frame(_ fill: UInt8) -> Data {
        var bytes = Data(repeating: fill, count: 417)
        bytes.replaceSubrange(0..<4, with: [0xFF, 0xFB, 0x90, 0x64])
        return bytes
    }
    private func fixture() async throws -> (URL, SharedLibraryCoordinator, RecordingStore, [String]) {
        let parent = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        roots.append(parent)
        let root = parent.appendingPathComponent("library")
        let legacy = RecordingStore(baseDirectory: root)
        try await legacy.setup()
        let names = ["REC_20240201_100000", "REC_20240202_100000"]
        for (index, name) in names.enumerated() {
            let bytes = frame(UInt8(index + 1))
            _ = try await legacy.importRecording(hdaData: bytes, entry: FileEntry(filename: name + ".hda", size: UInt32(bytes.count)))
            try await legacy.setMeta(mode: index == 0 ? "Mee" : "Call", deviceFilename: name + ".hda", for: name + ".mp3")
        }
        try await legacy.createFolder(named: "Archive")
        _ = try await legacy.moveRecording(filename: names[1] + ".mp3", toFolder: "Archive")
        let coordinator = SharedLibraryCoordinator(root: root, writerID: UUID(), witnessDirectory: parent.appendingPathComponent("local"))
        _ = try await coordinator.enable(); _ = try await coordinator.projectOutputs()
        let store = RecordingStore(baseDirectory: root, shared: SharedRecordingMetadataAdapter(coordinator: coordinator))
        try await store.setup()
        return (root, coordinator, store, ["Archive/" + names[1] + ".mp3", names[0] + ".mp3"])
    }
    func testActualSharedMergePreservesOriginalsDateModeAndNestedProvenance() async throws {
        let (root, coordinator, store, sources) = try await fixture()
        let original = try sources.map { try Data(contentsOf: root.appendingPathComponent($0)) }
        let result = try await store.mergeRecordings(filenames: sources, as: "Joined")
        XCTAssertEqual(result.filename, "Joined.mp3")
        XCTAssertNotNil(result.reference)
        XCTAssertEqual(result.recordedAt, FilenameParsing.parse(sources[1]).date)
        XCTAssertEqual(result.mode, "Call")
        let files = await store.allRecordings()
        XCTAssertEqual(files.count, 3)
        for (path, data) in zip(sources, original) { XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent(path)), data) }
        let merged = try Data(contentsOf: root.appendingPathComponent(result.filename))
        XCTAssertEqual(merged.suffix(834), original[0] + original[1])
        let view = try await coordinator.recording(at: result.filename)
        let metadata = try SharedRecordingMetadataAdapter.render(view)
        XCTAssertEqual(metadata.mergedFrom, sources)
        XCTAssertNil(metadata.deviceFilename)
        XCTAssertEqual(metadata.audioSHA256, SharedLibraryOperation.fingerprint(merged))
        XCTAssertNil(view.state.currentDocument(for: .transcript))
        XCTAssertNil(view.state.currentDocument(for: .summary))
        XCTAssertTrue(LibraryFileDiscovery.files(in: root.appendingPathComponent(".docktape/staging"), suffix: ".mp3").isEmpty)
    }
    func testMergeCancelledAfterAcceptanceResumesWithoutRecomputingInputs() async throws {
        let (root, coordinator, _, sources) = try await fixture()
        let originals = try sources.map { try Data(contentsOf: root.appendingPathComponent($0)) }
        let interrupted = SharedLibraryCoordinator(root: root, writerID: coordinator.writerID,
            witnessDirectory: root.deletingLastPathComponent().appendingPathComponent("local"),
            afterCommit: { withUnsafeCurrentTask { $0?.cancel() } })
        let task = Task { try await interrupted.mergeRecordings(filenames: sources, as: "Interrupted.mp3") }
        do { _ = try await task.value; XCTFail("Cancellation after acceptance") } catch is CancellationError {}
        let accepted = try await coordinator.recording(at: "Interrupted.mp3")
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("Interrupted.mp3").path))
        // Recovery must consume the accepted output, regardless of later input changes.
        try Data("later source change".utf8).write(to: root.appendingPathComponent(sources[0]), options: .atomic)
        let reopened = SharedLibraryCoordinator(root: root, writerID: coordinator.writerID,
            witnessDirectory: root.deletingLastPathComponent().appendingPathComponent("local"))
        let resumed = try await reopened.resumeRecordingOperation(id: accepted.state.id)
        XCTAssertEqual(resumed.result, .complete)
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("Interrupted.mp3")).suffix(834), originals[0] + originals[1])
        XCTAssertTrue(LibraryFileDiscovery.files(in: root.appendingPathComponent(".docktape/staging"), suffix: ".mp3").isEmpty)
    }
    func testMergeCancellationBeforeAcceptanceCleansOnlyStagedInputAndGrantsNoPhysicalPermission() async throws {
        let (root, coordinator, _, sources) = try await fixture()
        let originals = try sources.map { try Data(contentsOf: root.appendingPathComponent($0)) }
        let task = Task {
            try await coordinator.mergeRecordings(filenames: sources, as: "Never accepted.mp3", beforeCommit: {
                let staged = LibraryFileDiscovery.files(in: root.appendingPathComponent(".docktape/staging"), suffix: ".mp3")
                XCTAssertEqual(staged.count, 1, "New output must be staged before acceptance")
                let idText = URL(fileURLWithPath: staged[0].relativePath).deletingLastPathComponent().lastPathComponent
                let id = try XCTUnwrap(UUID(uuidString: idText))
                do {
                    _ = try await coordinator.operationAuthority(entity: .init(id: id, kind: .recording), paths: [])
                    XCTFail("Unpublished staging entity has no ordinary physical permission")
                } catch SharedSidecarError.unknownRecording {}
                withUnsafeCurrentTask { $0?.cancel() }
            })
        }
        do { _ = try await task.value; XCTFail("Cancellation before acceptance") } catch is CancellationError {}
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("Never accepted.mp3").path))
        XCTAssertTrue(LibraryFileDiscovery.files(in: root.appendingPathComponent(".docktape/staging"), suffix: ".mp3").isEmpty)
        for (source, bytes) in zip(sources, originals) { XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent(source)), bytes) }
    }
    func testIntentionalRepeatedMergeCreatesDistinctIdentitiesForIdenticalAudio() async throws {
        let (root, _, store, sources) = try await fixture()
        let first = try await store.mergeRecordings(filenames: sources, as: "First joined")
        let second = try await store.mergeRecordings(filenames: sources, as: "Second joined")
        XCTAssertNotEqual(first.reference, second.reference)
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent(first.filename)), try Data(contentsOf: root.appendingPathComponent(second.filename)))
    }
    func testMergeRejectsPhysicalInputChangeAtAcceptedWriteAndReleasesLeases() async throws {
        let (root, coordinator, _, sources) = try await fixture()
        do {
            _ = try await coordinator.mergeRecordings(filenames: sources, as: "Rejected.mp3", beforeCommit: {
                try Data("external replacement".utf8).write(to: root.appendingPathComponent(sources[0]), options: .atomic)
            })
            XCTFail("Changed physical source must invalidate the merge")
        } catch SharedLibraryRepositoryError.staleRevision {}
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("Rejected.mp3").path))
        XCTAssertTrue(LibraryFileDiscovery.files(in: root.appendingPathComponent(".docktape/staging"), suffix: ".mp3").isEmpty, "Rejected output must not accumulate staged audio")
        for source in sources {
            let entity = SharedEntityIdentity(id: try await coordinator.reference(to: source).entityID, kind: .recording)
            let permission = try await coordinator.operationAuthority(entity: entity, paths: [])
            XCTAssertFalse(permission.hasPendingWork, "Failed merge must release every source lease")
        }
    }
    func testMergeRejectsDeletedInputAtAcceptedWrite() async throws {
        let (root, coordinator, _, sources) = try await fixture()
        let reference = try await coordinator.reference(to: sources[0])
        do {
            _ = try await coordinator.mergeRecordings(filenames: sources, as: "Rejected.mp3", beforeCommit: {
                let view = try await coordinator.read(.init(id: reference.entityID, kind: .recording))
                _ = try await coordinator.edit(.init(base: view, changes: [.delete]))
            })
            XCTFail("Deletion between computation and accepted write must invalidate merge")
        } catch SharedLibraryRepositoryError.staleRevision {}
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("Rejected.mp3").path))
        XCTAssertTrue(LibraryFileDiscovery.files(in: root.appendingPathComponent(".docktape/staging"), suffix: ".mp3").isEmpty, "Rejected output must not accumulate staged audio")
        let permission = try await coordinator.operationAuthority(entity: .init(id: reference.entityID, kind: .recording), paths: [])
        XCTAssertFalse(permission.hasPendingWork)
    }

    func testMergeRejectsNewProviderHeadArrivingAtAcceptedWrite() async throws {
        let (root, coordinator, _, sources) = try await fixture()
        let reference = try await coordinator.reference(to: sources[0])
        let directory = root.appendingPathComponent(".docktape/records/" + reference.entityID.uuidString.lowercased())
        let head = directory.appendingPathComponent(coordinator.writerID.uuidString.lowercased() + ".json")
        do {
            _ = try await coordinator.mergeRecordings(filenames: sources, as: "Rejected.mp3", beforeCommit: {
                try Data(contentsOf: head).write(to: directory.appendingPathComponent("provider conflict copy.json"), options: .atomic)
            })
            XCTFail("A newly arriving source head must invalidate the held source set")
        } catch SharedLibraryRepositoryError.staleRevision {}
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("Rejected.mp3").path))
        XCTAssertTrue(LibraryFileDiscovery.files(in: root.appendingPathComponent(".docktape/staging"), suffix: ".mp3").isEmpty, "Rejected output must not accumulate staged audio")
    }

    func testMergeRejectsDeletionBetweenJobValidationAndSourceProof() async throws {
        let (root, coordinator, _, sources) = try await fixture()
        let reference = try await coordinator.reference(to: sources[0])
        do {
            _ = try await coordinator.mergeRecordings(filenames: sources, as: "Rejected.mp3", beforeSourceProof: { entity in
                if entity.id == reference.entityID {
                    let current = try await coordinator.read(entity)
                    _ = try await coordinator.edit(.init(base: current, changes: [.delete]))
                }
            })
            XCTFail("A fresh source proof must still describe the pinned alive input")
        } catch SharedLibraryCoordinatorError.staleJob {}
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("Rejected.mp3").path))
        XCTAssertTrue(LibraryFileDiscovery.files(in: root.appendingPathComponent(".docktape/staging"), suffix: ".mp3").isEmpty, "Rejected output must not accumulate staged audio")
    }

}
