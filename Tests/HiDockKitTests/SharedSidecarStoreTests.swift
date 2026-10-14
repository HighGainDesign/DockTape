// © 2026 High Gain Design. All rights reserved.
import XCTest
@testable import HiDockKit

final class SharedSidecarStoreTests: XCTestCase {
    private var roots: [URL] = []
    override func tearDown() { for root in roots { try? FileManager.default.removeItem(at: root) } }
    private func fixture() async throws -> (URL, SharedLibraryCoordinator) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        roots.append(root)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("synthetic audio".utf8).write(to: root.appendingPathComponent("Meeting.mp3"))
        let transcript = Transcript(recordingFilename: "Meeting.mp3", transcriptionModel: "fixture", hasSpeakerLabels: true,
                                    segments: [.init(startTime: 0, endTime: 1, text: "Test", speakerID: "A")],
                                    speakerNames: ["A": "Alice", "B": "Bob"])
        try await TranscriptStore(baseDirectory: root).save(transcript, mp3Filename: "Meeting.mp3")
        let coordinator = SharedLibraryCoordinator(root: root, writerID: UUID())
        _ = try await coordinator.enable()
        return (root, coordinator)
    }
    func testActualTranscriptStoresMergeIndependentSpeakerEditsThroughSharedAuthority() async throws {
        let (root, coordinator) = try await fixture()
        let one = TranscriptStore(baseDirectory: root, shared: SharedSidecarAdapter(coordinator: coordinator))
        let two = TranscriptStore(baseDirectory: root, shared: SharedSidecarAdapter(coordinator: coordinator))
        _ = try await one.loadTranscript(for: "Meeting.mp3")
        _ = try await two.loadTranscript(for: "Meeting.mp3")
        try await one.updateSpeakerNames(for: "Meeting.mp3", names: ["A": "Anna", "B": "Bob"])
        try await two.updateSpeakerNames(for: "Meeting.mp3", names: ["A": "Alice", "B": "Ben"])
        let result = try await one.loadTranscript(for: "Meeting.mp3")
        XCTAssertEqual(result?.speakerNames, ["A": "Anna", "B": "Ben"])
    }
    func testActualTranscriptStoreRejectsEditToSupersededGeneration() async throws {
        let (root, coordinator) = try await fixture()
        let one = TranscriptStore(baseDirectory: root, shared: SharedSidecarAdapter(coordinator: coordinator))
        let two = TranscriptStore(baseDirectory: root, shared: SharedSidecarAdapter(coordinator: coordinator))
        _ = try await one.loadTranscript(for: "Meeting.mp3")
        let replacement = Transcript(recordingFilename: "Meeting.mp3", transcriptionModel: "new", hasSpeakerLabels: true,
                                     segments: [.init(startTime: 0, endTime: 2, text: "New", speakerID: "A")])
        _ = try await two.loadTranscript(for: "Meeting.mp3")
        try await two.save(replacement, mp3Filename: "Meeting.mp3")
        do {
            try await one.updateSpeakerNames(for: "Meeting.mp3", names: ["A": "Wrong"])
            XCTFail("An old display must not rename a new generation")
        } catch SharedLibraryCoordinatorError.staleReview {}
        let result = try await two.loadTranscript(for: "Meeting.mp3")
        XCTAssertTrue(result?.speakerNames.isEmpty == true)
        XCTAssertEqual(result?.segments.first?.text, "New")
    }
    func testSharedSidecarDoesNotTrustUntrackedDiskReplacement() async throws {
        let (root, coordinator) = try await fixture()
        let store = TranscriptStore(baseDirectory: root, shared: SharedSidecarAdapter(coordinator: coordinator))
        let before = try await store.loadTranscript(for: "Meeting.mp3")
        try Data("{\"untracked\":true}".utf8).write(to: root.appendingPathComponent("Meeting.transcript.json"))
        let after = try await store.loadTranscript(for: "Meeting.mp3")
        XCTAssertEqual(before?.segments.first?.id, after?.segments.first?.id)
    }
    func testSharedSummaryStoresMergeIndependentCheckboxes() async throws {
        let (root, coordinator) = try await fixture()
        let first = Summary.Item(text: "First"), second = Summary.Item(text: "Second")
        let summary = Summary(recordingFilename: "Meeting.mp3", model: "fixture", provider: "fixture", templateUsed: "fixture",
                              sections: [.init(heading: "Tasks", content: "", items: [first, second])])
        let one = SummaryStore(baseDirectory: root, shared: SharedSidecarAdapter(coordinator: coordinator))
        let two = SummaryStore(baseDirectory: root, shared: SharedSidecarAdapter(coordinator: coordinator))
        try await one.save(summary, mp3Filename: "Meeting.mp3")
        _ = try await two.loadSummary(for: "Meeting.mp3")
        try await one.toggleItem(first.id, inSummaryFor: "Meeting.mp3")
        try await two.toggleItem(second.id, inSummaryFor: "Meeting.mp3")
        let result = try await one.loadSummary(for: "Meeting.mp3")
        XCTAssertEqual(result?.sections.first?.items?.map(\.isCompleted), [true, true])
    }
    func testSpeakerRemovalSurvivesReloadAndDoesNotRestoreOriginalLabel() async throws {
        let (root, coordinator) = try await fixture()
        let store = TranscriptStore(baseDirectory: root, shared: SharedSidecarAdapter(coordinator: coordinator))
        _ = try await store.loadTranscript(for: "Meeting.mp3")
        try await store.updateSpeakerNames(for: "Meeting.mp3", names: ["B": "Bob"])
        let fresh = TranscriptStore(baseDirectory: root, shared: SharedSidecarAdapter(coordinator: coordinator))
        let result = try await fresh.loadTranscript(for: "Meeting.mp3")
        XCTAssertNil(result?.speakerNames["A"])
        XCTAssertEqual(result?.speakerNames["B"], "Bob")
    }
    func testSaveRejectsContentBelongingToAnotherRecording() async throws {
        let (root, coordinator) = try await fixture()
        let store = TranscriptStore(baseDirectory: root, shared: SharedSidecarAdapter(coordinator: coordinator))
        let before = try await store.loadTranscript(for: "Meeting.mp3")
        let copied = Transcript(recordingFilename: "SomeoneElse.mp3", transcriptionModel: "fixture",
                                hasSpeakerLabels: false, segments: [])
        do {
            try await store.save(copied, mp3Filename: "Meeting.mp3")
            XCTFail("Copied content must be explicitly rebound/adopted")
        } catch SharedSidecarError.invalidContent {}
        let result = try await store.loadTranscript(for: "Meeting.mp3")
        XCTAssertEqual(result?.segments.first?.id, before?.segments.first?.id)
    }
    func testSharedStoreCannotBlindlyReplaceExistingContentWithoutAnInputSnapshot() async throws {
        let (root, coordinator) = try await fixture()
        let store = TranscriptStore(baseDirectory: root, shared: SharedSidecarAdapter(coordinator: coordinator))
        let generated = Transcript(recordingFilename: "Meeting.mp3", transcriptionModel: "stale job",
                                   hasSpeakerLabels: false, segments: [])
        do {
            try await store.save(generated, mp3Filename: "Meeting.mp3")
            XCTFail("An unpinned producer must not consume an existing generation")
        } catch SharedSidecarError.reloadRequired {}
    }

    private func deliverOwned(_ source: URL, _ destination: URL, writer: UUID) throws {
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
    func testActualStoresMergeOfflineTwoRootEditsAndPreserveCompetingNames() async throws {
        let (left, one) = try await fixture()
        let right = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        roots.append(right)
        try FileManager.default.createDirectory(at: right, withIntermediateDirectories: true)
        try Data("synthetic audio".utf8).write(to: right.appendingPathComponent("Meeting.mp3"))
        let secondWriter = UUID()
        let two = SharedLibraryCoordinator(root: right, writerID: secondWriter)
        try deliverOwned(left, right, writer: one.writerID)
        try await two.requestEnrollment(requestID: UUID(), label: "Fixture B")
        try deliverOwned(right, left, writer: secondWriter)
        try await one.refresh()
        try deliverOwned(left, right, writer: one.writerID)
        try await two.refresh()
        try deliverOwned(right, left, writer: secondWriter)
        try await one.refresh()
        try deliverOwned(left, right, writer: one.writerID)
        let a = TranscriptStore(baseDirectory: left, shared: SharedSidecarAdapter(coordinator: one))
        let b = TranscriptStore(baseDirectory: right, shared: SharedSidecarAdapter(coordinator: two))
        _ = try await a.loadTranscript(for: "Meeting.mp3")
        _ = try await b.loadTranscript(for: "Meeting.mp3")
        // No transport between these edits: actors cannot serialize two roots.
        try await a.updateSpeakerNames(for: "Meeting.mp3", names: ["A": "Anna", "B": "Bob"])
        try await b.updateSpeakerNames(for: "Meeting.mp3", names: ["A": "Alice", "B": "Ben"])
        try deliverOwned(left, right, writer: one.writerID)
        try deliverOwned(right, left, writer: secondWriter)
        let joinedA = try await a.loadTranscript(for: "Meeting.mp3")
        let joinedB = try await b.loadTranscript(for: "Meeting.mp3")
        XCTAssertEqual(joinedA?.speakerNames, ["A": "Anna", "B": "Ben"])
        XCTAssertEqual(joinedB?.speakerNames, joinedA?.speakerNames)
        // Establish the joined view as the confirmed common projection.
        for _ in 0..<3 {
            try await one.refresh()
            try deliverOwned(left, right, writer: one.writerID)
            try await two.refresh()
            try deliverOwned(right, left, writer: secondWriter)
        }
        let common = try await one.recording(at: "Meeting.mp3").confirmedState
        XCTAssertEqual(common?.generationEdits(for: .transcript)["A"], .text("Anna"))
        try await a.updateSpeakerNames(for: "Meeting.mp3", names: ["A": "Left choice", "B": "Ben"])
        try await b.updateSpeakerNames(for: "Meeting.mp3", names: ["A": "Right choice", "B": "Ben"])
        try deliverOwned(left, right, writer: one.writerID)
        try deliverOwned(right, left, writer: secondWriter)
        let state = try await one.recording(at: "Meeting.mp3").state
        let conflict = try XCTUnwrap(state.conflicts.first { $0.field.hasSuffix(".A") })
        XCTAssertEqual(conflict.values, [.text("Left choice"), .text("Right choice")])
        let other = try await two.recording(at: "Meeting.mp3").state
        XCTAssertEqual(state, other)
        let conflictedDisplay = try await a.loadTranscript(for: "Meeting.mp3")
        XCTAssertEqual(conflictedDisplay?.speakerNames["A"], "Anna", "Retain the last confirmed choice during conflict")
        XCTAssertEqual(conflictedDisplay?.speakerNames["B"], "Ben")
        do {
            try await a.updateSpeakerNames(for: "Meeting.mp3", names: ["A": "Unreviewed third choice", "B": "Ben"])
            XCTFail("Ordinary editing must not silently consume both competing values")
        } catch SharedSidecarError.conflictedContent {}
        let unresolved = try await one.recording(at: "Meeting.mp3").state
        XCTAssertEqual(unresolved.conflicts.first { $0.field.hasSuffix(".A") }?.values,
                       [.text("Left choice"), .text("Right choice")])
    }

    func testSharedAdapterCannotBeAttachedToAnotherLibraryRoot() async throws {
        let (_, coordinator) = try await fixture()
        let other = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        roots.append(other)
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        let store = TranscriptStore(baseDirectory: other, shared: SharedSidecarAdapter(coordinator: coordinator))
        do {
            _ = try await store.loadTranscript(for: "Meeting.mp3")
            XCTFail("A store must not read another library through its attached adapter")
        } catch SharedLibraryCoordinatorError.differentBinding {}
    }

}
