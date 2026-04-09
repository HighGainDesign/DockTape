import XCTest
@testable import HiDockKit

final class RecordingStoreFolderTests: XCTestCase {

    var tmpDir: URL!
    var store: RecordingStore!

    override func setUp() async throws {
        tmpDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        store = RecordingStore(baseDirectory: tmpDir)
        try await store.setup()
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: tmpDir)
    }

    // MARK: - Folder CRUD

    func testCreateFolder() async throws {
        try await store.createFolder(named: "Work")
        let folders = await store.folders()
        XCTAssertEqual(folders, ["Work"])
        XCTAssertTrue(FileManager.default.fileExists(atPath: tmpDir.appendingPathComponent("Work").path))
    }

    func testCreateFolderRejectsDuplicates() async throws {
        try await store.createFolder(named: "Work")
        do {
            try await store.createFolder(named: "Work")
            XCTFail("Should throw on duplicate folder")
        } catch {
            // expected
        }
    }

    func testRenameFolder() async throws {
        try await store.createFolder(named: "Work")
        try await store.renameFolder(from: "Work", to: "Office")
        let folders = await store.folders()
        XCTAssertEqual(folders, ["Office"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: tmpDir.appendingPathComponent("Work").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: tmpDir.appendingPathComponent("Office").path))
    }

    func testDeleteFolder() async throws {
        try await store.createFolder(named: "Work")
        try await store.deleteFolder(named: "Work")
        let folders = await store.folders()
        XCTAssertTrue(folders.isEmpty)
    }

    func testFoldersReturnsSortedTopLevelOnly() async throws {
        try await store.createFolder(named: "Zebra")
        try await store.createFolder(named: "Alpha")
        try FileManager.default.createDirectory(
            at: tmpDir.appendingPathComponent("Alpha/SubProject"),
            withIntermediateDirectories: true)
        let folders = await store.folders()
        XCTAssertEqual(folders, ["Alpha", "Zebra"])
    }

    // MARK: - Folder-aware recording scanning

    func testAllRecordingsIncludesSubfolders() async throws {
        try await store.createFolder(named: "Work")
        try Data([0xFF, 0xFB, 0x00]).write(to: tmpDir.appendingPathComponent("root.mp3"))
        try Data([0xFF, 0xFB, 0x00]).write(to: tmpDir.appendingPathComponent("Work/meeting.mp3"))

        let all = await store.allRecordings()
        let filenames = Set(all.map(\.filename))
        XCTAssertTrue(filenames.contains("root.mp3"))
        XCTAssertTrue(filenames.contains("Work/meeting.mp3"))
    }

    func testRecordingsInFolder() async throws {
        try await store.createFolder(named: "Work")
        try Data([0xFF, 0xFB, 0x00]).write(to: tmpDir.appendingPathComponent("root.mp3"))
        try Data([0xFF, 0xFB, 0x00]).write(to: tmpDir.appendingPathComponent("Work/meeting.mp3"))

        let workRecs = await store.recordings(inFolder: "Work")
        XCTAssertEqual(workRecs.count, 1)
        XCTAssertEqual(workRecs[0].filename, "Work/meeting.mp3")
    }

    // MARK: - Move recording

    func testMoveRecordingToFolder() async throws {
        try await store.createFolder(named: "Work")
        try Data([0xFF, 0xFB, 0x00]).write(to: tmpDir.appendingPathComponent("meeting.mp3"))
        try Data("{}".utf8).write(to: tmpDir.appendingPathComponent("meeting.transcript.json"))
        try Data("text".utf8).write(to: tmpDir.appendingPathComponent("meeting.txt"))

        let newFilename = try await store.moveRecording(filename: "meeting.mp3", toFolder: "Work")
        XCTAssertEqual(newFilename, "Work/meeting.mp3")

        XCTAssertTrue(FileManager.default.fileExists(atPath: tmpDir.appendingPathComponent("Work/meeting.mp3").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: tmpDir.appendingPathComponent("Work/meeting.transcript.json").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: tmpDir.appendingPathComponent("Work/meeting.txt").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: tmpDir.appendingPathComponent("meeting.mp3").path))
    }

    func testMoveRecordingToRoot() async throws {
        try await store.createFolder(named: "Work")
        try Data([0xFF, 0xFB, 0x00]).write(to: tmpDir.appendingPathComponent("Work/meeting.mp3"))

        let newFilename = try await store.moveRecording(filename: "Work/meeting.mp3", toFolder: nil)
        XCTAssertEqual(newFilename, "meeting.mp3")
        XCTAssertTrue(FileManager.default.fileExists(atPath: tmpDir.appendingPathComponent("meeting.mp3").path))
    }

    // MARK: - Folder metadata on RecordingMetadata

    func testRecordingMetadataIncludesFolder() async throws {
        try await store.createFolder(named: "Personal")
        try Data([0xFF, 0xFB, 0x00]).write(to: tmpDir.appendingPathComponent("Personal/memo.mp3"))

        let all = await store.allRecordings()
        let rec = all.first { $0.filename == "Personal/memo.mp3" }
        XCTAssertNotNil(rec)
        XCTAssertEqual(rec?.folder, "Personal")
    }
}
