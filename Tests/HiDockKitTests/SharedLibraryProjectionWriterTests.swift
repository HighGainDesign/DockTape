// © 2026 High Gain Design. All rights reserved.
import XCTest
@testable import HiDockKit

final class SharedLibraryProjectionWriterTests: XCTestCase {
    private var roots: [URL] = []
    override func tearDown() { for root in roots { try? FileManager.default.removeItem(at: root) } }
    private func fixture() async throws -> (URL, SharedLibraryCoordinator) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        roots.append(directory)
        let root = directory.appendingPathComponent("library")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("synthetic".utf8).write(to: root.appendingPathComponent("Meeting.mp3"))
        let recording = RecordingStore(baseDirectory: root)
        try await recording.setup()
        try await recording.setMeta(mode: "Rec", deviceFilename: "device.hda", for: "Meeting.mp3")
        let transcript = Transcript(recordingFilename: "Meeting.mp3", transcriptionModel: "fixture", hasSpeakerLabels: true,
            segments: [.init(startTime: 0, endTime: 1, text: "Readable fixture", speakerID: "s")])
        try await TranscriptStore(baseDirectory: root).save(transcript, mp3Filename: "Meeting.mp3")
        var template = TemplateStore.builtInDefaults[0]; template.promptText = "Fixture prompt"
        try await TemplateStore(baseDirectory: root).update(template)
        let coordinator = SharedLibraryCoordinator(root: root, writerID: UUID(), witnessDirectory: directory.appendingPathComponent("local"))
        _ = try await coordinator.enable()
        return (root, coordinator)
    }
    func testWritesCanonicalAggregatesAndReadableFilesThenSkipsIdenticalBytes() async throws {
        let (root, coordinator) = try await fixture()
        let records = RecordingStore(baseDirectory: root, shared: SharedRecordingMetadataAdapter(coordinator: coordinator))
        try await records.setup()
        try await records.setMeta(mode: "Mee", deviceFilename: "device.hda", for: "Meeting.mp3")
        let transcripts = TranscriptStore(baseDirectory: root, shared: SharedSidecarAdapter(coordinator: coordinator))
        _ = try await transcripts.loadTranscript(for: "Meeting.mp3")
        try await transcripts.updateSpeakerNames(for: "Meeting.mp3", names: ["s": "Alice"])
        let first = try await coordinator.projectOutputs()
        XCTAssertGreaterThan(first.written, 0)
        let library = try Data(contentsOf: root.appendingPathComponent("library.json"))
        let meta = try JSONDecoder().decode([String: RecordingStore.RecordingMeta].self, from: library)
        XCTAssertEqual(meta["Meeting.mp3"]?.mode, "Mee")
        XCTAssertNotNil(try SharedProjectionDocument.marker(in: library))
        XCTAssertTrue(String(decoding: try Data(contentsOf: root.appendingPathComponent("Meeting.transcript.md")), as: UTF8.self).contains("Alice"))
        let templateBytes = try Data(contentsOf: root.appendingPathComponent(".templates.json"))
        XCTAssertNotNil(try SharedProjectionDocument.marker(in: templateBytes))
        let before = try root.appendingPathComponent("Meeting.transcript.md").resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
        let next = try await coordinator.projectOutputs()
        XCTAssertEqual(next.written, 0)
        let after = try root.appendingPathComponent("Meeting.transcript.md").resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
        XCTAssertEqual(before, after)
    }
    func testUntrackedJSONEditRemainsUntouchedDuringProjection() async throws {
        let (root, coordinator) = try await fixture()
        _ = try await coordinator.projectOutputs()
        let file = root.appendingPathComponent("Meeting.transcript.json")
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
        object["speakerNames"] = ["s": "External edit"]
        let external = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        try external.write(to: file, options: .atomic)
        do { _ = try await coordinator.projectOutputs(); XCTFail("Untracked changes must require adoption") }
        catch SharedProjectionWriteError.untracked("Meeting.transcript.json") {}
        XCTAssertEqual(try Data(contentsOf: file), external)
    }
    func testChangedLegacyJSONAfterEnableIsNotSilentlyOverwritten() async throws {
        let (root, coordinator) = try await fixture()
        let file = root.appendingPathComponent("library.json")
        let external = Data("{\"Meeting.mp3\":{\"mode\":\"Wip\"}}".utf8)
        try external.write(to: file, options: .atomic)
        do { _ = try await coordinator.projectOutputs(); XCTFail("Initial projection cannot consume unknown changes") }
        catch SharedProjectionWriteError.untracked("library.json") {}
        XCTAssertEqual(try Data(contentsOf: file), external)
    }
    func testWholeLibraryGuardRejectsAnUnrelatedEditBeforeAggregateWrite() async throws {
        let (root, coordinator) = try await fixture()
        let original = try Data(contentsOf: root.appendingPathComponent("library.json"))
        let templates = TemplateStore(baseDirectory: root, shared: SharedTemplateAdapter(coordinator: coordinator))
        try await templates.load()
        var changed = TemplateStore.builtInDefaults[0]; changed.promptText = "Later prompt"
        let target = changed
        do {
            _ = try await coordinator.projectOutputs(beforeWrite: { try? await templates.update(target) })
            XCTFail("Any affected library revision must invalidate the aggregate plan")
        } catch SharedProjectionWriteError.stale {}
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("library.json")), original)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("Meeting.transcript.md").path))
    }
    private enum Interrupted: Error { case crash }
    func testPartialPublicationRecognizesBothOldAndPendingDocumentsAfterRestart() async throws {
        let (root, coordinator) = try await fixture()
        _ = try await coordinator.projectOutputs()
        let records = RecordingStore(baseDirectory: root, shared: SharedRecordingMetadataAdapter(coordinator: coordinator))
        try await records.setup()
        try await records.setMeta(mode: "Mee", deviceFilename: "device.hda", for: "Meeting.mp3")
        do {
            _ = try await coordinator.projectOutputs(afterOutput: { _ in throw Interrupted.crash })
            XCTFail("Expected interruption after a physical output")
        } catch Interrupted.crash {}
        let restarted = SharedLibraryCoordinator(root: root, writerID: coordinator.writerID,
            witnessDirectory: root.deletingLastPathComponent().appendingPathComponent("local"))
        _ = try await restarted.projectOutputs()
        let bytes = try Data(contentsOf: root.appendingPathComponent("library.json"))
        let library = try JSONDecoder().decode([String: RecordingStore.RecordingMeta].self, from: bytes)
        XCTAssertEqual(library["Meeting.mp3"]?.mode, "Mee")
        let noChanges = try await restarted.projectOutputs()
        XCTAssertEqual(noChanges.written, 0)
    }

    private func deliver(_ source: URL, _ destination: URL, writer: UUID) throws {
        let tree = source.appendingPathComponent(".docktape").resolvingSymlinksInPath()
        let iterator = try XCTUnwrap(FileManager.default.enumerator(at: tree, includingPropertiesForKeys: [.isDirectoryKey]))
        for case let file as URL in iterator {
            guard (try file.resourceValues(forKeys: [.isDirectoryKey])).isDirectory != true else { continue }
            let bytes = try Data(contentsOf: file)
            let object = try XCTUnwrap(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
            let payload = object["payload"] as? [String: Any]
            let owner = (object["writerID"] as? String) ?? (payload?["writer"] as? String) ?? (object["founder"] as? String)
            guard owner.flatMap(UUID.init(uuidString:)) == writer else { continue }
            let relative = String(file.resolvingSymlinksInPath().path.dropFirst(tree.path.count + 1))
            let target = destination.appendingPathComponent(".docktape/" + relative)
            try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try bytes.write(to: target, options: .atomic)
        }
    }
    func testContestedGenerationsPublishTheLastConfirmedContentOnAReopenedMac() async throws {
        let (left, one) = try await fixture()
        let secondDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        roots.append(secondDirectory)
        try FileManager.default.createDirectory(at: secondDirectory, withIntermediateDirectories: true)
        let right = secondDirectory.appendingPathComponent("library")
        try FileManager.default.copyItem(at: left, to: right)
        let two = SharedLibraryCoordinator(root: right, writerID: UUID(), witnessDirectory: secondDirectory.appendingPathComponent("local"))
        try await two.requestEnrollment(requestID: UUID(), label: "Fixture B")
        try deliver(right, left, writer: two.writerID)
        for _ in 0..<3 {
            try await one.refresh(); try deliver(left, right, writer: one.writerID)
            try await two.refresh(); try deliver(right, left, writer: two.writerID)
        }
        let a = TranscriptStore(baseDirectory: left, shared: SharedSidecarAdapter(coordinator: one))
        let b = TranscriptStore(baseDirectory: right, shared: SharedSidecarAdapter(coordinator: two))
        _ = try await a.loadTranscript(for: "Meeting.mp3"); _ = try await b.loadTranscript(for: "Meeting.mp3")
        func replacement(_ text: String) -> Transcript {
            Transcript(recordingFilename: "Meeting.mp3", transcriptionModel: "fixture", hasSpeakerLabels: false,
                       segments: [.init(startTime: 0, endTime: 1, text: text)])
        }
        try await a.save(replacement("Left competing content"), mp3Filename: "Meeting.mp3")
        try await b.save(replacement("Right competing content"), mp3Filename: "Meeting.mp3")
        try deliver(left, right, writer: one.writerID)
        try deliver(right, left, writer: two.writerID)
        let reopened = SharedLibraryCoordinator(root: right, writerID: two.writerID, witnessDirectory: secondDirectory.appendingPathComponent("local"))
        _ = try await reopened.projectOutputs()
        let json = try Data(contentsOf: right.appendingPathComponent("Meeting.transcript.json"))
        let content = try SharedContentCoding.decoder().decode(Transcript.self, from: json)
        XCTAssertEqual(content.segments.first?.text, "Readable fixture")
        let marker = try SharedProjectionDocument.marker(in: json)
        XCTAssertTrue(marker?.hasConflicts == true)
        let markdown = String(decoding: try Data(contentsOf: right.appendingPathComponent("Meeting.transcript.md")), as: UTF8.self)
        XCTAssertTrue(markdown.contains("Readable fixture"))
        XCTAssertFalse(markdown.contains("Left competing content"))
        XCTAssertFalse(markdown.contains("Right competing content"))
    }

}
