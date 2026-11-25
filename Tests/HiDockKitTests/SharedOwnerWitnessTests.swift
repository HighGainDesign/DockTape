// © 2026 High Gain Design. All rights reserved.
import XCTest

@testable import HiDockKit

final class SharedOwnerWitnessTests: XCTestCase {
  private struct Head: Codable, Sendable {
    let sequence: UInt64
    let value: String
  }
  private struct Fixture {
    let parent = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let writer = UUID(), library = UUID()
    var root: URL { parent.appendingPathComponent("library") }
    var head: URL { root.appendingPathComponent("owner.json") }
    var witness: SharedOwnerWitness {
      .init(directory: parent.appendingPathComponent("local"), libraryID: library, writerID: writer)
    }
    func setup() throws {
      try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    func cleanup() { try? FileManager.default.removeItem(at: parent) }
    func summary(_ bytes: Data) throws -> SharedOwnerHeadSummary {
      let value = try JSONDecoder().decode(Head.self, from: bytes)
      return .init(sequence: value.sequence, fingerprint: try SharedStateFingerprint.of(value))
    }
    func save(_ value: String, after: @escaping @Sendable () throws -> Void = {}) async throws
      -> String
    {
      try await witness.withWrite(
        at: head, key: "record", decode: { try summary($0) }, afterPublish: after
      ) { _, current in
        let previous = try current.map { try JSONDecoder().decode(Head.self, from: $0) }
        let head = Head(sequence: (previous?.sequence ?? 0) + 1, value: value)
        return .init(bytes: try JSONEncoder().encode(head), result: value)
      }
    }
  }
  private enum Interrupted: Error { case crash }
  func testNewWitnessUnderExplicitPrivateTmpAliasCanPublish() async throws {
    let parent = URL(fileURLWithPath: "/private/tmp/DockTapeWitnessAlias-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: parent) }
    let root = parent.appendingPathComponent("data/library")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let head = root.appendingPathComponent("owner.json")
    let witness = SharedOwnerWitness(directory: parent.appendingPathComponent("data/new-local"), libraryID: UUID(), writerID: UUID())
    let result = try await witness.withWrite(at: head, key: "record", decode: { bytes in
      let value = try JSONDecoder().decode(Head.self, from: bytes)
      return .init(sequence: value.sequence, fingerprint: try SharedStateFingerprint.of(value))
    }) { _, current in
      XCTAssertNil(current)
      let value = Head(sequence: 1, value: "first accepted edit")
      return .init(bytes: try JSONEncoder().encode(value), result: value.value)
    }
    XCTAssertEqual(result, "first accepted edit")
    XCTAssertTrue(FileManager.default.fileExists(atPath: witness.fileURL(for: "record").path))
    XCTAssertEqual(try JSONDecoder().decode(Head.self, from: Data(contentsOf: head)).sequence, 1)
  }
  func testWitnessSymlinkIntoLibraryCannotPublish() async throws {
    let f = Fixture(); try f.setup(); defer { f.cleanup() }
    let alias = f.parent.appendingPathComponent("local-alias")
    try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: f.root)
    let witness = SharedOwnerWitness(directory: alias, libraryID: f.library, writerID: f.writer)
    XCTAssertFalse(witness.isOutside(f.root))
    do {
      _ = try await witness.withWrite(at: f.head, key: "record", decode: { try f.summary($0) }) { _, _ in
        XCTFail("A local witness inside the shared root cannot accept a write")
        return SharedOwnerPreparedWrite(bytes: Data(), result: false)
      }
      XCTFail("Symlink escape must remain refused")
    } catch SharedLibraryOperationError.unsafePath {}
    XCTAssertFalse(FileManager.default.fileExists(atPath: f.head.path))
  }
  func testCheckpointSymlinkCannotReadOrOverwriteAnOutsideFile() async throws {
    let f = Fixture(); try f.setup(); defer { f.cleanup() }
    let target = f.parent.appendingPathComponent("unrelated.json")
    let original = Data("unrelated original".utf8)
    try original.write(to: target)
    let checkpoint = f.witness.fileURL(for: "record")
    try FileManager.default.createDirectory(at: checkpoint.deletingLastPathComponent(), withIntermediateDirectories: true)
    try FileManager.default.createSymbolicLink(at: checkpoint, withDestinationURL: target)
    do { _ = try await f.save("not accepted"); XCTFail("Checkpoint symlinks must remain refused") }
    catch SharedLibraryOperationError.unsafePath {}
    XCTAssertEqual(try Data(contentsOf: target), original)
    XCTAssertFalse(FileManager.default.fileExists(atPath: f.head.path))
  }
  func testAcceptedOwnerRollbackNeverAllocatesAReusedSequence() async throws {
    let f = Fixture()
    try f.setup()
    defer { f.cleanup() }
    _ = try await f.save("one")
    let old = try Data(contentsOf: f.head)
    _ = try await f.save("two")
    try old.write(to: f.head)
    do {
      _ = try await f.save("unseen newer user edit")
      XCTFail()
    } catch { XCTAssertEqual(error as? SharedOwnerWitnessError, .rollback) }
    XCTAssertEqual(try Data(contentsOf: f.head), old)
  }
  func testPendingPublishReplaysBeforeAnotherEditAfterInterruption() async throws {
    let f = Fixture()
    try f.setup()
    defer { f.cleanup() }
    _ = try await f.save("one")
    do {
      _ = try await f.save("two", after: { throw Interrupted.crash })
      XCTFail()
    } catch {}
    // A queued provider old version after the interrupted publish cannot
    // erase the durable intent or make the next commit reuse its sequence.
    try JSONEncoder().encode(Head(sequence: 1, value: "one")).write(to: f.head)
    let value = try await f.save("three")
    XCTAssertEqual(value, "three")
    let head = try JSONDecoder().decode(Head.self, from: Data(contentsOf: f.head))
    XCTAssertEqual(head.sequence, 3)
    XCTAssertEqual(head.value, "three")
  }
  func testCorruptLocalWitnessPreservesFilesAndNeverResetsItsCounter() async throws {
    let f = Fixture()
    try f.setup()
    defer { f.cleanup() }
    _ = try await f.save("one")
    let local = f.witness.fileURL(for: "record")
    let corrupted = Data("corrupt witness".utf8)
    try corrupted.write(to: local)
    let accepted = try Data(contentsOf: f.head)
    do {
      _ = try await f.save("two")
      XCTFail()
    } catch {}
    XCTAssertEqual(try Data(contentsOf: local), corrupted)
    XCTAssertEqual(try Data(contentsOf: f.head), accepted)
  }
  func testRealRepositoryRejectsOwnerRollbackAfterRestartWithoutPeerProof() async throws {
    let f = Fixture()
    try f.setup()
    defer { f.cleanup() }
    let entity = SharedEntityIdentity(id: UUID(), kind: .recording)
    let repository = SharedLibraryRepository(root: f.root, writerID: f.writer, witness: f.witness)
    let empty = try await repository.load(entity: entity)
    let one = try await repository.commit(
      .init(base: empty, changes: [.assign(field: "title", value: .text("One"))]))
    let file = f.root.appendingPathComponent(
      ".docktape/records/" + entity.id.uuidString.lowercased() + "/"
        + f.writer.uuidString.lowercased() + ".json")
    let old = try Data(contentsOf: file)
    _ = try await repository.commit(
      .init(base: one, changes: [.assign(field: "title", value: .text("Two"))]))
    try old.write(to: file)
    let restarted = SharedLibraryRepository(root: f.root, writerID: f.writer, witness: f.witness)
    do {
      _ = try await restarted.load(entity: entity)
      XCTFail()
    } catch { XCTAssertEqual(error as? SharedOwnerWitnessError, .rollback) }
    XCTAssertEqual(try Data(contentsOf: file), old)
  }

  func testValidatedPeerRestoresKnownCausalCoverageBeforeOwnerAllocatesAgain() async throws {
    let f = Fixture()
    try f.setup()
    defer { f.cleanup() }
    let entity = SharedEntityIdentity(id: UUID(), kind: .recording)
    let repository = SharedLibraryRepository(root: f.root, writerID: f.writer, witness: f.witness)
    let empty = try await repository.load(entity: entity)
    let one = try await repository.commit(
      .init(base: empty, changes: [.assign(field: "title", value: .text("One"))]))
    let file = f.root.appendingPathComponent(
      ".docktape/records/" + entity.id.uuidString.lowercased() + "/"
        + f.writer.uuidString.lowercased() + ".json")
    let old = try Data(contentsOf: file)
    _ = try await repository.commit(
      .init(base: one, changes: [.assign(field: "title", value: .text("Two"))]))
    let peer = SharedLibraryRepository(root: f.root, writerID: UUID())
    let acquired = try await peer.load(entity: entity)
    _ = try await peer.commit(.init(base: acquired, changes: []))
    try old.write(to: file)
    let restarted = SharedLibraryRepository(root: f.root, writerID: f.writer, witness: f.witness)
    let recovered = try await restarted.load(entity: entity)
    XCTAssertEqual(recovered.state.value(for: "title"), .text("Two"))
    let updated = try await restarted.commit(
      .init(base: recovered, changes: [.assign(field: "notes", value: .text("After recovery"))]))
    XCTAssertEqual(updated.ownerSequence, 3)
    XCTAssertEqual(updated.state.value(for: "title"), .text("Two"))
    XCTAssertEqual(updated.state.value(for: "notes"), .text("After recovery"))
  }

  func testMemberRollbackCannotForgetAWriterJoinRequestAfterRestart() async throws {
    let f = Fixture()
    try f.setup()
    defer { f.cleanup() }
    try FileManager.default.createDirectory(
      at: f.root.appendingPathComponent(".docktape"), withIntermediateDirectories: false)
    let manifest = SharedBootstrapManifest(
      schemaVersion: 1, libraryID: f.library, founder: f.writer, references: [], complete: true)
    let repository = SharedMemberRepository(
      root: f.root, writer: f.writer, manifest: manifest, witness: f.witness)
    let empty = try await repository.load()
    let one = try await repository.commit(base: empty, membership: empty.membership)
    let file = f.root.appendingPathComponent(
      ".docktape/members/" + f.writer.uuidString.lowercased() + ".json")
    let old = try Data(contentsOf: file)
    var pending = one.membership
    try pending.requestJoin(.init(writer: UUID(), label: "new Mac"))
    _ = try await repository.commit(base: one, membership: pending)
    try old.write(to: file)
    let restarted = SharedMemberRepository(
      root: f.root, writer: f.writer, manifest: manifest, witness: f.witness)
    do {
      _ = try await restarted.load()
      XCTFail()
    } catch { XCTAssertEqual(error as? SharedOwnerWitnessError, .rollback) }
    XCTAssertEqual(try Data(contentsOf: file), old)
  }

  func testAcknowledgmentRollbackCannotReactivateWithdrawnPermission() async throws {
    let f = Fixture()
    try f.setup()
    defer { f.cleanup() }
    let id = UUID()
    var state = SharedEntityState(id: id, kind: .recording)
    try state.assign(field: "title", value: .text("Synthetic"), writer: f.writer)
    try state.delete(writer: f.writer)
    let authority = SharedMaterializationAuthority(
      libraryID: f.library, state: state,
      membership: .init(libraryID: f.library, founder: f.writer, bootstrapFingerprint: "fixture"),
      acknowledgments: [], hasPendingWork: false, pathOwners: [:])
    let store = SharedOperationAcknowledgmentStore(
      root: f.root, libraryID: f.library, writer: f.writer, witness: f.witness)
    _ = try await store.acknowledge(purpose: .delete, authority: { authority })
    let file = f.root.appendingPathComponent(
      ".docktape/acknowledgments/" + id.uuidString + "/" + f.writer.uuidString + ".json")
    let old = try Data(contentsOf: file)
    try await store.withdraw(entity: id)
    try old.write(to: file)
    let restarted = SharedOperationAcknowledgmentStore(
      root: f.root, libraryID: f.library, writer: f.writer, witness: f.witness)
    do {
      _ = try await restarted.load(entity: id)
      XCTFail()
    } catch { XCTAssertEqual(error as? SharedOwnerWitnessError, .rollback) }
    XCTAssertEqual(try Data(contentsOf: file), old)
  }

  func testRetiredGenerationFloorCannotStandInForMissingLiveFields() throws {
    let writer = UUID()
    let old = UUID()
    let active = UUID()
    let hash = String(repeating: "a", count: 64)
    let title = SharedOwnerHeadSummary(
      sequence: 1, fingerprint: hash, contexts: ["title": [.init(writer: writer, counter: 4)]])
    let generation = SharedOwnerHeadSummary(
      sequence: 1, fingerprint: hash,
      contexts: [
        "transcript.edits." + old.uuidString + ".name": [.init(writer: writer, counter: 4)]
      ])
    let retired = SharedOwnerHeadSummary(
      sequence: 2, fingerprint: hash,
      retired: [.init(writer: writer, counter: 10)], activeGenerations: [active])
    XCTAssertFalse(try retired.covers(title))
    XCTAssertTrue(try retired.covers(generation))
    let stillActive = SharedOwnerHeadSummary(
      sequence: 2, fingerprint: hash,
      retired: [.init(writer: writer, counter: 10)], activeGenerations: [old])
    XCTAssertFalse(try stillActive.covers(generation))
  }

}
