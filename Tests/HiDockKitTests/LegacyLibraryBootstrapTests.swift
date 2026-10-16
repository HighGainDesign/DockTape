// © 2026 High Gain Design. All rights reserved.
import XCTest
@testable import HiDockKit

final class LegacyLibraryBootstrapTests: XCTestCase {
    private var roots: [URL] = []
    override func tearDown() { for root in roots { try? FileManager.default.removeItem(at: root) }; roots = [] }
    private func root() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        roots.append(url); return url
    }
    private func seed(_ root: URL) throws -> (Data, Data, Data) {
        let audio = Data("synthetic audio bytes; bootstrap must not rewrite these".utf8)
        let transcript = try JSONEncoder().encode(Transcript(recordingFilename: "Meeting.mp3", createdAt: Date(timeIntervalSince1970: 100),
            transcriptionModel: "fixture", hasSpeakerLabels: true, segments: [.init(startTime: 0, endTime: 1, text: "Hello", speakerID: "A")], speakerNames: ["A":"Sam"]))
        let metadata = Data("{\"Meeting.mp3\":{\"mode\":\"Pho\",\"deviceFilename\":\"Original.hda\",\"recordedAt\":123,\"sourceMD5\":\"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\",\"audioSHA256\":\"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb\",\"unknownFutureKey\":\"preserve\"}}".utf8)
        try audio.write(to: root.appendingPathComponent("Meeting.mp3"))
        try transcript.write(to: root.appendingPathComponent("Meeting.transcript.json"))
        try metadata.write(to: root.appendingPathComponent("library.json"))
        return (audio,transcript,metadata)
    }
    func testBootstrapPreservesAudioAndAllLegacyMetadataAndSegmentIDs() async throws {
        let directory = try root(), writer = UUID()
        let originals = try seed(directory)
        let bootstrap = LegacyLibraryBootstrap(root: directory, writerID: writer)
        let manifest = try await bootstrap.enable()
        XCTAssertEqual(manifest.references.count, 1)
        let readiness = try await bootstrap.readiness()
        XCTAssertEqual(readiness, .ready(manifest))
        XCTAssertEqual(try Data(contentsOf: directory.appendingPathComponent("Meeting.mp3")), originals.0)
        XCTAssertEqual(try Data(contentsOf: directory.appendingPathComponent("Meeting.transcript.json")), originals.1)
        XCTAssertEqual(try Data(contentsOf: directory.appendingPathComponent("library.json")), originals.2)
        let repository = SharedLibraryRepository(root: directory, writerID: writer)
        let state = try await repository.load(entity: .init(id: manifest.references[0].entity.id, kind: .recording)).state
        XCTAssertEqual(state.value(for: "initialPath"), .text("Meeting.mp3"))
        let document = try XCTUnwrap(state.currentDocument(for: .transcript))
        let restored = try JSONDecoder().decode(Transcript.self, from: document.json)
        let original = try JSONDecoder().decode(Transcript.self, from: originals.1)
        XCTAssertEqual(restored.segments[0].id, original.segments[0].id)
        guard case .document(let meta)? = state.value(for: "legacyMetadata") else { return XCTFail("Missing metadata") }
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: meta.json) as? [String:Any])
        XCTAssertEqual(object["unknownFutureKey"] as? String, "preserve")
        XCTAssertEqual(object["recordedAt"] as? Int, 123)
    }
    func testColdManifestDoesNotSeedAnIdentityFromPartiallySyncedRenamedAudio() async throws {
        let left = try root(), right = try root(), writer = UUID()
        _ = try seed(left)
        let manifest = try await LegacyLibraryBootstrap(root: left, writerID: writer).enable()
        try FileManager.default.createDirectory(at: right.appendingPathComponent(".docktape/bootstraps"), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: left.appendingPathComponent(".docktape/format.json"), to: right.appendingPathComponent(".docktape/format.json"))
        try FileManager.default.copyItem(at: left.appendingPathComponent(".docktape/bootstraps/\(writer.uuidString.lowercased()).json"),
            to: right.appendingPathComponent(".docktape/bootstraps/\(writer.uuidString.lowercased()).json"))
        try Data("renamed audio arrived first".utf8).write(to: right.appendingPathComponent("Renamed.mp3"))
        let incoming = LegacyLibraryBootstrap(root: right, writerID: UUID())
        let pending = try await incoming.readiness()
        XCTAssertEqual(pending, .pending(manifest))
        do { _ = try await incoming.enable(); XCTFail("A second Mac cannot bootstrap over a pending manifest") }
        catch { XCTAssertEqual(error as? LegacyBootstrapError, .alreadyEnabled) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: right.appendingPathComponent(".docktape/records").path))
        try FileManager.default.copyItem(at: left.appendingPathComponent(".docktape/records"), to: right.appendingPathComponent(".docktape/records"))
        let ready = try await incoming.readiness()
        XCTAssertEqual(ready, .ready(manifest))
    }
    func testConcurrentBootstrapIsAmbiguousAndOriginalsAreUntouched() async throws {
        let left = try root(), right = try root(), a = UUID(), b = UUID()
        let original = try seed(left); _ = try seed(right)
        _ = try await LegacyLibraryBootstrap(root: left, writerID: a).enable()
        _ = try await LegacyLibraryBootstrap(root: right, writerID: b).enable()
        try FileManager.default.copyItem(at: right.appendingPathComponent(".docktape/bootstraps/\(b.uuidString.lowercased()).json"),
            to: left.appendingPathComponent(".docktape/bootstraps/\(b.uuidString.lowercased()).json"))
        do { _ = try await LegacyLibraryBootstrap(root: left, writerID: a).readiness(); XCTFail("Conflicting bootstrap identities must be read-only") }
        catch { XCTAssertEqual(error as? LegacyBootstrapError, .ambiguousBootstrap) }
        XCTAssertEqual(try Data(contentsOf: left.appendingPathComponent("Meeting.mp3")), original.0)
    }
    func testSameBasenamesAndNestedFoldersKeepDistinctIdentitiesAndTemplatesKeepTheirIDs() async throws {
        let directory = try root(), writer = UUID()
        for folder in ["Calls", "Work/Calls"] {
            let path = directory.appendingPathComponent(folder)
            try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true)
            try Data("same bytes deliberately separate recordings".utf8).write(to: path.appendingPathComponent("Meeting.mp3"))
        }
        let template = Template(id: "custom-preserved", name: "Custom", description: "User template", promptText: "Keep this prompt", isBuiltIn: false)
        let bytes = try JSONSerialization.data(withJSONObject: ["builtInOverrides":[], "userTemplates":[JSONSerialization.jsonObject(with: JSONEncoder().encode(template))]])
        try bytes.write(to: directory.appendingPathComponent(".templates.json"))
        let manifest = try await LegacyLibraryBootstrap(root: directory, writerID: writer).enable()
        let recordings = manifest.references.filter { $0.entity.kind == .recording }
        XCTAssertEqual(recordings.count, 2)
        XCTAssertNotEqual(recordings[0].entity.id, recordings[1].entity.id)
        XCTAssertEqual(Set(manifest.references.filter { $0.entity.kind == .folder }.map(\.initialPath)), ["Calls", "Work", "Work/Calls"])
        let reference = try XCTUnwrap(manifest.references.first { $0.entity.kind == .template })
        let state = try await SharedLibraryRepository(root: directory, writerID: writer).load(entity: reference.entity).state
        XCTAssertEqual(state.value(for: "templateID"), .text("custom-preserved"))
        XCTAssertEqual(state.value(for: "prompt"), .text("Keep this prompt"))
        XCTAssertEqual(try Data(contentsOf: directory.appendingPathComponent(".templates.json")), bytes)
    }
    func testAmbiguousBasenameMetadataFailsBeforePublishingAnyUpgradeIntent() async throws {
        let directory = try root()
        for folder in ["Calls", "Work"] {
            let path = directory.appendingPathComponent(folder)
            try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true)
            try Data("original".utf8).write(to: path.appendingPathComponent("Meeting.mp3"))
        }
        try Data("{\"Meeting.mp3\":{\"mode\":\"Pho\"}}".utf8).write(to: directory.appendingPathComponent("library.json"))
        do { _ = try await LegacyLibraryBootstrap(root: directory, writerID: UUID()).enable(); XCTFail() }
        catch { XCTAssertEqual(error as? LegacyBootstrapError, .ambiguousMetadata) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent(".docktape/format.json").path))
    }

    func testReadyPointerWithoutFoundersClaimIsStillPending() async throws {
        let directory = try root(), writer = UUID()
        _ = try seed(directory)
        let bootstrap = LegacyLibraryBootstrap(root: directory, writerID: writer)
        let manifest = try await bootstrap.enable()
        try FileManager.default.removeItem(at: directory.appendingPathComponent(".docktape/bootstraps/\(writer.uuidString.lowercased()).json"))
        let state = try await bootstrap.readiness()
        XCTAssertEqual(state, .pending(manifest), "The founder's independently owned claim must arrive too")
    }
    func testInterruptedBootstrapResumesWithoutMovingOriginalsOrAllocatingNewIdentities() async throws {
        let directory = try root(), writer = UUID()
        let original = try seed(directory)
        let bootstrap = LegacyLibraryBootstrap(root: directory, writerID: writer)
        let ready = try await bootstrap.enable()
        var interrupted = ready; interrupted.complete = false
        let bytes = try JSONEncoder().encode(interrupted)
        for path in [".docktape/format.json", ".docktape/bootstraps/\(writer.uuidString.lowercased()).json"] {
            try bytes.write(to: directory.appendingPathComponent(path), options: .atomic)
        }
        try FileManager.default.removeItem(at: directory.appendingPathComponent(".docktape/records"))
        let resumed = try await bootstrap.resume()
        XCTAssertEqual(resumed, ready)
        XCTAssertEqual(try Data(contentsOf: directory.appendingPathComponent("Meeting.mp3")), original.0)
        XCTAssertEqual(try Data(contentsOf: directory.appendingPathComponent("Meeting.transcript.json")), original.1)
    }
    func testInterruptedBootstrapRejectsAddedEmptyFolderBeforeFinishing() async throws {
        let directory = try root(), writer = UUID()
        _ = try seed(directory)
        try FileManager.default.createDirectory(at: directory.appendingPathComponent("Empty"), withIntermediateDirectories: true)
        let bootstrap = LegacyLibraryBootstrap(root: directory, writerID: writer)
        let ready = try await bootstrap.enable()
        var pending = ready; pending.complete = false
        for path in [".docktape/format.json", ".docktape/bootstraps/\(writer.uuidString.lowercased()).json"] {
            try JSONEncoder().encode(pending).write(to: directory.appendingPathComponent(path), options: .atomic)
        }
        try FileManager.default.createDirectory(at: directory.appendingPathComponent("Late empty"), withIntermediateDirectories: true)
        do { _ = try await bootstrap.resume(); XCTFail("A changed directory list needs review") }
        catch LegacyBootstrapError.changedLegacyInput {}
        let header = try await bootstrap.publishedManifest()
        XCTAssertEqual(header, .pending(pending))
        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.appendingPathComponent("Late empty").path))
    }
    func testInterruptedLegacyInputProofWithoutDirectoryIndexStillResumes() async throws {
        let directory = try root(), writer = UUID()
        let originals = try seed(directory)
        let bootstrap = LegacyLibraryBootstrap(root: directory, writerID: writer)
        let ready = try await bootstrap.enable()
        let files = try await SharedProjectionInputs.capture(root: directory, includeDirectoryProof: false)
        let oldInputs = try SharedProjectionInputs(manifest: ready, files: files)
        try oldInputs.encoded().write(to: SharedProjectionInputs.file(in: directory), options: .atomic)
        var pending = ready; pending.complete = false
        for path in [".docktape/format.json", ".docktape/bootstraps/\(writer.uuidString.lowercased()).json"] {
            try JSONEncoder().encode(pending).write(to: directory.appendingPathComponent(path), options: .atomic)
        }
        try FileManager.default.removeItem(at: directory.appendingPathComponent(".docktape/records"))
        let resumed = try await bootstrap.resume()
        XCTAssertEqual(resumed, ready)
        XCTAssertEqual(try Data(contentsOf: directory.appendingPathComponent("Meeting.mp3")), originals.0)
    }

    func testManifestSymlinkCannotReadOutsideTheLibrary() async throws {
        let directory = try root(), outside = try root()
        try FileManager.default.createDirectory(at: directory.appendingPathComponent(".docktape"), withIntermediateDirectories: true)
        let unrelated = outside.appendingPathComponent("other.json")
        try Data("{\"schemaVersion\":999}".utf8).write(to: unrelated)
        try FileManager.default.createSymbolicLink(at: directory.appendingPathComponent(".docktape/format.json"), withDestinationURL: unrelated)
        do { _ = try await LegacyLibraryBootstrap(root: directory, writerID: UUID()).readiness(); XCTFail() }
        catch { XCTAssertEqual(error as? SharedLibraryRepositoryError, .invalidPath) }
    }

    func testUnknownSchemaDoesNotInitializeOrRepairTheLibrary() async throws {
        let directory = try root()
        try FileManager.default.createDirectory(at: directory.appendingPathComponent(".docktape"), withIntermediateDirectories: true)
        let bytes = Data("{\"schemaVersion\":999}".utf8)
        try bytes.write(to: directory.appendingPathComponent(".docktape/format.json"))
        let bootstrap = LegacyLibraryBootstrap(root: directory, writerID: UUID())
        do { _ = try await bootstrap.readiness(); XCTFail() }
        catch { XCTAssertEqual(error as? LegacyBootstrapError, .unsupportedSchema(999)) }
        XCTAssertEqual(try Data(contentsOf: directory.appendingPathComponent(".docktape/format.json")), bytes)
    }
    func testBootstrapReadsActualStoreISODateSidecarsWithoutRewritingThem() async throws {
        let directory = try root(); defer { try? FileManager.default.removeItem(at: directory) }
        try Data("synthetic audio".utf8).write(to: directory.appendingPathComponent("call.mp3"))
        let transcript = Transcript(recordingFilename: "call.mp3", transcriptionModel: "fixture", hasSpeakerLabels: false,
            segments: [.init(startTime: 0, endTime: 1, text: "Synthetic")])
        let summary = Summary(recordingFilename: "call.mp3", model: "fixture", provider: "fixture", templateUsed: "meeting",
            sections: [.init(heading: "Summary", content: "Synthetic")])
        try await TranscriptStore(baseDirectory: directory).save(transcript, mp3Filename: "call.mp3")
        try await SummaryStore(baseDirectory: directory).save(summary, mp3Filename: "call.mp3")
        let t = directory.appendingPathComponent("call.transcript.json"), s = directory.appendingPathComponent("call.summary.json")
        let originalT = try Data(contentsOf: t), originalS = try Data(contentsOf: s)
        let writer = UUID()
        let bootstrap = LegacyLibraryBootstrap(root: directory, writerID: writer)
        let manifest = try await bootstrap.enable()
        XCTAssertTrue(manifest.complete)
        XCTAssertEqual(try Data(contentsOf: t), originalT); XCTAssertEqual(try Data(contentsOf: s), originalS)
        let repository = SharedLibraryRepository(root: directory, writerID: writer, manifest: manifest)
        let entity = try XCTUnwrap(manifest.references.first { $0.entity.kind == .recording }).entity
        let state = try await repository.load(entity: entity).state
        XCTAssertEqual(state.currentDocument(for: .transcript)?.json, try SharedDocument(id: UUID(), json: originalT).json)
        XCTAssertEqual(state.currentDocument(for: .summary)?.json, try SharedDocument(id: UUID(), json: originalS).json)
    }

}
