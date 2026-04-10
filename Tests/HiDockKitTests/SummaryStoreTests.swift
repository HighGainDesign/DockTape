// Tests/HiDockKitTests/SummaryStoreTests.swift
import XCTest
@testable import HiDockKit

final class SummaryStoreTests: XCTestCase {
    var tempDir: URL!

    override func setUp() {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("SummaryStoreTests-\(UUID().uuidString)")
        try! FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempDir)
    }

    func testSaveAndLoad() async throws {
        let store = SummaryStore(baseDirectory: tempDir)
        let summary = Summary(
            recordingFilename: "test.mp3",
            model: "claude-sonnet-4-6",
            provider: "anthropic",
            templateUsed: "meeting",
            sections: [
                Summary.Section(heading: "Summary", content: "A productive meeting.", items: nil)
            ]
        )

        try await store.save(summary, mp3Filename: "test.mp3")

        // Verify file on disk
        let fileURL = tempDir.appendingPathComponent("test.summary.json")
        XCTAssertTrue(FileManager.default.fileExists(atPath: fileURL.path))

        // Verify cache hit
        let loaded = await store.summary(for: "test.mp3")
        XCTAssertNotNil(loaded)
        XCTAssertEqual(loaded?.sections.count, 1)
        XCTAssertEqual(loaded?.sections[0].content, "A productive meeting.")
    }

    func testLoadAll() async throws {
        let store = SummaryStore(baseDirectory: tempDir)
        let s1 = Summary(
            recordingFilename: "a.mp3",
            model: "gpt-4o",
            provider: "openai",
            templateUsed: "call",
            sections: [Summary.Section(heading: "Synopsis", content: "Quick sync.", items: nil)]
        )
        let s2 = Summary(
            recordingFilename: "b.mp3",
            model: "gpt-4o",
            provider: "openai",
            templateUsed: "recording",
            sections: [Summary.Section(heading: "Summary", content: "Lecture notes.", items: nil)]
        )

        try await store.save(s1, mp3Filename: "a.mp3")
        try await store.save(s2, mp3Filename: "b.mp3")

        // Create a fresh store to test loadAll from disk
        let store2 = SummaryStore(baseDirectory: tempDir)
        try await store2.loadAll()

        let all = await store2.allSummaries()
        XCTAssertEqual(all.count, 2)
    }

    func testUpdateItemCompletion() async throws {
        let store = SummaryStore(baseDirectory: tempDir)
        let itemID = UUID()
        let summary = Summary(
            recordingFilename: "tasks.mp3",
            model: "claude-sonnet-4-6",
            provider: "anthropic",
            templateUsed: "meeting",
            sections: [
                Summary.Section(
                    heading: "Action Items",
                    content: "",
                    items: [Summary.Item(id: itemID, text: "Send email", isCompleted: false)]
                )
            ]
        )

        try await store.save(summary, mp3Filename: "tasks.mp3")
        try await store.toggleItem(itemID, inSummaryFor: "tasks.mp3")

        let updated = await store.summary(for: "tasks.mp3")
        XCTAssertTrue(updated?.sections[0].items?[0].isCompleted ?? false)

        // Verify persisted to disk
        let store2 = SummaryStore(baseDirectory: tempDir)
        try await store2.loadAll()
        let reloaded = await store2.summary(for: "tasks.mp3")
        XCTAssertTrue(reloaded?.sections[0].items?[0].isCompleted ?? false)
    }

    func testRenameMovesFileAndUpdatesFilename() async throws {
        let store = SummaryStore(baseDirectory: tempDir)
        let summary = Summary(
            recordingFilename: "old.mp3",
            model: "gpt-4o",
            provider: "openai",
            templateUsed: "meeting",
            sections: [Summary.Section(heading: "Summary", content: "Test.", items: nil)]
        )
        try await store.save(summary, mp3Filename: "old.mp3")

        await store.rename(from: "old.mp3", to: "new.mp3")

        // Old file gone, new file exists
        XCTAssertFalse(FileManager.default.fileExists(atPath: tempDir.appendingPathComponent("old.summary.json").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: tempDir.appendingPathComponent("new.summary.json").path))

        // Cache updated
        let old = await store.summary(for: "old.mp3")
        XCTAssertNil(old)
        let new = await store.summary(for: "new.mp3")
        XCTAssertNotNil(new)
        XCTAssertEqual(new?.recordingFilename, "new.mp3")

        // Persists across reload
        let store2 = SummaryStore(baseDirectory: tempDir)
        try await store2.loadAll()
        let reloaded = await store2.summary(for: "new.mp3")
        XCTAssertEqual(reloaded?.recordingFilename, "new.mp3")
    }

    func testDeleteRemovesFileAndCache() async throws {
        let store = SummaryStore(baseDirectory: tempDir)
        let summary = Summary(
            recordingFilename: "doomed.mp3",
            model: "gpt-4o",
            provider: "openai",
            templateUsed: "memo",
            sections: [Summary.Section(heading: "Gist", content: "Gone soon.", items: nil)]
        )
        try await store.save(summary, mp3Filename: "doomed.mp3")
        let hasBefore = await store.hasSummary(for: "doomed.mp3")
        XCTAssertTrue(hasBefore)

        try await store.delete(for: "doomed.mp3")

        let hasAfter = await store.hasSummary(for: "doomed.mp3")
        XCTAssertFalse(hasAfter)
        XCTAssertFalse(FileManager.default.fileExists(atPath: tempDir.appendingPathComponent("doomed.summary.json").path))
    }

    func testLoadAllWithSubfolders() async throws {
        // Create a subfolder structure
        let subDir = tempDir.appendingPathComponent("Meetings")
        try FileManager.default.createDirectory(at: subDir, withIntermediateDirectories: true)

        let store = SummaryStore(baseDirectory: tempDir)
        let s1 = Summary(
            recordingFilename: "root.mp3",
            model: "gpt-4o", provider: "openai", templateUsed: "recording",
            sections: [Summary.Section(heading: "Summary", content: "Root file.", items: nil)]
        )
        let s2 = Summary(
            recordingFilename: "Meetings/standup.mp3",
            model: "gpt-4o", provider: "openai", templateUsed: "meeting",
            sections: [Summary.Section(heading: "Summary", content: "Standup notes.", items: nil)]
        )

        try await store.save(s1, mp3Filename: "root.mp3")
        try await store.save(s2, mp3Filename: "Meetings/standup.mp3")

        // Reload from disk
        let store2 = SummaryStore(baseDirectory: tempDir)
        try await store2.loadAll()

        let root = await store2.summary(for: "root.mp3")
        XCTAssertEqual(root?.sections[0].content, "Root file.")

        let sub = await store2.summary(for: "Meetings/standup.mp3")
        XCTAssertEqual(sub?.sections[0].content, "Standup notes.")
        let allCount = await store2.allSummaries().count
        XCTAssertEqual(allCount, 2)
    }

    func testHasSummary() async throws {
        let store = SummaryStore(baseDirectory: tempDir)
        let has = await store.hasSummary(for: "nonexistent.mp3")
        XCTAssertFalse(has)

        let summary = Summary(
            recordingFilename: "exists.mp3",
            model: "gpt-4o",
            provider: "openai",
            templateUsed: "memo",
            sections: [Summary.Section(heading: "Gist", content: "Quick note.", items: nil)]
        )
        try await store.save(summary, mp3Filename: "exists.mp3")

        let hasNow = await store.hasSummary(for: "exists.mp3")
        XCTAssertTrue(hasNow)
    }
}
