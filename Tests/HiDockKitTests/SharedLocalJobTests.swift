// © 2026 High Gain Design. All rights reserved.
import XCTest
@testable import HiDockKit

final class SharedLocalJobTests: XCTestCase {
    private var roots: [URL] = []
    override func tearDown() { for root in roots { try? FileManager.default.removeItem(at: root) } }
    private func fixture() async throws -> (URL, SharedLibraryCoordinator, SharedLibraryCoordinator, SharedEntityIdentity) {
        let parent = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        roots.append(parent)
        let root = parent.appendingPathComponent("library")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("single original".utf8).write(to: root.appendingPathComponent("Meeting.mp3"))
        let writer = UUID(), local = parent.appendingPathComponent("local")
        let one = SharedLibraryCoordinator(root: root, writerID: writer, witnessDirectory: local)
        let manifest = try await one.enable()
        _ = try await one.projectOutputs()
        let two = SharedLibraryCoordinator(root: root, writerID: writer, witnessDirectory: local, trash: { url in
            let disposed = parent.appendingPathComponent("disposed")
            try FileManager.default.createDirectory(at: disposed, withIntermediateDirectories: true)
            try FileManager.default.moveItem(at: url, to: disposed.appendingPathComponent(url.lastPathComponent))
        })
        return (root, one, two, manifest.references.first { $0.entity.kind == .recording }!.entity)
    }
    func testAnotherCoordinatorSeesActiveWorkAndCannotRemoveOriginal() async throws {
        let (root, one, two, entity) = try await fixture()
        let token = try await one.pinJob(entity)
        let permission = try await two.operationAuthority(entity: entity, paths: ["Meeting.mp3"])
        XCTAssertTrue(permission.hasPendingWork)
        let pending = try await two.deleteSharedRecording(filename: "Meeting.mp3")
        XCTAssertEqual(pending.result, .waitingForAcknowledgments)
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("Meeting.mp3").path))
        await one.finishJob(token)
        let released = try await two.operationAuthority(entity: entity, paths: ["Meeting.mp3"])
        XCTAssertFalse(released.hasPendingWork)
    }
    func testAnotherCoordinatorCannotRelocateAudioWhileJobOwnsIt() async throws {
        let (root, one, two, entity) = try await fixture()
        let token = try await one.pinJob(entity)
        let pending = try await two.relocateRecording(filename: "Meeting.mp3", title: "Renamed")
        XCTAssertNotEqual(pending.result, .complete)
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("Meeting.mp3").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("Renamed.mp3").path))
        await one.finishJob(token)
        let completed = try await two.resumeRecordingOperation(id: entity.id)
        XCTAssertEqual(completed.result, .complete)
    }
}
