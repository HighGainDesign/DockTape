// © 2026 High Gain Design. All rights reserved.
import XCTest
@testable import HiDockKit

final class RecordingLibrarySessionTests: XCTestCase {
    private var roots: [URL] = []
    override func tearDown() { for root in roots { try? FileManager.default.removeItem(at: root) } }
    private func fixture() async throws -> (URL, URL, SharedLibraryWriterIdentity) {
        let parent = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        roots.append(parent)
        let root = parent.appendingPathComponent("library")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("synthetic audio".utf8).write(to: root.appendingPathComponent("A.mp3"))
        let writer = try await SharedLibraryWriterIdentityStore(file: parent.appendingPathComponent("identity.json"), installationAnchor: "fixture").load()
        return (root, parent.appendingPathComponent("witness"), writer)
    }
    func testLegacyReadDoesNotAcquireSharedIdentityOrEnableFormat() async throws {
        let (root, witness, _) = try await fixture()
        let session = try await RecordingLibrarySession.open(root: root, witnessDirectory: witness, identity: { throw SharedWriterIdentityError.hardwareUnavailable })
        XCTAssertNil(session.coordinator)
        let recordings = await session.pipeline.allRecordings()
        XCTAssertEqual(recordings.map(\.filename), ["A.mp3"])
        try await session.requireWritable()
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent(".docktape").path))
    }
    func testSharedSessionUsesExistingWriterAndActualConditionalStores() async throws {
        let (root, witness, writer) = try await fixture()
        let owner = SharedLibraryCoordinator(root: root, writerID: writer.writer, witnessDirectory: witness)
        _ = try await owner.enable(); _ = try await owner.projectOutputs()
        let session = try await RecordingLibrarySession.open(root: root, witnessDirectory: witness, identity: { writer })
        let coordinator = try XCTUnwrap(session.coordinator)
        XCTAssertEqual(coordinator.writerID, owner.writerID)
        try await session.requireWritable()
        let ref = try await owner.reference(to: "A.mp3")
        let entity = SharedEntityIdentity(id: ref.entityID, kind: .recording)
        _ = try await owner.edit(.init(base: try await owner.read(entity), changes: [.assign(field: "metadata.recordedAt", value: .text("123"))]))
        try await session.recordings.setMeta(mode: "Wip", deviceFilename: "source.hda", for: "A.mp3")
        let result = try await owner.read(entity)
        XCTAssertEqual(result.state.value(for: "metadata.mode"), .text("\"Wip\""))
        XCTAssertEqual(result.state.value(for: "metadata.deviceFilename"), .text("\"source.hda\""))
        XCTAssertEqual(result.state.value(for: "metadata.recordedAt"), .text("123"))
        let transcript = Transcript(recordingFilename: "A.mp3", transcriptionModel: "fixture", hasSpeakerLabels: false, segments: [.init(startTime: 0, endTime: 1, text: "Session writes through shared authority")])
        try await session.transcripts.save(transcript, mp3Filename: "A.mp3")
        let reloaded = TranscriptStore(baseDirectory: root, shared: SharedSidecarAdapter(coordinator: owner))
        try await reloaded.loadAll()
        let saved = await reloaded.transcript(for: "A.mp3")
        XCTAssertEqual(saved?.segments.first?.text, transcript.segments.first?.text)
    }
    func testUnknownWriterCanReadButMustEnrollBeforeAnyWrite() async throws {
        let (root, witness, owner) = try await fixture()
        let founder = SharedLibraryCoordinator(root: root, writerID: owner.writer, witnessDirectory: witness)
        _ = try await founder.enable(); _ = try await founder.projectOutputs()
        let peer = try await SharedLibraryWriterIdentityStore(file: witness.deletingLastPathComponent().appendingPathComponent("peer.json"), installationAnchor: "peer").load()
        let session = try await RecordingLibrarySession.open(root: root, witnessDirectory: witness, identity: { peer })
        let recordings = await session.pipeline.allRecordings()
        XCTAssertEqual(recordings.count, 1)
        do { try await session.requireWritable(); XCTFail("Read-only membership must stop writes before expensive work") }
        catch RecordingLibrarySessionError.enrollmentRequired {}
        try await session.requestAccess()
        try await founder.refresh()
        try await session.refresh()
        try await session.requireWritable()
    }
    func testSharedIdentityFailureDoesNotFallBackToLegacyWrites() async throws {
        let (root, witness, writer) = try await fixture()
        let founder = SharedLibraryCoordinator(root: root, writerID: writer.writer, witnessDirectory: witness)
        _ = try await founder.enable(); _ = try await founder.projectOutputs()
        let before = try Data(contentsOf: root.appendingPathComponent("library.json"))
        do {
            _ = try await RecordingLibrarySession.open(root: root, witnessDirectory: witness, identity: { throw SharedWriterIdentityError.hardwareUnavailable })
            XCTFail("Fail closed")
        } catch SharedWriterIdentityError.hardwareUnavailable {}
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("library.json")), before)
    }
}
