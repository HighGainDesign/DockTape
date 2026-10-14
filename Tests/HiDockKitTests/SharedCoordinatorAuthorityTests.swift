// © 2026 High Gain Design. All rights reserved.
import XCTest
@testable import HiDockKit

final class SharedCoordinatorAuthorityTests: XCTestCase {
    private var roots: [URL] = []
    override func tearDown() { for root in roots { try? FileManager.default.removeItem(at: root) } }
    private func fixture() async throws -> (URL, SharedLibraryCoordinator, SharedEntityIdentity) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        roots.append(directory)
        let root = directory.appendingPathComponent("library")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("synthetic audio".utf8).write(to: root.appendingPathComponent("Meeting.mp3"))
        let coordinator = SharedLibraryCoordinator(root: root, writerID: UUID(),
                                                  witnessDirectory: directory.appendingPathComponent("local"))
        let manifest = try await coordinator.enable()
        return (root, coordinator, manifest.references.first { $0.entity.kind == .recording }!.entity)
    }
    func testActualCoordinatorSuppliesOwnedPathsAndRevokesLeaseBeforeEdit() async throws {
        let (_, coordinator, entity) = try await fixture()
        let authority = try await coordinator.operationAuthority(entity: entity, paths: ["Meeting.mp3", "Meeting.summary.json"])
        XCTAssertEqual(authority.pathOwners["Meeting.mp3"], [entity.id])
        XCTAssertFalse(authority.revisionLease.isRevoked)
        let base = try await coordinator.read(entity)
        _ = try await coordinator.edit(.init(base: base, changes: [.assign(field: "title", value: .text("Renamed"))]))
        XCTAssertTrue(authority.revisionLease.isRevoked)
        let fresh = try await coordinator.operationAuthority(entity: entity, paths: ["Renamed.mp3"])
        XCTAssertFalse(fresh.revisionLease.isRevoked)
        XCTAssertEqual(fresh.pathOwners["Renamed.mp3"], [entity.id])
    }
    func testUnchangedAuthorityReadsShareLeaseButRefreshRevokesIt() async throws {
        let (_, coordinator, entity) = try await fixture()
        let first = try await coordinator.operationAuthority(entity: entity, paths: ["Meeting.mp3"])
        _ = try await coordinator.operationAuthority(entity: entity, paths: ["Meeting.mp3"])
        XCTAssertFalse(first.revisionLease.isRevoked)
        try await coordinator.refresh()
        XCTAssertTrue(first.revisionLease.isRevoked)
    }
    func testPinnedJobSuspendsDestructionAndFinishingInvalidatesPermission() async throws {
        let (_, coordinator, entity) = try await fixture()
        let old = try await coordinator.operationAuthority(entity: entity, paths: ["Meeting.mp3"])
        let job = try await coordinator.pinJob(entity)
        XCTAssertTrue(old.revisionLease.isRevoked)
        let pending = try await coordinator.operationAuthority(entity: entity, paths: ["Meeting.mp3"])
        XCTAssertTrue(pending.hasPendingWork)
        XCTAssertThrowsError(try pending.acknowledgment(by: coordinator.writerID, purpose: .replaceAudio))
        await coordinator.finishJob(job)
        XCTAssertTrue(pending.revisionLease.isRevoked)
        let finished = try await coordinator.operationAuthority(entity: entity, paths: ["Meeting.mp3"])
        XCTAssertFalse(finished.hasPendingWork)
    }
    func testSingleEntityAuthorityCannotWriteAggregateOrUnownedPaths() async throws {
        let (_, coordinator, entity) = try await fixture()
        for path in ["library.json", "SomeoneElse.summary.json"] {
            do {
                _ = try await coordinator.operationAuthority(entity: entity, paths: [path])
                XCTFail("Single-entity authority must not replace aggregate/unowned paths")
            } catch {}
        }
    }
    private final class Barrier: @unchecked Sendable {
        private let condition = NSCondition()
        private var entered = false
        private var released = false
        private var completed = false
        func block() throws {
            condition.lock(); defer { condition.unlock() }
            entered = true; condition.broadcast()
            let deadline = Date().addingTimeInterval(5)
            while !released {
                if !condition.wait(until: deadline) { throw CocoaError(.userCancelled) }
            }
        }
        func waitForEntry() -> Bool {
            condition.lock(); defer { condition.unlock() }
            let deadline = Date().addingTimeInterval(5)
            while !entered { if !condition.wait(until: deadline) { return false } }
            return true
        }
        func release() { condition.lock(); released = true; condition.broadcast(); condition.unlock() }
        func markComplete() { condition.lock(); completed = true; condition.unlock() }
        func isComplete() -> Bool { condition.lock(); defer { condition.unlock() }; return completed }
    }
    func testActualOwnerEditWaitsUntilPhysicalCommitAndReceiptFinish() async throws {
        let (root, coordinator, entity) = try await fixture()
        let before = try await coordinator.read(entity)
        let permission = try await coordinator.operationAuthority(entity: entity, paths: ["Meeting.summary.json"])
        let barrier = Barrier()
        let materializer = try await coordinator.makeMaterializer(entity: entity, paths: ["Meeting.summary.json"],
            receipts: root.deletingLastPathComponent().appendingPathComponent("receipts"),
            afterMutation: { _ in try barrier.block() })
        let operation = try SharedLibraryOperation(libraryID: before.libraryID, entity: entity,
            inputRevision: "before", outputRevision: SharedStateFingerprint.of(before.state),
            steps: [.write(path: "Meeting.summary.json", expectedFingerprint: nil, bytes: Data("{}".utf8))])
        let physical = Task { try await materializer.replay(operation) }
        defer { barrier.release() }
        let entered = await Task.detached { barrier.waitForEntry() }.value
        XCTAssertTrue(entered)
        let edit = Task {
            defer { barrier.markComplete() }
            return try await coordinator.edit(.init(base: before,
                changes: [.assign(field: "title", value: .text("Renamed"))]))
        }
        let deadline = Date().addingTimeInterval(3)
        while !permission.revisionLease.isRevoked, Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(permission.revisionLease.isRevoked, "The edit must have started, revoking old permission")
        let observation = Date().addingTimeInterval(0.3)
        while !barrier.isComplete(), Date() < observation { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertFalse(barrier.isComplete(), "A started owner edit must remain pending during the physical phase")
        // A new coordinated read queues behind the pending writer, which
        // itself must wait for this deliberately paused physical lease. Read
        // the immutable on-disk head for this assertion instead of creating a
        // reader → writer → physical-barrier cycle in the test.
        struct OwnerHead: Decodable { let state: SharedEntityState }
        let ownerFile = root.appendingPathComponent(".docktape/records/" + entity.id.uuidString.lowercased())
            .appendingPathComponent(coordinator.writerID.uuidString.lowercased() + ".json")
        let during = try JSONDecoder().decode(OwnerHead.self, from: Data(contentsOf: ownerFile))
        XCTAssertEqual(during.state.value(for: "title"), .text("Meeting"),
                       "No accepted local edit may cross a physical commit/receipt boundary")
        barrier.release()
        let result = try await physical.value
        XCTAssertEqual(result, .complete)
        let accepted = try await edit.value
        XCTAssertEqual(accepted.state.value(for: "title"), .text("Renamed"))
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("Meeting.summary.json")), Data("{}".utf8))
    }

    func testAnotherSameWriterCoordinatorCannotLeaveAStalePhysicalPermissionUsable() async throws {
        let (root, one, entity) = try await fixture()
        let before = try await one.read(entity)
        let old = try await one.operationAuthority(entity: entity, paths: ["Meeting.summary.json"])
        let local = root.deletingLastPathComponent().appendingPathComponent("local")
        let two = SharedLibraryCoordinator(root: root, writerID: one.writerID, witnessDirectory: local)
        let other = try await two.read(entity)
        _ = try await two.edit(.init(base: other, changes: [.assign(field: "title", value: .text("Renamed"))]))
        XCTAssertFalse(old.revisionLease.isRevoked, "A different process cannot cancel an in-memory Progress object")
        let gate = SharedLibraryLocalGate(file: local.appendingPathComponent("Gates")
            .appendingPathComponent(before.libraryID.uuidString).appendingPathComponent(one.writerID.uuidString + ".lock"))
        let materializer = SharedLibraryMaterializer(root: root,
            receipts: root.deletingLastPathComponent().appendingPathComponent("receipts"), authority: { old }, gate: gate)
        let operation = try SharedLibraryOperation(libraryID: before.libraryID, entity: entity,
            inputRevision: "before", outputRevision: SharedStateFingerprint.of(before.state),
            steps: [.write(path: "Meeting.summary.json", expectedFingerprint: nil, bytes: Data("{}".utf8))])
        let result = try await materializer.replay(operation)
        XCTAssertEqual(result, .needsReplanning)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("Meeting.summary.json").path))
    }

    func testAReplayCannotExtendSingleEntityPermissionToAnUnrequestedAggregate() async throws {
        let (root, coordinator, entity) = try await fixture()
        let before = try await coordinator.read(entity)
        let materializer = try await coordinator.makeMaterializer(entity: entity, paths: ["Meeting.summary.json"],
            receipts: root.deletingLastPathComponent().appendingPathComponent("receipts"))
        let operation = try SharedLibraryOperation(libraryID: before.libraryID, entity: entity,
            inputRevision: "before", outputRevision: SharedStateFingerprint.of(before.state),
            steps: [.write(path: "library.json", expectedFingerprint: nil, bytes: Data("{}".utf8))])
        do {
            _ = try await materializer.replay(operation)
            XCTFail("A replay must not extend permission to a root-wide aggregate")
        } catch SharedLibraryOperationError.pathConflict("library.json") {}
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("library.json").path))
    }
    func testLocalGateCannotUseTheProviderRootOrAPathInsideIt() async throws {
        let (root, _, _) = try await fixture()
        for file in [root, root.appendingPathComponent("commit.lock")] {
            XCTAssertThrowsError(try SharedLibraryLocalGate(file: file).items(outside: root))
        }
    }

    func testPhysicalPermissionCannotFollowAReboundLibraryAtTheSameRootPath() async throws {
        let (root, coordinator, entity) = try await fixture()
        let before = try await coordinator.read(entity)
        let permission = try await coordinator.operationAuthority(entity: entity, paths: ["Meeting.summary.json"])
        let header = root.appendingPathComponent(".docktape/format.json")
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: header)) as? [String: Any])
        object["libraryID"] = UUID().uuidString
        try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]).write(to: header, options: .atomic)
        let local = root.deletingLastPathComponent().appendingPathComponent("local")
        let gate = SharedLibraryLocalGate(file: local.appendingPathComponent("Gates")
            .appendingPathComponent(before.libraryID.uuidString).appendingPathComponent(coordinator.writerID.uuidString + ".lock"))
        let materializer = SharedLibraryMaterializer(root: root,
            receipts: root.deletingLastPathComponent().appendingPathComponent("receipts"), authority: { permission }, gate: gate)
        let operation = try SharedLibraryOperation(libraryID: before.libraryID, entity: entity,
            inputRevision: "before", outputRevision: SharedStateFingerprint.of(before.state),
            steps: [.write(path: "Meeting.summary.json", expectedFingerprint: nil, bytes: Data("{}".utf8))])
        let result = try await materializer.replay(operation)
        XCTAssertEqual(result, .needsReplanning)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("Meeting.summary.json").path))
    }

}
