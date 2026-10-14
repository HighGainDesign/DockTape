// © 2026 High Gain Design. All rights reserved.
import XCTest

@testable import HiDockKit

final class SharedLibraryOperationTests: XCTestCase {
  private actor Authority {
    var value: SharedMaterializationAuthority
    init(_ value: SharedMaterializationAuthority) { self.value = value }
    func current() -> SharedMaterializationAuthority { value }
    func update(_ value: SharedMaterializationAuthority) {
      self.value.revisionLease.revoke()
      var fresh = value
      fresh.revisionLease = .init()
      self.value = fresh
    }
  }
  private struct Fixture {
    let root: URL
    let receipts: URL
    let library = UUID()
    let writer = UUID()
    let entity = SharedEntityIdentity(id: UUID(), kind: .recording)
    var state: SharedEntityState
    let authority: Authority
    init(deleted: Bool = false) throws {
      let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
        UUID().uuidString)
      root = directory.appendingPathComponent("library")
      receipts = directory.appendingPathComponent("local-receipts")
      try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
      state = SharedEntityState(id: entity.id, kind: .recording)
      try state.assign(field: "title", value: .text("new"), writer: writer)
      if deleted { try state.delete(writer: writer) }
      let membership = SharedLibraryMembership(
        libraryID: library, founder: writer, bootstrapFingerprint: "bootstrap")
      authority = Authority(
        .init(
          libraryID: library, state: state, membership: membership,
          acknowledgments: [], hasPendingWork: false,
          pathOwners: ["old.mp3": [entity.id], "new.mp3": [entity.id]]))
    }
    func materializer(after: @escaping @Sendable (Int) throws -> Void = { _ in })
      -> SharedLibraryMaterializer
    {
      SharedLibraryMaterializer(
        root: root, receipts: receipts, authority: { await authority.current() },
        afterMutation: after)
    }
    func operation(_ steps: [SharedLibraryOperation.Step]) throws -> SharedLibraryOperation {
      try .init(
        libraryID: library, entity: entity, inputRevision: "previous",
        outputRevision: SharedStateFingerprint.of(state), steps: steps)
    }
    func cleanup() { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
  }
  private enum Interrupted: Error { case crash }

  func testMoveReplayAfterFilesystemChangePreservesSingleCopyAndCompanion() async throws {
    let f = try Fixture()
    defer { f.cleanup() }
    let bytes = Data("synthetic audio".utf8)
    try bytes.write(to: f.root.appendingPathComponent("old.mp3"))
    try Data("transcript".utf8).write(to: f.root.appendingPathComponent("old.transcript.json"))
    var auth = await f.authority.current()
    auth.pathOwners["old.transcript.json"] = [f.entity.id]
    auth.pathOwners["new.transcript.json"] = [f.entity.id]
    await f.authority.update(auth)
    let op = try f.operation([
      .move(
        source: "old.mp3", destination: "new.mp3",
        fingerprint: SharedLibraryOperation.fingerprint(bytes)),
      .move(
        source: "old.transcript.json", destination: "new.transcript.json",
        fingerprint: SharedLibraryOperation.fingerprint(Data("transcript".utf8))),
    ])
    do {
      _ = try await f.materializer(after: { _ in throw Interrupted.crash }).replay(op)
      XCTFail()
    } catch { XCTAssertTrue(error is Interrupted) }
    XCTAssertFalse(
      FileManager.default.fileExists(atPath: f.root.appendingPathComponent("old.mp3").path))
    let result = try await f.materializer().replay(op)
    XCTAssertEqual(result, .complete)
    XCTAssertEqual(try Data(contentsOf: f.root.appendingPathComponent("new.mp3")), bytes)
    XCTAssertEqual(
      try Data(contentsOf: f.root.appendingPathComponent("new.transcript.json")),
      Data("transcript".utf8))
    let again = try await f.materializer().replay(op)
    XCTAssertEqual(again, .complete)
  }
  func testForeignDestinationWithIdenticalBytesIsNeverAdoptedOrOverwritten() async throws {
    let f = try Fixture()
    defer { f.cleanup() }
    let bytes = Data("same bytes different recording".utf8)
    try bytes.write(to: f.root.appendingPathComponent("old.mp3"))
    try bytes.write(to: f.root.appendingPathComponent("new.mp3"))
    var auth = await f.authority.current()
    auth.pathOwners["new.mp3"] = [UUID()]
    await f.authority.update(auth)
    let op = try f.operation([
      .move(
        source: "old.mp3", destination: "new.mp3",
        fingerprint: SharedLibraryOperation.fingerprint(bytes))
    ])
    do {
      _ = try await f.materializer().replay(op)
      XCTFail()
    } catch { XCTAssertEqual(error as? SharedLibraryOperationError, .pathConflict("new.mp3")) }
    XCTAssertEqual(try Data(contentsOf: f.root.appendingPathComponent("old.mp3")), bytes)
    XCTAssertEqual(try Data(contentsOf: f.root.appendingPathComponent("new.mp3")), bytes)
  }
  func testUnknownChangedSourceAndMissingSourceNeverReportSuccessfulMove() async throws {
    let f = try Fixture()
    defer { f.cleanup() }
    let op = try f.operation([
      .move(
        source: "old.mp3", destination: "new.mp3",
        fingerprint: SharedLibraryOperation.fingerprint(Data("expected".utf8)))
    ])
    let missing = try await f.materializer().replay(op)
    XCTAssertEqual(missing, .waitingForFile("old.mp3"))
    try Data("external edit".utf8).write(to: f.root.appendingPathComponent("old.mp3"))
    do {
      _ = try await f.materializer().replay(op)
      XCTFail()
    } catch { XCTAssertEqual(error as? SharedLibraryOperationError, .contentChanged("old.mp3")) }
    XCTAssertFalse(
      FileManager.default.fileExists(atPath: f.root.appendingPathComponent("new.mp3").path))
  }
  func testStaleLogicalRevisionStopsBeforePhysicalChange() async throws {
    let f = try Fixture()
    defer { f.cleanup() }
    let bytes = Data("audio".utf8)
    try bytes.write(to: f.root.appendingPathComponent("old.mp3"))
    let op = try f.operation([
      .move(
        source: "old.mp3", destination: "new.mp3",
        fingerprint: SharedLibraryOperation.fingerprint(bytes))
    ])
    var auth = await f.authority.current()
    try auth.state.assign(field: "folderID", value: .text(UUID().uuidString), writer: f.writer)
    await f.authority.update(auth)
    let result = try await f.materializer().replay(op)
    XCTAssertEqual(result, .needsReplanning)
    XCTAssertEqual(try Data(contentsOf: f.root.appendingPathComponent("old.mp3")), bytes)
  }
  func testDeleteWaitsForExactAcknowledgmentAndTrashFailureDoesNotComplete() async throws {
    let f = try Fixture(deleted: true)
    defer { f.cleanup() }
    let bytes = Data("audio".utf8)
    try bytes.write(to: f.root.appendingPathComponent("old.mp3"))
    let op = try f.operation([
      .trash(path: "old.mp3", fingerprint: SharedLibraryOperation.fingerprint(bytes))
    ])
    let result = try await f.materializer().replay(op)
    XCTAssertEqual(result, .waitingForAcknowledgments)
    var auth = await f.authority.current()
    auth.acknowledgments = [
      .init(
        writer: f.writer, entity: f.entity.id, revision: try SharedStateFingerprint.of(f.state),
        cohort: auth.membership.fingerprint, purpose: .delete)
    ]
    await f.authority.update(auth)
    let failure = SharedLibraryMaterializer(
      root: f.root, receipts: f.receipts, authority: { await f.authority.current() },
      trash: { _ in throw CocoaError(.fileWriteNoPermission) })
    do {
      _ = try await failure.replay(op)
      XCTFail()
    } catch { XCTAssertEqual((error as NSError).code, CocoaError.fileWriteNoPermission.rawValue) }
    XCTAssertEqual(try Data(contentsOf: f.root.appendingPathComponent("old.mp3")), bytes)
  }
  func testFolderRemovalNeverRecursivelyDeletesUnknownFiles() async throws {
    let f = try Fixture()
    defer { f.cleanup() }
    let folder = f.root.appendingPathComponent("folder")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
    try Data("unknown".utf8).write(to: folder.appendingPathComponent(".hidden"))
    var auth = await f.authority.current()
    auth.pathOwners["folder"] = [f.entity.id]
    await f.authority.update(auth)
    let op = try f.operation([.removeEmptyDirectory(path: "folder")])
    let result = try await f.materializer().replay(op)
    XCTAssertEqual(result, .directoryNotEmpty("folder"))
    XCTAssertEqual(
      try Data(contentsOf: folder.appendingPathComponent(".hidden")), Data("unknown".utf8))
  }
  func testProjectionWriteResumesAfterCommitAndDoesNotRewriteIdenticalBytes() async throws {
    let f = try Fixture()
    defer { f.cleanup() }
    var auth = await f.authority.current()
    auth.pathOwners["new.transcript.json"] = [f.entity.id]
    await f.authority.update(auth)
    let bytes = Data("new generation".utf8)
    let op = try f.operation([
      .write(path: "new.transcript.json", expectedFingerprint: nil, bytes: bytes)
    ])
    do {
      _ = try await f.materializer(after: { _ in throw Interrupted.crash }).replay(op)
      XCTFail()
    } catch { XCTAssertTrue(error is Interrupted) }
    let url = f.root.appendingPathComponent("new.transcript.json")
    let modified = try url.resourceValues(forKeys: [.contentModificationDateKey])
      .contentModificationDate
    let result = try await f.materializer().replay(op)
    XCTAssertEqual(result, .complete)
    XCTAssertEqual(try Data(contentsOf: url), bytes)
    XCTAssertEqual(
      try url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate,
      modified)
  }
  func testReplacementWaitsForCohortButIdenticalFingerprintRepairDoesNot() async throws {
    for repair in [false, true] {
      let f = try Fixture()
      defer { f.cleanup() }
      let old = Data("old audio".utf8)
      let selected = Data("selected audio".utf8)
      try old.write(to: f.root.appendingPathComponent("old.mp3"))
      let hash = SharedLibraryOperation.fingerprint(selected)
      var auth = await f.authority.current()
      try auth.state.assign(field: "audioFingerprint", value: .text(hash), writer: f.writer)
      await f.authority.update(auth)
      let staged = try await f.materializer().stageNewAudio(selected, entity: f.entity)
      let op = try SharedLibraryOperation(
        libraryID: f.library, entity: f.entity, inputRevision: "old",
        outputRevision: SharedStateFingerprint.of(auth.state),
        steps: [
          .replaceAudio(
            path: "old.mp3", staged: staged,
            expectedFingerprint: SharedLibraryOperation.fingerprint(old), selectedFingerprint: hash,
            repair: repair)
        ], inputAudioFingerprint: repair ? hash : SharedLibraryOperation.fingerprint(old))
      if !repair {
        let pending = try await f.materializer().replay(op)
        XCTAssertEqual(pending, .waitingForAcknowledgments)
        XCTAssertEqual(try Data(contentsOf: f.root.appendingPathComponent("old.mp3")), old)
        auth.acknowledgments = [try auth.acknowledgment(by: f.writer, purpose: .replaceAudio)]
        await f.authority.update(auth)
      }
      let result = try await f.materializer().replay(op)
      XCTAssertEqual(result, .complete)
      XCTAssertEqual(try Data(contentsOf: f.root.appendingPathComponent("old.mp3")), selected)
      XCTAssertFalse(
        FileManager.default.fileExists(atPath: f.root.appendingPathComponent(staged).path))
      let media = LibraryFileDiscovery.files(in: f.root, suffix: ".mp3")
      XCTAssertEqual(media.map(\.logicalName), ["old.mp3"])
    }
  }
  func testFolderRenameProjectsOwnedChildrenAndLeavesUnknownFilesInOldFolder() async throws {
    let f = try Fixture()
    defer { f.cleanup() }
    let old = f.root.appendingPathComponent("oldFolder")
    try FileManager.default.createDirectory(at: old, withIntermediateDirectories: false)
    try Data("audio".utf8).write(to: old.appendingPathComponent("old.mp3"))
    try Data("unknown".utf8).write(to: old.appendingPathComponent("private.txt"))
    var auth = await f.authority.current()
    for path in ["oldFolder", "newFolder", "oldFolder/old.mp3", "newFolder/old.mp3"] {
      auth.pathOwners[path] = [f.entity.id]
    }
    await f.authority.update(auth)
    let op = try f.operation([
      .createDirectory(path: "newFolder"),
      .move(
        source: "oldFolder/old.mp3", destination: "newFolder/old.mp3",
        fingerprint: SharedLibraryOperation.fingerprint(Data("audio".utf8))),
      .removeEmptyDirectory(path: "oldFolder"),
    ])
    let result = try await f.materializer().replay(op)
    XCTAssertEqual(result, .directoryNotEmpty("oldFolder"))
    XCTAssertEqual(
      try Data(contentsOf: old.appendingPathComponent("private.txt")), Data("unknown".utf8))
    XCTAssertEqual(
      try Data(contentsOf: f.root.appendingPathComponent("newFolder/old.mp3")), Data("audio".utf8))
  }
  func testDurableAcknowledgmentAndWithdrawalInvalidateStaleProviderCopy() async throws {
    let f = try Fixture(deleted: true)
    defer { f.cleanup() }
    let store = SharedOperationAcknowledgmentStore(
      root: f.root, libraryID: f.library, writer: f.writer)
    let accepted = try await store.acknowledge(
      purpose: .delete, authority: { await f.authority.current() })
    let file = f.root.appendingPathComponent(
      ".docktape/acknowledgments/\(f.entity.id.uuidString)/\(f.writer.uuidString).json")
    try FileManager.default.copyItem(
      at: file, to: file.deletingLastPathComponent().appendingPathComponent("conflicted copy.json"))
    let restarted = SharedOperationAcknowledgmentStore(
      root: f.root, libraryID: f.library, writer: f.writer)
    let before = try await restarted.load(entity: f.entity.id)
    XCTAssertEqual(before, [accepted])
    try await restarted.withdraw(entity: f.entity.id)
    let after = try await restarted.load(entity: f.entity.id)
    XCTAssertEqual(after, [])
    var auth = await f.authority.current()
    auth.hasPendingWork = true
    await f.authority.update(auth)
    do {
      _ = try await store.acknowledge(purpose: .delete, authority: { await f.authority.current() })
      XCTFail()
    } catch { XCTAssertEqual(error as? SharedLibraryOperationError, .invalidOperation) }
  }

  func testOfflineWriterAndNewEnrollmentKeepDeletionPending() async throws {
    let f = try Fixture(deleted: true)
    defer { f.cleanup() }
    var auth = await f.authority.current()
    let peer = UUID()
    try auth.membership.requestJoin(.init(writer: peer, label: "second Mac"))
    let proposal = try auth.membership.proposal(checkpoint: "acquired")
    let votes = [f.writer, peer].map {
      SharedMembershipVote(writer: $0, proposal: proposal.fingerprint, checkpoint: "acquired")
    }
    try auth.membership.accept(auth.membership.certify(proposal, votes: votes))
    auth.acknowledgments = [try auth.acknowledgment(by: f.writer, purpose: .delete)]
    XCTAssertFalse(auth.mayDestroy(.delete))
    auth.acknowledgments.append(try auth.acknowledgment(by: peer, purpose: .delete))
    XCTAssertTrue(auth.mayDestroy(.delete))
    try auth.membership.requestJoin(.init(writer: UUID(), label: "newly joining Mac"))
    XCTAssertFalse(auth.mayDestroy(.delete))
    XCTAssertThrowsError(try auth.acknowledgment(by: f.writer, purpose: .delete))
  }
  func testChangedLifecycleRevisionOrPendingOldJobRevokesDestructivePermission() async throws {
    let f = try Fixture(deleted: true)
    defer { f.cleanup() }
    var auth = await f.authority.current()
    auth.acknowledgments = [try auth.acknowledgment(by: f.writer, purpose: .delete)]
    XCTAssertTrue(auth.mayDestroy(.delete))
    auth.hasPendingWork = true
    XCTAssertFalse(auth.mayDestroy(.delete))
    XCTAssertThrowsError(try auth.acknowledgment(by: f.writer, purpose: .delete))
    auth.hasPendingWork = false
    try auth.state.restore(writer: f.writer)
    try auth.state.delete(writer: f.writer)
    XCTAssertFalse(auth.mayDestroy(.delete))
    var offlineEdit = f.state
    try offlineEdit.restore(writer: UUID())
    auth.state = try auth.state.merged(with: offlineEdit)
    XCTAssertEqual(auth.state.lifecycle, .conflicted)
    XCTAssertFalse(auth.mayDestroy(.delete))
  }
  func testReceiptCorruptionIsReportedAndAcceptedFilesystemBytesRemainUntouched() async throws {
    let f = try Fixture()
    defer { f.cleanup() }
    let bytes = Data("audio".utf8)
    try bytes.write(to: f.root.appendingPathComponent("old.mp3"))
    let op = try f.operation([
      .move(
        source: "old.mp3", destination: "new.mp3",
        fingerprint: SharedLibraryOperation.fingerprint(bytes))
    ])
    do { _ = try await f.materializer(after: { _ in throw Interrupted.crash }).replay(op) } catch {}
    let receipt = f.receipts.appendingPathComponent(f.entity.id.uuidString + ".json")
    var envelope = try XCTUnwrap(
      JSONSerialization.jsonObject(with: Data(contentsOf: receipt)) as? [String: Any])
    envelope["checksum"] = String(repeating: "0", count: 64)
    let corrupted = try JSONSerialization.data(withJSONObject: envelope, options: [.sortedKeys])
    try corrupted.write(to: receipt)
    do {
      _ = try await f.materializer().replay(op)
      XCTFail()
    } catch { XCTAssertEqual(error as? SharedLibraryOperationError, .invalidReceipt) }
    XCTAssertEqual(try Data(contentsOf: receipt), corrupted)
    XCTAssertEqual(try Data(contentsOf: f.root.appendingPathComponent("new.mp3")), bytes)
  }
  func testTwoMaterializersObserveAlreadyCommittedReceiptWithoutRepeatingMutation() async throws {
    let f = try Fixture()
    defer { f.cleanup() }
    let bytes = Data("audio".utf8)
    try bytes.write(to: f.root.appendingPathComponent("old.mp3"))
    let op = try f.operation([
      .move(
        source: "old.mp3", destination: "new.mp3",
        fingerprint: SharedLibraryOperation.fingerprint(bytes))
    ])
    let changed = expectation(description: "Exactly one coordinated mutation")
    changed.expectedFulfillmentCount = 1
    changed.assertForOverFulfill = true
    async let a = f.materializer(after: { _ in changed.fulfill() }).replay(op)
    async let b = f.materializer(after: { _ in changed.fulfill() }).replay(op)
    let results = try await [a, b]
    XCTAssertEqual(results, [.complete, .complete])
    await fulfillment(of: [changed], timeout: 1)
    XCTAssertEqual(try Data(contentsOf: f.root.appendingPathComponent("new.mp3")), bytes)
  }
  func testTrashSuccessAndCrashBeforeReceiptHaveDistinctOutcomes() async throws {
    for interrupted in [false, true] {
      let f = try Fixture(deleted: true)
      defer { f.cleanup() }
      let bytes = Data("audio".utf8)
      try bytes.write(to: f.root.appendingPathComponent("old.mp3"))
      var auth = await f.authority.current()
      auth.acknowledgments = [try auth.acknowledgment(by: f.writer, purpose: .delete)]
      await f.authority.update(auth)
      let op = try f.operation([
        .trash(path: "old.mp3", fingerprint: SharedLibraryOperation.fingerprint(bytes))
      ])
      let trash = f.root.deletingLastPathComponent().appendingPathComponent("test-Trash.mp3")
      let materializer = SharedLibraryMaterializer(
        root: f.root, receipts: f.receipts,
        authority: { await f.authority.current() },
        trash: { try FileManager.default.moveItem(at: $0, to: trash) },
        afterMutation: { _ in if interrupted { throw Interrupted.crash } })
      do {
        let result = try await materializer.replay(op)
        XCTAssertFalse(interrupted)
        XCTAssertEqual(result, .complete)
      } catch {
        XCTAssertTrue(interrupted)
        XCTAssertTrue(error is Interrupted)
      }
      XCTAssertEqual(try Data(contentsOf: trash), bytes)
      let next = try await materializer.replay(op)
      XCTAssertEqual(next, interrupted ? .waitingForFile("old.mp3") : .complete)
    }
  }
  func testMissingRootAndSymlinkEscapeNeverCreateAReplacementLibrary() async throws {
    let f = try Fixture()
    defer { f.cleanup() }
    let bytes = Data("audio".utf8)
    let external = f.root.deletingLastPathComponent().appendingPathComponent("external.mp3")
    try bytes.write(to: external)
    try FileManager.default.createSymbolicLink(
      at: f.root.appendingPathComponent("old.mp3"), withDestinationURL: external)
    let op = try f.operation([
      .move(
        source: "old.mp3", destination: "new.mp3",
        fingerprint: SharedLibraryOperation.fingerprint(bytes))
    ])
    do {
      _ = try await f.materializer().replay(op)
      XCTFail()
    } catch { XCTAssertEqual(error as? SharedLibraryOperationError, .unsafePath) }
    XCTAssertEqual(try Data(contentsOf: external), bytes)
    try FileManager.default.removeItem(at: f.root)
    do {
      _ = try await f.materializer().replay(op)
      XCTFail()
    } catch { XCTAssertEqual(error as? SharedLibraryOperationError, .unavailableRoot) }
    XCTAssertFalse(FileManager.default.fileExists(atPath: f.root.path))
  }

  func testProviderCleanupRequiresAcceptedAdoptionAndCompletedCanonicalProjection() async throws {
    let f = try Fixture()
    defer { f.cleanup() }
    let bytes = Data("{\"text\":\"adopted\"}".utf8)
    let document = try SharedDocument(id: UUID(), json: bytes)
    let fingerprint = try SharedStateFingerprint.of(bytes)
    let canonical = f.root.appendingPathComponent("new.transcript.json")
    let candidate = SharedExternalContent(
      libraryID: f.library, versionID: "selected-version", id: UUID(),
      entity: f.entity, component: .transcript, url: canonical, fingerprint: fingerprint,
      document: document)
    var auth = await f.authority.current()
    try auth.state.assignGeneration(document, component: .transcript, writer: f.writer)
    try auth.state.assign(
      field: "externalAdoption.transcript", value: .text(fingerprint), writer: f.writer)
    auth.pathOwners["new.transcript.json"] = [f.entity.id]
    await f.authority.update(auth)
    let op = try SharedLibraryOperation(
      libraryID: f.library, entity: f.entity, inputRevision: "previous",
      outputRevision: SharedStateFingerprint.of(auth.state),
      steps: [
        .write(path: "new.transcript.json", expectedFingerprint: nil, bytes: bytes)
      ])
    let removed = expectation(description: "Only reviewed version removed")
    let versions = RecordingFileVersionAccess(
      lookup: { _ in [] }, read: { _ in bytes },
      remove: { url, id, source, current in
        XCTAssertEqual(url, canonical)
        XCTAssertEqual(id, "selected-version")
        XCTAssertEqual(source, fingerprint)
        XCTAssertEqual(current, SharedLibraryOperation.fingerprint(bytes))
        removed.fulfill()
      })
    let materializer = f.materializer()
    do {
      try await materializer.cleanupReviewedVersion(
        candidate, operation: op, canonicalPath: "new.transcript.json", versions: versions)
      XCTFail()
    } catch { XCTAssertEqual(error as? SharedLibraryOperationError, .unfinishedOperation) }
    let result = try await materializer.replay(op)
    XCTAssertEqual(result, .complete)
    try await materializer.cleanupReviewedVersion(
      candidate, operation: op, canonicalPath: "new.transcript.json", versions: versions)
    await fulfillment(of: [removed], timeout: 1)
    try Data("external changed current".utf8).write(to: canonical)
    do {
      try await materializer.cleanupReviewedVersion(
        candidate, operation: op, canonicalPath: "new.transcript.json", versions: versions)
      XCTFail()
    } catch {
      XCTAssertEqual(error as? SharedLibraryOperationError, .contentChanged("new.transcript.json"))
    }
  }

  func testIndependentEditCanReplanPartialMoveWithoutLosingAudioOrCompanion() async throws {
    let f = try Fixture()
    defer { f.cleanup() }
    let audio = Data("audio".utf8)
    let transcript = Data("transcript".utf8)
    try audio.write(to: f.root.appendingPathComponent("old.mp3"))
    try transcript.write(to: f.root.appendingPathComponent("old.transcript.json"))
    var auth = await f.authority.current()
    for path in ["old.transcript.json", "new.transcript.json"] {
      auth.pathOwners[path] = [f.entity.id]
    }
    await f.authority.update(auth)
    let first = try f.operation([
      .move(
        source: "old.mp3", destination: "new.mp3",
        fingerprint: SharedLibraryOperation.fingerprint(audio)),
      .move(
        source: "old.transcript.json", destination: "new.transcript.json",
        fingerprint: SharedLibraryOperation.fingerprint(transcript)),
    ])
    let materializer = f.materializer()
    do { _ = try await f.materializer(after: { _ in throw Interrupted.crash }).replay(first) } catch
    {}
    let progress = try await materializer.progress(entity: f.entity, libraryID: f.library)
    XCTAssertEqual(progress?.completedSteps, 0)
    XCTAssertEqual(progress?.phaseWasAttempted, true)
    try auth.state.assign(field: "notes", value: .text("independent edit"), writer: f.writer)
    await f.authority.update(auth)
    let stale = try await materializer.replay(first)
    XCTAssertEqual(stale, .needsReplanning)
    let replacement = try SharedLibraryOperation(
      libraryID: f.library, entity: f.entity,
      inputRevision: first.outputRevision, outputRevision: SharedStateFingerprint.of(auth.state),
      steps: first.steps)
    try await materializer.replan(replacement, replacing: first.id)
    let result = try await materializer.replay(replacement)
    XCTAssertEqual(result, .complete)
    XCTAssertEqual(try Data(contentsOf: f.root.appendingPathComponent("new.mp3")), audio)
    XCTAssertEqual(
      try Data(contentsOf: f.root.appendingPathComponent("new.transcript.json")), transcript)
    let finalAuthority = await f.authority.current()
    XCTAssertEqual(finalAuthority.state.value(for: "notes"), .text("independent edit"))
  }

  func testRevisionChangeWhileWaitingForFileLeaseRevokesTrash() async throws {
    let f = try Fixture(deleted: true)
    defer { f.cleanup() }
    let file = f.root.appendingPathComponent("old.mp3")
    let bytes = Data("audio".utf8)
    try bytes.write(to: file)
    var auth = await f.authority.current()
    auth.acknowledgments = [try auth.acknowledgment(by: f.writer, purpose: .delete)]
    await f.authority.update(auth)
    let op = try f.operation([
      .trash(path: "old.mp3", fingerprint: SharedLibraryOperation.fingerprint(bytes))
    ])
    let acquired = expectation(description: "Source held by other local request")
    let requested = expectation(description: "Materializer waiting for its source lease")
    let release = DispatchSemaphore(value: 0)
    let holder = Task {
      try await CoordinatedFileAccess().withWrite(at: file) { _ in
        acquired.fulfill()
        guard release.wait(timeout: .now() + 3) == .success else { throw Interrupted.crash }
      }
    }
    await fulfillment(of: [acquired], timeout: 1)
    actor Reads {
      var count = 0
      func next() -> Int {
        count += 1
        return count
      }
    }
    let reads = Reads()
    let runner = SharedLibraryMaterializer(
      root: f.root, receipts: f.receipts,
      authority: {
        let current = await f.authority.current()
        if await reads.next() == 3 { requested.fulfill() }
        return current
      }, trash: { _ in XCTFail("A revoked operation cannot remove audio") })
    let task = Task { try await runner.replay(op) }
    await fulfillment(of: [requested], timeout: 1)
    var changed = await f.authority.current()
    try changed.state.restore(writer: f.writer)
    await f.authority.update(changed)
    release.signal()
    try await holder.value
    let result = try await task.value
    XCTAssertEqual(result, .needsReplanning)
    XCTAssertEqual(try Data(contentsOf: file), bytes)
  }

  func testStagedCancellationRejectsSelectedOrChangedInputAndLeavesNoBackup() async throws {
    let f = try Fixture()
    defer { f.cleanup() }
    let bytes = Data("new input".utf8)
    let hash = SharedLibraryOperation.fingerprint(bytes)
    let materializer = f.materializer()
    let staged = try await materializer.stageNewAudio(bytes, entity: f.entity)
    var auth = await f.authority.current()
    try auth.state.assign(field: "audioFingerprint", value: .text(hash), writer: f.writer)
    await f.authority.update(auth)
    do {
      try await materializer.discardStagedAudio(staged, entity: f.entity, fingerprint: hash)
      XCTFail()
    } catch { XCTAssertEqual(error as? SharedLibraryOperationError, .invalidOperation) }
    XCTAssertEqual(try Data(contentsOf: f.root.appendingPathComponent(staged)), bytes)
    try auth.state.assign(
      field: "audioFingerprint",
      value: .text(SharedLibraryOperation.fingerprint(Data("other selected".utf8))),
      writer: f.writer)
    await f.authority.update(auth)
    try Data("externally changed staging".utf8).write(to: f.root.appendingPathComponent(staged))
    do {
      try await materializer.discardStagedAudio(staged, entity: f.entity, fingerprint: hash)
      XCTFail()
    } catch {
      XCTAssertEqual(error as? SharedLibraryOperationError, .contentChanged("staged audio"))
    }
    try bytes.write(to: f.root.appendingPathComponent(staged))
    try await materializer.discardStagedAudio(staged, entity: f.entity, fingerprint: hash)
    XCTAssertFalse(
      FileManager.default.fileExists(atPath: f.root.appendingPathComponent(staged).path))
  }
  func testInterruptedReplacementReplaysWithoutAnotherAudioCopy() async throws {
    let f = try Fixture()
    defer { f.cleanup() }
    let old = Data("old".utf8)
    let bytes = Data("new".utf8)
    try old.write(to: f.root.appendingPathComponent("old.mp3"))
    let hash = SharedLibraryOperation.fingerprint(bytes)
    var auth = await f.authority.current()
    try auth.state.assign(field: "audioFingerprint", value: .text(hash), writer: f.writer)
    auth.acknowledgments = [try auth.acknowledgment(by: f.writer, purpose: .replaceAudio)]
    await f.authority.update(auth)
    let staged = try await f.materializer().stageNewAudio(bytes, entity: f.entity)
    let op = try SharedLibraryOperation(
      libraryID: f.library, entity: f.entity, inputRevision: "old",
      outputRevision: SharedStateFingerprint.of(auth.state),
      steps: [
        .replaceAudio(
          path: "old.mp3", staged: staged,
          expectedFingerprint: SharedLibraryOperation.fingerprint(old), selectedFingerprint: hash,
          repair: false)
      ])
    do {
      _ = try await f.materializer(after: { _ in throw Interrupted.crash }).replay(op)
      XCTFail()
    } catch { XCTAssertTrue(error is Interrupted) }
    let result = try await f.materializer().replay(op)
    XCTAssertEqual(result, .complete)
    XCTAssertEqual(try Data(contentsOf: f.root.appendingPathComponent("old.mp3")), bytes)
    XCTAssertFalse(
      FileManager.default.fileExists(atPath: f.root.appendingPathComponent(staged).path))
  }

  func testProjectionWriteCannotBypassAudioReplacementAcknowledgments() throws {
    let f = try Fixture()
    defer { f.cleanup() }
    XCTAssertThrowsError(
      try f.operation([
        .write(path: "old.mp3", expectedFingerprint: nil, bytes: Data("replacement".utf8))
      ]))
    XCTAssertThrowsError(
      try f.operation([
        .move(
          source: "old.transcript.json", destination: "new.mp3",
          fingerprint: SharedLibraryOperation.fingerprint(Data("replacement".utf8)))
      ]))
  }

  func testNewAudioPublicationNeedsNoDestructiveVoteAndNeverOverwritesDifferentBytes() async throws
  {
    let f = try Fixture()
    defer { f.cleanup() }
    let bytes = Data("new recording".utf8)
    let hash = SharedLibraryOperation.fingerprint(bytes)
    var auth = await f.authority.current()
    try auth.state.assign(field: "audioFingerprint", value: .text(hash), writer: f.writer)
    let peer = UUID()
    try auth.membership.requestJoin(.init(writer: peer, label: "second Mac"))
    let proposal = try auth.membership.proposal(checkpoint: "acquired")
    try auth.membership.accept(
      auth.membership.certify(
        proposal,
        votes: [f.writer, peer].map {
          .init(writer: $0, proposal: proposal.fingerprint, checkpoint: "acquired")
        }))
    await f.authority.update(auth)
    let staged = try await f.materializer().stageNewAudio(bytes, entity: f.entity)
    let op = try SharedLibraryOperation(
      libraryID: f.library, entity: f.entity, inputRevision: "new import",
      outputRevision: SharedStateFingerprint.of(auth.state),
      steps: [
        .publishAudio(path: "new.mp3", staged: staged, selectedFingerprint: hash)
      ])
    try Data("untracked existing audio".utf8).write(to: f.root.appendingPathComponent("new.mp3"))
    do {
      _ = try await f.materializer().replay(op)
      XCTFail()
    } catch { XCTAssertEqual(error as? SharedLibraryOperationError, .contentChanged("new.mp3")) }
    XCTAssertEqual(
      try Data(contentsOf: f.root.appendingPathComponent("new.mp3")),
      Data("untracked existing audio".utf8))
    try FileManager.default.removeItem(at: f.root.appendingPathComponent("new.mp3"))
    let result = try await f.materializer().replay(op)
    XCTAssertEqual(result, .complete)
    XCTAssertEqual(try Data(contentsOf: f.root.appendingPathComponent("new.mp3")), bytes)
    XCTAssertFalse(
      FileManager.default.fileExists(atPath: f.root.appendingPathComponent(staged).path))
  }

}
