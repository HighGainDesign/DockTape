// © 2026 High Gain Design. All rights reserved.
import XCTest

@testable import HiDockKit

final class SharedLibraryRepositoryTests: XCTestCase {
    private let a = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
    private let b = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
    private let id = UUID(uuidString: "10000000-0000-0000-0000-000000000001")!
    private var temporary: [URL] = []

    private func root() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        temporary.append(url)
        return url
    }

    override func tearDown() {
        for url in temporary { try? FileManager.default.removeItem(at: url) }
        temporary = []
    }

    private func head(_ root: URL, writer: UUID) -> URL {
        root.appendingPathComponent(
            ".docktape/records/\(id.uuidString.lowercased())/\(writer.uuidString.lowercased()).json")
    }

    private func deliver(_ source: URL, to destination: URL) throws {
        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(contentsOf: source).write(to: destination, options: .atomic)
    }

    func testIndependentOfflineEditsSurviveRealFileDeliveryAndRestart() async throws {
        let leftRoot = try root()
        let rightRoot = try root()
        let left = SharedLibraryRepository(root: leftRoot, writerID: a)
        let right = SharedLibraryRepository(root: rightRoot, writerID: b)
        let entity = SharedEntityIdentity(id: id, kind: .recording)
        let leftBase = try await left.load(entity: entity)
        let rightBase = try await right.load(entity: entity)
        _ = try await left.commit(.init(base: leftBase, changes: [.assign(field: "title", value: .text("Alpha"))]))
        _ = try await right.commit(.init(base: rightBase, changes: [.assign(field: "folder", value: .text("Calls"))]))
        try deliver(head(leftRoot, writer: a), to: head(rightRoot, writer: a))
        try deliver(head(rightRoot, writer: b), to: head(leftRoot, writer: b))
        let first = try await left.load(entity: entity)
        let second = try await right.load(entity: entity)
        XCTAssertEqual(first.state.value(for: "title"), .text("Alpha"))
        XCTAssertEqual(first.state.value(for: "folder"), .text("Calls"))
        XCTAssertEqual(first.state, second.state)
        let restarted = SharedLibraryRepository(root: leftRoot, writerID: a)
        let afterRestart = try await restarted.load(entity: entity)
        XCTAssertEqual(afterRestart.state, first.state)
        XCTAssertTrue(afterRestart.state.conflicts.isEmpty)
    }

    func testStaleSameMacDraftRebasesAnIndependentFieldUnderCoordination() async throws {
        let directory = try root()
        let one = SharedLibraryRepository(root: directory, writerID: a)
        let two = SharedLibraryRepository(root: directory, writerID: a)
        let entity = SharedEntityIdentity(id: id, kind: .recording)
        let baseOne = try await one.load(entity: entity)
        let baseTwo = try await two.load(entity: entity)
        _ = try await one.commit(.init(base: baseOne, changes: [.assign(field: "title", value: .text("Alpha"))]))
        let result = try await two.commit(
            .init(base: baseTwo, changes: [.assign(field: "folder", value: .text("Calls"))]))
        XCTAssertEqual(result.state.value(for: "title"), .text("Alpha"))
        XCTAssertEqual(result.state.value(for: "folder"), .text("Calls"))
        XCTAssertEqual(result.ownerSequence, 2)
    }

    func testStaleSameFieldDraftIsRejectedWithoutReplacingAcceptedBytes() async throws {
        let directory = try root()
        let one = SharedLibraryRepository(root: directory, writerID: a)
        let two = SharedLibraryRepository(root: directory, writerID: a)
        let entity = SharedEntityIdentity(id: id, kind: .recording)
        let old = try await two.load(entity: entity)
        _ = try await one.commit(.init(base: old, changes: [.assign(field: "title", value: .text("Accepted"))]))
        let accepted = try Data(contentsOf: head(directory, writer: a))
        do {
            _ = try await two.commit(.init(base: old, changes: [.assign(field: "title", value: .text("Stale"))]))
            XCTFail("Stale draft must not overwrite a same-field change")
        } catch { XCTAssertEqual(error as? SharedLibraryRepositoryError, .staleRevision) }
        XCTAssertEqual(try Data(contentsOf: head(directory, writer: a)), accepted)
    }

    func testOldAndRepeatedDeliveryCannotUndoAResolvedPublishedObservation() async throws {
        let leftRoot = try root()
        let rightRoot = try root()
        let left = SharedLibraryRepository(root: leftRoot, writerID: a)
        let right = SharedLibraryRepository(root: rightRoot, writerID: b)
        let entity = SharedEntityIdentity(id: id, kind: .recording)
        let start = try await left.load(entity: entity)
        let old = try await left.commit(.init(base: start, changes: [.assign(field: "title", value: .text("Old"))]))
        let staleBytes = try Data(contentsOf: head(leftRoot, writer: a))
        _ = try await left.commit(.init(base: old, changes: [.assign(field: "title", value: .text("Current"))]))
        try deliver(head(leftRoot, writer: a), to: head(rightRoot, writer: a))
        let observed = try await right.load(entity: entity)
        _ = try await right.commit(.init(base: observed, changes: []))
        try staleBytes.write(to: head(rightRoot, writer: a), options: .atomic)
        let result = try await right.load(entity: entity)
        XCTAssertEqual(result.state.value(for: "title"), .text("Current"))
        let restarted = SharedLibraryRepository(root: rightRoot, writerID: b)
        let afterRestart = try await restarted.load(entity: entity)
        XCTAssertEqual(afterRestart.state.value(for: "title"), .text("Current"))
    }

    func testRepeatedObservationDoesNotCreateAnEndlessMetadataWriteLoop() async throws {
        let leftRoot = try root()
        let rightRoot = try root()
        let left = SharedLibraryRepository(root: leftRoot, writerID: a)
        let right = SharedLibraryRepository(root: rightRoot, writerID: b)
        let entity = SharedEntityIdentity(id: id, kind: .recording)
        let base = try await left.load(entity: entity)
        _ = try await left.commit(.init(base: base, changes: [.assign(field: "title", value: .text("Alpha"))]))
        try deliver(head(leftRoot, writer: a), to: head(rightRoot, writer: a))
        let observed = try await right.load(entity: entity)
        _ = try await right.commit(.init(base: observed, changes: []))
        try deliver(head(rightRoot, writer: b), to: head(leftRoot, writer: b))
        let first = try await left.load(entity: entity)
        _ = try await left.commit(.init(base: first, changes: []))
        let beforeLeft = try Data(contentsOf: head(leftRoot, writer: a))
        let beforeRight = try Data(contentsOf: head(rightRoot, writer: b))
        for _ in 0..<4 {
            try deliver(head(leftRoot, writer: a), to: head(rightRoot, writer: a))
            let second = try await right.load(entity: entity)
            _ = try await right.commit(.init(base: second, changes: []))
            try deliver(head(rightRoot, writer: b), to: head(leftRoot, writer: b))
            let third = try await left.load(entity: entity)
            _ = try await left.commit(.init(base: third, changes: []))
        }
        XCTAssertEqual(try Data(contentsOf: head(leftRoot, writer: a)), beforeLeft)
        XCTAssertEqual(try Data(contentsOf: head(rightRoot, writer: b)), beforeRight)
    }

    func testOwnerRollbackUsesReplicatedHighWaterRatherThanReusingSequence() async throws {
        let leftRoot = try root()
        let rightRoot = try root()
        let left = SharedLibraryRepository(root: leftRoot, writerID: a)
        let right = SharedLibraryRepository(root: rightRoot, writerID: b)
        let entity = SharedEntityIdentity(id: id, kind: .recording)
        let firstBase = try await left.load(entity: entity)
        _ = try await left.commit(.init(base: firstBase, changes: [.assign(field: "title", value: .text("Alpha"))]))
        let obsoleteOwner = try Data(contentsOf: head(leftRoot, writer: a))
        let peerBase = try await right.load(entity: entity)
        _ = try await right.commit(.init(base: peerBase, changes: [.assign(field: "folder", value: .text("Calls"))]))
        try deliver(head(rightRoot, writer: b), to: head(leftRoot, writer: b))
        let observed = try await left.load(entity: entity)
        let published = try await left.commit(.init(base: observed, changes: []))
        XCTAssertEqual(published.ownerSequence, 2)
        try deliver(head(leftRoot, writer: a), to: head(rightRoot, writer: a))
        let seen = try await right.load(entity: entity)
        var peer = try await right.commit(.init(base: seen, changes: []))
        peer = try await right.commit(.init(base: peer, changes: [.assign(field: "peer-one", value: .text("One"))]))
        _ = try await right.commit(.init(base: peer, changes: [.assign(field: "peer-two", value: .text("Two"))]))
        try deliver(head(rightRoot, writer: b), to: head(leftRoot, writer: b))
        try obsoleteOwner.write(to: head(leftRoot, writer: a), options: .atomic)
        let restored = try await left.load(entity: entity)
        let accepted = try await left.commit(
            .init(base: restored, changes: [.assign(field: "note", value: .text("Next"))]))
        XCTAssertEqual(
            accepted.ownerSequence, 3,
            "Use this writer's observed high water, not the old file or another writer's sequence")
        XCTAssertEqual(accepted.state.value(for: "folder"), .text("Calls"))
        XCTAssertEqual(accepted.state.value(for: "peer-two"), .text("Two"))
    }

    func testUnknownSchemaAndChecksumFailureAreErrorsInsteadOfEmptyLibraries() async throws {
        let directory = try root()
        let repository = SharedLibraryRepository(root: directory, writerID: a)
        let entity = SharedEntityIdentity(id: id, kind: .recording)
        let base = try await repository.load(entity: entity)
        _ = try await repository.commit(.init(base: base, changes: [.assign(field: "title", value: .text("Accepted"))]))
        let accepted = try Data(contentsOf: head(directory, writer: a))
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: accepted) as? [String: Any])
        object["schemaVersion"] = 999
        try JSONSerialization.data(withJSONObject: object).write(to: head(directory, writer: a), options: .atomic)
        do {
            _ = try await repository.load(entity: entity)
            XCTFail("Unknown schema must fail")
        } catch { XCTAssertEqual(error as? SharedLibraryRepositoryError, .unsupportedSchema(999)) }
        try accepted.write(to: head(directory, writer: a), options: .atomic)
        object = try XCTUnwrap(JSONSerialization.jsonObject(with: accepted) as? [String: Any])
        object["checksum"] = String(repeating: "0", count: 64)
        try JSONSerialization.data(withJSONObject: object).write(to: head(directory, writer: a), options: .atomic)
        do {
            _ = try await repository.load(entity: entity)
            XCTFail("Corruption must not become an empty state")
        } catch { XCTAssertEqual(error as? SharedLibraryRepositoryError, .invalidEnvelope) }
    }

    func testProviderConflictCopyIsValidatedByContentAndRemainsPresent() async throws {
        let leftRoot = try root()
        let rightRoot = try root()
        let entity = SharedEntityIdentity(id: id, kind: .recording)
        let left = SharedLibraryRepository(root: leftRoot, writerID: a)
        let right = SharedLibraryRepository(root: rightRoot, writerID: b)
        let first = try await left.load(entity: entity)
        let second = try await right.load(entity: entity)
        _ = try await left.commit(.init(base: first, changes: [.assign(field: "title", value: .text("Alpha"))]))
        _ = try await right.commit(.init(base: second, changes: [.assign(field: "title", value: .text("Beta"))]))
        let copy = head(leftRoot, writer: a).deletingLastPathComponent().appendingPathComponent(
            "provider conflict copy.json")
        try deliver(head(rightRoot, writer: b), to: copy)
        let result = try await left.load(entity: entity)
        XCTAssertEqual(result.state.fields["title"]?.values, [.text("Alpha"), .text("Beta")])
        XCTAssertTrue(FileManager.default.fileExists(atPath: copy.path), "Loading must not remove a conflict copy")
        let identities = try await left.scan()
        XCTAssertEqual(identities, [entity])
        try Data("{\"schemaVersion\":1,\"state\":{}".utf8).write(to: copy, options: .atomic)
        do {
            _ = try await left.load(entity: entity)
            XCTFail("Partial conflict state must be an error")
        } catch { XCTAssertTrue(error is DecodingError) }
        XCTAssertTrue(FileManager.default.fileExists(atPath: copy.path))
    }

    func testPermissionFailureLeavesAcceptedStateUntouched() async throws {
        let directory = try root()
        let repository = SharedLibraryRepository(root: directory, writerID: a)
        let entity = SharedEntityIdentity(id: id, kind: .recording)
        let base = try await repository.load(entity: entity)
        let current = try await repository.commit(
            .init(base: base, changes: [.assign(field: "title", value: .text("Accepted"))]))
        let url = head(directory, writer: a)
        let bytes = try Data(contentsOf: url)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o555], ofItemAtPath: url.deletingLastPathComponent().path)
        defer {
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o755], ofItemAtPath: url.deletingLastPathComponent().path)
        }
        do {
            _ = try await repository.commit(
                .init(base: current, changes: [.assign(field: "title", value: .text("Not accepted"))]))
            XCTFail("Write into non-writable fixture must fail")
        } catch {}
        XCTAssertEqual(try Data(contentsOf: url), bytes)
    }

    func testForeignWriterEnvelopeCannotClaimTheOwnerPath() async throws {
        let directory = try root()
        let repository = SharedLibraryRepository(root: directory, writerID: a)
        let entity = SharedEntityIdentity(id: id, kind: .recording)
        let base = try await repository.load(entity: entity)
        _ = try await repository.commit(.init(base: base, changes: [.assign(field: "title", value: .text("Alpha"))]))
        let bytes = try Data(contentsOf: head(directory, writer: a))
        try bytes.write(to: head(directory, writer: b), options: .atomic)
        do {
            _ = try await repository.load(entity: entity)
            XCTFail("Filename/header writer mismatch must not be accepted")
        } catch { XCTAssertEqual(error as? SharedLibraryRepositoryError, .invalidEnvelope) }
    }

    func testSnapshotFromAnotherLibraryOrWriterCannotBeCommitted() async throws {
        let directory = try root()
        let other = try root()
        let repository = SharedLibraryRepository(root: directory, writerID: a)
        let foreign = SharedLibraryRepository(root: other, writerID: a)
        let entity = SharedEntityIdentity(id: id, kind: .recording)
        let snapshot = try await foreign.load(entity: entity)
        do {
            _ = try await repository.commit(
                .init(base: snapshot, changes: [.assign(field: "title", value: .text("Wrong library"))]))
            XCTFail()
        } catch { XCTAssertEqual(error as? SharedLibraryRepositoryError, .differentBinding) }
        let otherWriter = SharedLibraryRepository(root: directory, writerID: b)
        let wrongWriter = try await otherWriter.load(entity: entity)
        do {
            _ = try await repository.commit(
                .init(base: wrongWriter, changes: [.assign(field: "title", value: .text("Wrong writer"))]))
            XCTFail()
        } catch { XCTAssertEqual(error as? SharedLibraryRepositoryError, .differentBinding) }
    }

    func testUnavailableLibraryRootIsNotRecreatedAsAnEmptyLocalLibrary() async throws {
        let directory = try root()
        let repository = SharedLibraryRepository(root: directory, writerID: a)
        let entity = SharedEntityIdentity(id: id, kind: .recording)
        let base = try await repository.load(entity: entity)
        try FileManager.default.removeItem(at: directory)
        do {
            _ = try await repository.load(entity: entity)
            XCTFail("Unavailable library is not an empty library")
        } catch { XCTAssertEqual(error as? SharedLibraryRepositoryError, .unavailableRoot) }
        do {
            _ = try await repository.commit(
                .init(base: base, changes: [.assign(field: "title", value: .text("Do not recreate"))]))
            XCTFail()
        } catch { XCTAssertEqual(error as? SharedLibraryRepositoryError, .unavailableRoot) }
        do {
            _ = try await repository.scan()
            XCTFail("Scan must not present an absent root as empty")
        } catch { XCTAssertEqual(error as? SharedLibraryRepositoryError, .unavailableRoot) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
    }

    func testMetadataSymlinkCannotReadOrReplaceAnOutsideFile() async throws {
        let directory = try root()
        let outside = try root()
        let repository = SharedLibraryRepository(root: directory, writerID: a)
        let entity = SharedEntityIdentity(id: id, kind: .recording)
        let base = try await repository.load(entity: entity)
        let destination = head(directory, writer: a)
        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        let foreign = outside.appendingPathComponent("untouched.json")
        let bytes = Data("Do not read or overwrite outside the selected library".utf8)
        try bytes.write(to: foreign)
        try FileManager.default.createSymbolicLink(at: destination, withDestinationURL: foreign)
        do {
            _ = try await repository.commit(
                .init(base: base, changes: [.assign(field: "title", value: .text("Wrong"))]))
            XCTFail()
        } catch { XCTAssertEqual(error as? SharedLibraryRepositoryError, .invalidPath) }
        XCTAssertEqual(try Data(contentsOf: foreign), bytes)
    }
}
