// © 2026 High Gain Design. All rights reserved.
import XCTest
@testable import HiDockKit

final class SharedBootstrapContinuationTests: XCTestCase {
    private var roots: [URL] = []
    override func tearDown() { for root in roots { try? FileManager.default.removeItem(at: root) } }
    private struct Fixture {
        let root: URL
        let witness: URL
        let identity: SharedLibraryWriterIdentity
        let pending: SharedBootstrapManifest
        let originals: [String: Data]
    }
    private func interrupted() async throws -> Fixture {
        let parent = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString); roots.append(parent)
        let root = parent.appendingPathComponent("library"), witness = parent.appendingPathComponent("local")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let identity = try await SharedLibraryWriterIdentityStore(file: parent.appendingPathComponent("writer.json"), installationAnchor: "synthetic bootstrap continuation").load()
        for index in 0..<32 { try Data("Synthetic bootstrap conversation \(index)".utf8).write(to: root.appendingPathComponent(String(format: "Clip-%02d.mp3", index))) }
        let store = RecordingStore(baseDirectory: root); try await store.setup()
        try await store.setMeta(mode: "Rec", deviceFilename: "synthetic.hda", for: "Clip-00.mp3")
        try await TranscriptStore(baseDirectory: root).save(Transcript(recordingFilename: "Clip-00.mp3", transcriptionModel: "fixture", hasSpeakerLabels: false,
            segments: [.init(startTime: 0, endTime: 1, text: "Original bootstrap transcript")]), mp3Filename: "Clip-00.mp3")
        let originals = try Dictionary(uniqueKeysWithValues: ["Clip-00.mp3", "Clip-00.transcript.json", "library.json"].map { ($0, try Data(contentsOf: root.appendingPathComponent($0))) })
        let initial = SharedLibraryCoordinator(root: root, writerID: identity.writer, witnessDirectory: witness)
        let work = Task { try await initial.enable() }
        let file = root.appendingPathComponent(".docktape/format.json"), limit = ContinuousClock.now.advanced(by: .seconds(15))
        while !FileManager.default.fileExists(atPath: file.path) {
            guard ContinuousClock.now < limit else { work.cancel(); _ = try? await work.value; throw FixtureFailure.noIntent }
            try await Task.sleep(for: .milliseconds(1))
        }
        work.cancel()
        do { _ = try await work.value; throw FixtureFailure.completedBeforeInterruption }
        catch is CancellationError { }
        let bootstrap = LegacyLibraryBootstrap(root: root, writerID: identity.writer, witnessDirectory: witness)
        guard case .pending(let pending) = try await bootstrap.readiness(), !pending.complete else { throw FixtureFailure.noPendingIntent }
        return .init(root: root, witness: witness, identity: identity, pending: pending, originals: originals)
    }
    private enum FixtureFailure: Error { case noIntent, completedBeforeInterruption, noPendingIntent }

    func testFounderEnableContinuesActualInterruptedInitialBootstrap() async throws {
        let f = try await interrupted()
        let restarted = SharedLibraryCoordinator(root: f.root, writerID: f.identity.writer, witnessDirectory: f.witness)
        let resumable = try await restarted.canResumeBootstrap(); XCTAssertTrue(resumable)
        let ready = try await restarted.enable()
        let stillResumable = try await restarted.canResumeBootstrap(); XCTAssertFalse(stillResumable)
        XCTAssertTrue(ready.complete); XCTAssertEqual(ready.libraryID, f.pending.libraryID)
        XCTAssertEqual(ready.references, f.pending.references)
        let writable = try await restarted.mayEdit(); XCTAssertTrue(writable)
        for (name, bytes) in f.originals { XCTAssertEqual(try Data(contentsOf: f.root.appendingPathComponent(name)), bytes) }
    }
    func testFounderSessionEnableUsesSameGuardedContinuation() async throws {
        let f = try await interrupted()
        // The CLI shared-enable handler opens this exact session with enable:true.
        let session = try await RecordingLibrarySession.open(root: f.root, enable: true, witnessDirectory: f.witness, identity: { f.identity })
        try await session.requireWritable()
        let recordings = await session.recordings.allRecordings()
        XCTAssertEqual(recordings.count, 32)
        let transcript = try await session.transcripts.loadTranscript(for: "Clip-00.mp3")
        XCTAssertEqual(transcript?.plainText(), "Original bootstrap transcript")
        for (name, bytes) in f.originals { XCTAssertEqual(try Data(contentsOf: f.root.appendingPathComponent(name)), bytes) }
    }
    func testChangedInputsRefuseFounderContinuationWithoutRepairCopies() async throws {
        for changed in ["transcript", "metadata", "new-path"] {
            let f = try await interrupted(), format = f.root.appendingPathComponent(".docktape/format.json")
            let formatBytes = try Data(contentsOf: format)
            let changedFile: URL, bytes: Data
            if changed == "transcript" { changedFile = f.root.appendingPathComponent("Clip-00.transcript.json"); bytes = f.originals["Clip-00.transcript.json"]! + Data("\n".utf8) }
            else if changed == "metadata" { changedFile = f.root.appendingPathComponent("library.json"); bytes = Data("{\"Clip-00.mp3\":{\"mode\":\"Mee\"}}".utf8) }
            else { changedFile = f.root.appendingPathComponent("New.mp3"); bytes = Data("Newly imported synthetic conversation".utf8) }
            try bytes.write(to: changedFile, options: .atomic)
            let restarted = SharedLibraryCoordinator(root: f.root, writerID: f.identity.writer, witnessDirectory: f.witness)
            do { _ = try await restarted.enable(); XCTFail("Changed bootstrap input must not be silently reseeded") }
            catch LegacyBootstrapError.changedLegacyInput { }
            XCTAssertEqual(try Data(contentsOf: changedFile), bytes)
            XCTAssertEqual(try Data(contentsOf: format), formatBytes)
            XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: f.root.path).contains { $0.contains("backup") || $0.contains("recovery") })
        }
    }
    func testAudioOnlyChangeIsPreservedWithoutRewritingMedia() async throws {
        let f = try await interrupted(), audio = f.root.appendingPathComponent("Clip-00.mp3")
        let changed = Data("Changed synthetic audio remains the filesystem source of truth".utf8)
        try changed.write(to: audio, options: .atomic)
        let restarted = SharedLibraryCoordinator(root: f.root, writerID: f.identity.writer, witnessDirectory: f.witness)
        let ready = try await restarted.enable()
        XCTAssertEqual(ready.references, f.pending.references)
        XCTAssertEqual(try Data(contentsOf: audio), changed)
    }
    func testAnotherWriterCannotFinishFoundersInterruptedBootstrap() async throws {
        let f = try await interrupted(), before = try Data(contentsOf: f.root.appendingPathComponent(".docktape/format.json"))
        let other = SharedLibraryCoordinator(root: f.root, writerID: UUID(), witnessDirectory: f.root.deletingLastPathComponent().appendingPathComponent("other-local"))
        let resumable = try await other.canResumeBootstrap(); XCTAssertFalse(resumable)
        do { _ = try await other.enable(); XCTFail("Another Mac cannot finish the founder's upgrade") }
        catch LegacyBootstrapError.alreadyEnabled { }
        XCTAssertEqual(try Data(contentsOf: f.root.appendingPathComponent(".docktape/format.json")), before)
        for (name, bytes) in f.originals { XCTAssertEqual(try Data(contentsOf: f.root.appendingPathComponent(name)), bytes) }
    }
    func testCompletedManifestWithUndeliveredSeedCannotBeRebootstrapped() async throws {
        let f = try await interrupted()
        let ready = try await LegacyLibraryBootstrap(root: f.root, writerID: f.identity.writer, witnessDirectory: f.witness).resume()
        let recording = try XCTUnwrap(ready.references.first { $0.entity.kind == .recording })
        let file = f.root.appendingPathComponent(".docktape/records/" + recording.entity.id.uuidString.lowercased() + "/" + f.identity.writer.uuidString.lowercased() + ".json")
        try FileManager.default.removeItem(at: file) // A provider has not delivered this synthetic state file.
        let format = f.root.appendingPathComponent(".docktape/format.json"), before = try Data(contentsOf: format)
        let restarted = SharedLibraryCoordinator(root: f.root, writerID: f.identity.writer, witnessDirectory: f.witness)
        let resumable = try await restarted.canResumeBootstrap(); XCTAssertFalse(resumable)
        do { _ = try await restarted.enable(); XCTFail("Complete bootstrap metadata is not consent to recreate undelivered state") }
        catch LegacyBootstrapError.alreadyEnabled { }
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
        XCTAssertEqual(try Data(contentsOf: format), before)
    }
}
