// © 2026 High Gain Design. All rights reserved.
import XCTest

@testable import HiDockKit

/// Actual legacy store failures that the shared adapters must cover. These use
/// real JSON/filesystem state, not doubles replacing the stores being tested.
final class SharedStoreRegressionTests: XCTestCase {
  private func root() throws -> URL {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
  }
  func testTwoRecordingStoresDoNotLoseIndependentMetadata() async throws {
    let root = try root()
    defer { try? FileManager.default.removeItem(at: root) }
    let a = RecordingStore(baseDirectory: root)
    let b = RecordingStore(baseDirectory: root)
    try await a.setup()
    try await b.setup()
    try await a.setMeta(mode: "Rec", deviceFilename: "a.hda", for: "a.mp3")
    try await b.setMeta(mode: "Pho", deviceFilename: "b.hda", for: "b.mp3")
    let reopened = RecordingStore(baseDirectory: root)
    try await reopened.setup()
    let aMode = await reopened.mode(for: "a.mp3")
    let bMode = await reopened.mode(for: "b.mp3")
    XCTAssertEqual(aMode, "Rec")
    XCTAssertEqual(bMode, "Pho")
  }
  func testSameBasenameInDifferentFoldersKeepsIndependentMetadata() async throws {
    let root = try root()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = RecordingStore(baseDirectory: root)
    try await store.setup()
    try await store.setMeta(mode: "Rec", deviceFilename: "first.hda", for: "One/call.mp3")
    try await store.setMeta(mode: "Pho", deviceFilename: "second.hda", for: "Two/call.mp3")
    let first = await store.mode(for: "One/call.mp3")
    let second = await store.mode(for: "Two/call.mp3")
    XCTAssertEqual(first, "Rec")
    XCTAssertEqual(second, "Pho")
  }
  func testTranscriptCacheObservesExternalAcceptedWrite() async throws {
    let root = try root()
    defer { try? FileManager.default.removeItem(at: root) }
    let a = TranscriptStore(baseDirectory: root)
    let b = TranscriptStore(baseDirectory: root)
    func transcript(_ name: String) -> Transcript {
      .init(
        recordingFilename: "a.mp3", transcriptionModel: "fixture", hasSpeakerLabels: true,
        segments: [.init(startTime: 0, endTime: 1, text: "Synthetic", speakerID: "s1")],
        speakerNames: ["s1": name])
    }
    try await a.save(transcript("Alice"), mp3Filename: "a.mp3")
    _ = try await a.loadTranscript(for: "a.mp3")
    try await b.save(transcript("Bob"), mp3Filename: "a.mp3")
    let current = try await a.loadTranscript(for: "a.mp3")
    XCTAssertEqual(current?.speakerNames["s1"], "Bob")
  }
  func testSummaryCacheObservesExternalAcceptedWrite() async throws {
    let root = try root()
    defer { try? FileManager.default.removeItem(at: root) }
    let a = SummaryStore(baseDirectory: root)
    let b = SummaryStore(baseDirectory: root)
    func summary(_ text: String) -> Summary {
      .init(
        recordingFilename: "a.mp3", model: "fixture", provider: "fixture", templateUsed: "meeting",
        sections: [.init(heading: "Summary", content: text)])
    }
    try await a.save(summary("First"), mp3Filename: "a.mp3")
    _ = try await a.loadSummary(for: "a.mp3")
    try await b.save(summary("Second"), mp3Filename: "a.mp3")
    let current = try await a.loadSummary(for: "a.mp3")
    XCTAssertEqual(current?.sections.first?.content, "Second")
  }
  func testIndependentTemplateStoresDoNotDiscardOtherAddedTemplate() async throws {
    let root = try root()
    defer { try? FileManager.default.removeItem(at: root) }
    let a = TemplateStore(baseDirectory: root)
    let b = TemplateStore(baseDirectory: root)
    try await a.load()
    try await b.load()
    try await a.addUserTemplate(
      .init(id: "one", name: "One", description: "", promptText: "First", isBuiltIn: false))
    try await b.addUserTemplate(
      .init(id: "two", name: "Two", description: "", promptText: "Second", isBuiltIn: false))
    let reopened = TemplateStore(baseDirectory: root)
    try await reopened.load()
    let ids = await reopened.userCreatedTemplates().map(\.id)
    XCTAssertEqual(Set(ids), ["one", "two"])
  }
  func testStaleSpeakerEditDoesNotOverwriteReplacedTranscriptGeneration() async throws {
    let root = try root()
    defer { try? FileManager.default.removeItem(at: root) }
    let a = TranscriptStore(baseDirectory: root)
    let b = TranscriptStore(baseDirectory: root)
    func transcript(_ text: String) -> Transcript {
      .init(
        recordingFilename: "a.mp3", transcriptionModel: "fixture", hasSpeakerLabels: true,
        segments: [.init(startTime: 0, endTime: 1, text: text, speakerID: "s1")],
        speakerNames: ["s1": text])
    }
    try await a.save(transcript("First"), mp3Filename: "a.mp3")
    try await b.save(transcript("Replacement"), mp3Filename: "a.mp3")
    let file = root.appendingPathComponent("a.transcript.json")
    let replacement = try Data(contentsOf: file)
    do {
      try await a.updateSpeakerNames(for: "a.mp3", names: ["s1": "Stale name"])
      XCTFail("Old edits need a new review")
    } catch {}
    XCTAssertEqual(try Data(contentsOf: file), replacement)
  }
  func testLegacyStoresCannotWriteAroundSharedAuthority() async throws {
    let root = try root()
    defer { try? FileManager.default.removeItem(at: root) }
    let transcript = Transcript(
      recordingFilename: "a.mp3", transcriptionModel: "fixture", hasSpeakerLabels: false,
      segments: [.init(startTime: 0, endTime: 1, text: "Synthetic")])
    let store = TranscriptStore(baseDirectory: root)
    try await store.save(transcript, mp3Filename: "a.mp3")
    let file = root.appendingPathComponent("a.transcript.json")
    let original = try Data(contentsOf: file)
    try FileManager.default.createDirectory(
      at: root.appendingPathComponent(".docktape"), withIntermediateDirectories: false)
    do {
      try await store.save(transcript, mp3Filename: "a.mp3")
      XCTFail("Shared writes need the adapter")
    } catch {}
    do {
      try await store.delete(for: "a.mp3")
      XCTFail("Shared deletes need the adapter")
    } catch {}
    XCTAssertEqual(try Data(contentsOf: file), original)
  }

  func testStaleSummaryToggleDoesNotOverwriteNewGeneration() async throws {
    let root = try root()
    defer { try? FileManager.default.removeItem(at: root) }
    let a = SummaryStore(baseDirectory: root)
    let b = SummaryStore(baseDirectory: root)
    let item = Summary.Item(text: "old action", isCompleted: false)
    let original = Summary(
      recordingFilename: "a.mp3", model: "fixture", provider: "fixture", templateUsed: "meeting",
      sections: [.init(heading: "Actions", content: "", items: [item])])
    try await a.save(original, mp3Filename: "a.mp3")
    let replacement = Summary(
      recordingFilename: "a.mp3", model: "fixture", provider: "fixture", templateUsed: "meeting",
      sections: [
        .init(
          heading: "New summary", content: "new content",
          items: [.init(text: "new action", isCompleted: false)])
      ])
    try await b.save(replacement, mp3Filename: "a.mp3")
    let file = root.appendingPathComponent("a.summary.json")
    let bytes = try Data(contentsOf: file)
    do {
      try await a.toggleItem(item.id, inSummaryFor: "a.mp3")
      XCTFail("Old checkbox edits need a fresh review")
    } catch {}
    XCTAssertEqual(try Data(contentsOf: file), bytes)
  }
  func testIndependentSpeakerAndActionEditsPreserveOtherLocalStoreChanges() async throws {
    let root = try root()
    defer { try? FileManager.default.removeItem(at: root) }
    let a = TranscriptStore(baseDirectory: root)
    let b = TranscriptStore(baseDirectory: root)
    let transcript = Transcript(
      recordingFilename: "a.mp3", transcriptionModel: "fixture", hasSpeakerLabels: true,
      segments: [.init(startTime: 0, endTime: 1, text: "Synthetic", speakerID: "s1")],
      speakerNames: ["s1": "Alice", "s2": "Bob"])
    try await a.save(transcript, mp3Filename: "a.mp3")
    _ = try await b.loadTranscript(for: "a.mp3")
    try await b.updateSpeakerNames(for: "a.mp3", names: ["s1": "Remote", "s2": "Bob"])
    try await a.updateSpeakerNames(for: "a.mp3", names: ["s1": "Alice", "s2": "Local"])
    let current = try await a.loadTranscript(for: "a.mp3")
    XCTAssertEqual(current?.speakerNames, ["s1": "Remote", "s2": "Local"])
    let first = Summary.Item(text: "first", isCompleted: false)
    let second = Summary.Item(text: "second", isCompleted: false)
    let summary = Summary(
      recordingFilename: "a.mp3", model: "fixture", provider: "fixture", templateUsed: "meeting",
      sections: [.init(heading: "Actions", content: "", items: [first, second])])
    let sa = SummaryStore(baseDirectory: root)
    let sb = SummaryStore(baseDirectory: root)
    try await sa.save(summary, mp3Filename: "a.mp3")
    _ = try await sb.loadSummary(for: "a.mp3")
    try await sb.toggleItem(first.id, inSummaryFor: "a.mp3")
    try await sa.toggleItem(second.id, inSummaryFor: "a.mp3")
    let currentSummary = try await sa.loadSummary(for: "a.mp3")
    XCTAssertEqual(currentSummary?.sections.first?.items?.map(\.isCompleted), [true, true])
  }

  func testMalformedCurrentMetadataIsPreservedWhenAnotherStoreTriesToSave() async throws {
    let root = try root()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = RecordingStore(baseDirectory: root)
    try await store.setup()
    let file = root.appendingPathComponent("library.json")
    let malformed = Data("{\"corrupted.mp3\":\"unrecognized metadata\"}".utf8)
    try malformed.write(to: file)
    do {
      try await store.setMeta(mode: "Rec", deviceFilename: "new.hda", for: "new.mp3")
      XCTFail()
    } catch {}
    XCTAssertEqual(try Data(contentsOf: file), malformed)
  }
  func testFailedTemplateMigrationRetainsTheOriginalPreference() async throws {
    let root = try root()
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(
      at: root.appendingPathComponent(".docktape"), withIntermediateDirectories: false)
    let suite = "DockTape-migration-fixture-" + UUID().uuidString
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    defaults.set("Synthetic prompt", forKey: "templatePrompt_meeting")
    let store = TemplateStore(baseDirectory: root)
    do {
      try await store.migrateFromUserDefaults(defaults)
      XCTFail()
    } catch {}
    XCTAssertEqual(defaults.string(forKey: "templatePrompt_meeting"), "Synthetic prompt")
  }

}
