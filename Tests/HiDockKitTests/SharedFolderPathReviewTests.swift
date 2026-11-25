// © 2026 High Gain Design. All rights reserved.
import XCTest
@testable import HiDockKit

final class SharedFolderPathReviewTests: XCTestCase {
    private var roots: [URL] = []
    override func tearDown() { for root in roots { try? FileManager.default.removeItem(at: root) } }
    private struct Fixture {
        let root: URL
        let coordinator: SharedLibraryCoordinator
        let folder: SharedEntityIdentity
        let target: SharedEntityIdentity
        let other: SharedEntityIdentity
    }
    private func fixture(physical: Bool = false, stage: String = "unstarted", peerName: String = "Peer", targetName: String = "Target", otherName: String = "Other", parentBase: URL? = nil) async throws -> Fixture {
        let parent = (parentBase ?? FileManager.default.temporaryDirectory).appendingPathComponent(UUID().uuidString)
        roots.append(parent)
        let left = parent.appendingPathComponent("left"), right = parent.appendingPathComponent("right")
        for name in ["Folder/Nested", targetName, otherName] + (parentBase == nil ? [] : [otherName + "/Peer"]) {
            try FileManager.default.createDirectory(at: left.appendingPathComponent(name), withIntermediateDirectories: true)
        }
        for path in ["Folder/A.mp3", "Folder/Nested/B.mp3", "Folder/.notes", "Unrelated.mp3"] {
            try Data(path.utf8).write(to: left.appendingPathComponent(path))
        }
        try await TranscriptStore(baseDirectory: left).save(Transcript(recordingFilename: "Folder/A.mp3", transcriptionModel: "fixture", hasSpeakerLabels: false,
            segments: [.init(startTime: 0, endTime: 1, text: "Retained words")]), mp3Filename: "Folder/A.mp3")
        let writer = UUID(), witness = parent.appendingPathComponent("a-local")
        let a = SharedLibraryCoordinator(root: left, writerID: writer, witnessDirectory: witness)
        _ = try await a.enable(); _ = try await a.projectOutputs()
        let folders = try await a.snapshots(kinds: [.folder])
        func entity(_ name: String) throws -> SharedEntityIdentity {
            .init(id: try XCTUnwrap(folders.first { $0.state.value(for: "name") == .text(name) }).state.id, kind: .folder)
        }
        let folder = try entity("Folder"), target = try entity(targetName), other = try entity(otherName)
        try FileManager.default.copyItem(at: left, to: right)
        let b = SharedLibraryCoordinator(root: right, writerID: UUID(), witnessDirectory: parent.appendingPathComponent("b-local"),
            afterCommit: { if physical { withUnsafeCurrentTask { $0?.cancel() } } })
        try await b.requestEnrollment(requestID: UUID(), label: "Folder peer")
        for _ in 0..<3 {
            try deliver(right, to: left, writer: b.writerID); try await a.refresh()
            try deliver(left, to: right, writer: a.writerID); try await b.refresh()
        }
        if physical {
            let interrupted = SharedLibraryCoordinator(root: left, writerID: writer, witnessDirectory: witness,
                afterCommit: { if stage == "unstarted" { withUnsafeCurrentTask { $0?.cancel() } } })
            for coordinator in [interrupted, b] {
                do {
                    _ = try await Task { try await coordinator.renameFolder(from: "Folder", to: coordinator.writerID == writer ? "Local" : "Peer", afterMutation: { _ in
                        if coordinator.writerID == writer && stage == "attempted" { throw CancellationError() }
                    }) }.value
                    XCTAssertTrue(coordinator.writerID == writer && stage == "published", "Expected committed interruption")
                }
                catch is CancellationError { }
            }
            do { _ = try await Task { try await b.edit(.init(base: try await b.read(folder), changes: [.assign(field: "parent", value: .text(target.id.uuidString)), .assign(field: "name", value: .text(peerName))])) }.value }
            catch is CancellationError { }
        } else {
            _ = try await a.edit(.init(base: try await a.read(folder), changes: [.assign(field: "name", value: .text("Local")), .assign(field: "parent", value: .text(other.id.uuidString))]))
            _ = try await b.edit(.init(base: try await b.read(folder), changes: [.assign(field: "name", value: .text("Peer")), .assign(field: "parent", value: .text(target.id.uuidString))]))
        }
        try deliver(right, to: left, writer: b.writerID)
        return Fixture(root: left, coordinator: a, folder: folder, target: target, other: other)
    }
    private func choice(_ fixture: Fixture) async throws -> SharedFolderPathReview {
        let choices = try await fixture.coordinator.folderPathChoices(fixture.coordinator.read(fixture.folder))
        return try XCTUnwrap(choices.first { $0.destination == "Target/Peer" })
    }
    private func prepared(_ fixture: Fixture) async throws -> SharedFolderReplanReview {
        _ = try await fixture.coordinator.resolveFolderPath(choice(fixture))
        let value = try await fixture.coordinator.reviewFolderOperation(id: fixture.folder.id)
        let review = try XCTUnwrap(value)
        XCTAssertTrue(review.canReplan)
        return try await fixture.coordinator.prepareFolderReplan(review)
    }
    func testFolderChoiceRefusesParentLifecycleABA() async throws {
        let f = try await fixture(), a = f.coordinator, selected = try await choice(f)
        _ = try await a.edit(.init(base: try await a.read(f.target), changes: [.delete]))
        _ = try await a.resolve(.init(base: try await a.read(f.target), changes: [.restore]))
        do { _ = try await a.resolveFolderPath(selected); XCTFail("Parent lifecycle changed after review") }
        catch SharedLibraryCoordinatorError.staleReview { }
        let fresh = try await choice(f)
        XCTAssertNotEqual(fresh.contextFingerprint, selected.contextFingerprint)
        XCTAssertEqual(try Data(contentsOf: f.root.appendingPathComponent("Folder/A.mp3")), Data("Folder/A.mp3".utf8))
    }
    private actor Once {
        var available = true
        func take() -> Bool { defer { available = false }; return available }
    }
    func testFolderChoiceRefusesParentChangedDuringAuthorityAcquisition() async throws {
        let f = try await fixture(), a = f.coordinator, selected = try await choice(f), once = Once()
        let raced = SharedLibraryCoordinator(root: f.root, writerID: a.writerID,
            witnessDirectory: f.root.deletingLastPathComponent().appendingPathComponent("a-local"), afterPublishedLibraryRead: {
                if await once.take() { _ = try await a.edit(.init(base: try await a.read(f.target), changes: [.assign(field: "name", value: .text("Shifted"))])) }
            })
        do { _ = try await raced.resolveFolderPath(selected); XCTFail("Acquired authority cannot bless the old path") }
        catch SharedLibraryCoordinatorError.staleReview { }
        let retained = try await a.read(f.folder)
        XCTAssertTrue(retained.state.fields["name"]?.isConflicted == true)
    }
    func testFolderChoicesRejectAmbiguousAndCyclicParents() async throws {
        let f = try await fixture(), a = f.coordinator
        _ = try await a.edit(.init(base: try await a.read(f.other), changes: [.assign(field: "name", value: .text("Target"))]))
        let ambiguous = try await a.folderPathChoices(a.read(f.folder))
        XCTAssertTrue(ambiguous.isEmpty)
        _ = try await a.edit(.init(base: try await a.read(f.other), changes: [.assign(field: "name", value: .text("Other"))]))
        _ = try await a.edit(.init(base: try await a.read(f.target), changes: [.assign(field: "parent", value: .text(f.folder.id.uuidString))]))
        do {
            let cyclic = try await a.folderPathChoices(a.read(f.folder))
            XCTAssertFalse(cyclic.contains { $0.values["parent"] == .text(f.target.id.uuidString) })
        } catch SharedLibraryPathError.invalidGraph { }
    }
    func testFolderChoiceRejectsCopiedRootAndPreservesUnrelatedEdit() async throws {
        let f = try await fixture(), a = f.coordinator, selected = try await choice(f)
        let copied = SharedLibraryCoordinator(root: f.root.deletingLastPathComponent().appendingPathComponent("right"), writerID: UUID())
        do { _ = try await copied.resolveFolderPath(selected); XCTFail("Review belongs to a different physical root") }
        catch SharedLibraryCoordinatorError.differentBinding { }
        let unrelated = try await a.recording(at: "Unrelated.mp3")
        _ = try await a.edit(.init(base: unrelated, changes: [.assign(field: "metadata.mode", value: .text("\"Mee\""))]))
        _ = try await a.resolveFolderPath(selected)
        let retained = try await a.read(.init(id: unrelated.state.id, kind: .recording))
        XCTAssertEqual(retained.state.value(for: "metadata.mode"), .text("\"Mee\""))
        XCTAssertTrue(FileManager.default.fileExists(atPath: f.root.appendingPathComponent("Folder/A.mp3").path))
    }
    func testUpdatedFolderPlanRefusesChangedOrdinaryFileAndCannotRenewItsHash() async throws {
        let f = try await fixture(physical: true), plan = try await prepared(f), file = f.root.appendingPathComponent("Folder/.notes")
        let replacement = Data("external edited notes".utf8)
        try replacement.write(to: file, options: .atomic)
        do { _ = try await f.coordinator.applyFolderReplan(plan); XCTFail("Reviewed inventory must remain exact") } catch { }
        let value = try await f.coordinator.reviewFolderOperation(id: f.folder.id), review = try XCTUnwrap(value)
        do { _ = try await f.coordinator.prepareFolderReplan(review); XCTFail("New preview cannot bless arbitrary changed original") } catch { }
        XCTAssertEqual(try Data(contentsOf: file), replacement)
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.root.appendingPathComponent("Target/Peer").path))
    }
    func testUpdatedFolderPlanRefusesLateAliasAndChangedChild() async throws {
        for scenario in ["alias", "child"] {
            let f = try await fixture(physical: true), plan = try await prepared(f), a = f.coordinator
            do {
                _ = try await a.applyFolderReplan(plan, beforeCommit: {
                    if scenario == "alias" {
                        try FileManager.default.createDirectory(at: f.root.appendingPathComponent("Local"), withIntermediateDirectories: true)
                        try Data("late alias".utf8).write(to: f.root.appendingPathComponent("Local/Unknown.txt"))
                    } else {
                        let child = try await a.read(.init(id: a.reference(to: "Target/Peer/A.mp3").entityID, kind: .recording))
                        _ = try await a.edit(.init(base: child, changes: [.assign(field: "title", value: .text("Changed"))]))
                    }
                }); XCTFail("Late source graph change invalidates old preview")
            } catch { }
            XCTAssertEqual(try Data(contentsOf: f.root.appendingPathComponent("Folder/A.mp3")), Data("Folder/A.mp3".utf8))
            XCTAssertFalse(FileManager.default.fileExists(atPath: f.root.appendingPathComponent("Target/Peer").path))
        }
    }
    func testAcquiredFolderPermissionRechecksRetainedAliasesAtMutation() async throws {
        let f = try await fixture(physical: true), plan = try await prepared(f), a = f.coordinator
        let stopped = SharedLibraryCoordinator(root: f.root, writerID: a.writerID,
            witnessDirectory: f.root.deletingLastPathComponent().appendingPathComponent("a-local"),
            afterCommit: { withUnsafeCurrentTask { $0?.cancel() } })
        do { _ = try await Task { try await stopped.applyFolderReplan(plan) }.value; XCTFail("Expected interruption before receipt replacement") }
        catch is CancellationError { }
        let permission = try await a.operationAuthority(entity: f.folder, paths: [])
        XCTAssertTrue(permission.directoryScopeMatches)
        XCTAssertTrue(try permission.validateLocalCommit())
        try FileManager.default.createDirectory(at: f.root.appendingPathComponent("Local"), withIntermediateDirectories: true)
        try Data("late provider alias".utf8).write(to: f.root.appendingPathComponent("Local/Unknown.txt"))
        XCTAssertFalse(try permission.validateLocalCommit(), "A directory arriving after authority acquisition vetoes the physical commit")
        let currentPermission = try await a.operationAuthority(entity: f.folder, paths: [])
        XCTAssertFalse(currentPermission.directoryScopeMatches)
        let result = try await a.resumeFolderOperation(id: f.folder.id)
        XCTAssertEqual(result.result, .needsReplanning)
        let value = try await a.reviewFolderOperation(id: f.folder.id)
        XCTAssertNotNil(value)
        XCTAssertEqual(try Data(contentsOf: f.root.appendingPathComponent("Local/Unknown.txt")), Data("late provider alias".utf8))
        XCTAssertTrue(FileManager.default.fileExists(atPath: f.root.appendingPathComponent("Folder/A.mp3").path))
    }
    func testChoosingAlreadyMovedDirectoryPreservesOriginalReceipt() async throws {
        for stage in ["attempted", "published"] {
            let f = try await fixture(physical: true, stage: stage), a = f.coordinator
            _ = try await a.resolve(.init(base: try await a.read(f.folder), changes: [.assign(field: "parent", value: .unset)]))
            let choices = try await a.folderPathChoices(a.read(f.folder))
            let selected = try XCTUnwrap(choices.first { $0.destination == "Local" })
            _ = try await a.resolveFolderPath(selected)
            let value = try await a.reviewFolderOperation(id: f.folder.id), review = try XCTUnwrap(value)
            let plan = try await a.prepareFolderReplan(review)
            XCTAssertTrue(plan.reusesOperation)
            XCTAssertEqual(plan.source, "Local"); XCTAssertEqual(plan.destination, "Local")
            let original = try XCTUnwrap(plan.localOperation)
            let outcome = try await a.applyFolderReplan(plan)
            XCTAssertEqual(outcome.result, .complete)
            XCTAssertNil(outcome.projectionError)
            let materializer = SharedLibraryMaterializer(root: f.root,
                receipts: f.root.deletingLastPathComponent().appendingPathComponent("a-local/Operations/" + review.base.libraryID.uuidString + "/" + a.writerID.uuidString),
                authority: { try await a.operationAuthority(entity: f.folder, paths: []) })
            // Reused recipes retain their original input, step and identity;
            // only their current accepted output authority may be refreshed.
            let progress = try await materializer.progress(entity: f.folder, libraryID: review.base.libraryID)
            if let progress {
                XCTAssertEqual(progress.operation.id, original.id)
                XCTAssertEqual(progress.operation.steps, original.steps)
                XCTAssertEqual(progress.operation.inputRevision, original.inputRevision)
                XCTAssertEqual(progress.completedSteps, original.steps.count)
            } else { XCTFail("The original local receipt must survive no-op recovery") }
            XCTAssertEqual(try Data(contentsOf: f.root.appendingPathComponent("Local/A.mp3")), Data("Folder/A.mp3".utf8))
            XCTAssertFalse(FileManager.default.fileExists(atPath: f.root.appendingPathComponent("Folder").path))
        }
    }
    func testUpdatedFolderPlanRefusesCorruptCompanionsAudioAndUnknownFiles() async throws {
        for scenario in ["canonical", "derived", "audio", "extra"] {
            let f = try await fixture(physical: true), plan = try await prepared(f), a = f.coordinator
            let path = scenario == "canonical" ? "Folder/A.transcript.json" : scenario == "derived" ? "Folder/A.transcript.md" : scenario == "audio" ? "Folder/A.mp3" : "Folder/Unknown.txt"
            let file = f.root.appendingPathComponent(path)
            let damaged: Data
            if scenario == "canonical" {
                let original = try String(contentsOf: file, encoding: .utf8)
                damaged = Data(original.replacingOccurrences(of: "Retained words", with: "Unreviewed external words").utf8)
            } else { damaged = Data(("unreviewed " + scenario).utf8) }
            try damaged.write(to: file, options: .atomic)
            do { _ = try await a.applyFolderReplan(plan); XCTFail("Stale directory inventory must refuse \(scenario)") } catch { }
            let value = try await a.reviewFolderOperation(id: f.folder.id), fresh = try XCTUnwrap(value)
            do { _ = try await a.prepareFolderReplan(fresh); XCTFail("Preview cannot renew unregistered \(scenario) bytes") } catch { }
            XCTAssertEqual(try Data(contentsOf: file), damaged)
            XCTAssertEqual(try Data(contentsOf: f.root.appendingPathComponent("Folder/Nested/B.mp3")), Data("Folder/Nested/B.mp3".utf8))
            XCTAssertFalse(FileManager.default.fileExists(atPath: f.root.appendingPathComponent("Target/Peer").path))
        }
    }
    func testUpdatedFolderPlanRefusesCohortChange() async throws {
        let f = try await fixture(physical: true), plan = try await prepared(f), a = f.coordinator
        let right = f.root.deletingLastPathComponent().appendingPathComponent("right")
        let newcomer = SharedLibraryCoordinator(root: right, writerID: UUID(), witnessDirectory: right.deletingLastPathComponent().appendingPathComponent("c-local"))
        try await newcomer.requestEnrollment(requestID: UUID(), label: "New Mac")
        try deliver(right, to: f.root, writer: newcomer.writerID)
        do { _ = try await a.applyFolderReplan(plan); XCTFail("A changed participant set invalidates existing physical consent") } catch { }
        XCTAssertEqual(try Data(contentsOf: f.root.appendingPathComponent("Folder/A.mp3")), Data("Folder/A.mp3".utf8))
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.root.appendingPathComponent("Target/Peer").path))
    }
    func testUpdatedFolderPlanAllowsChoosingOriginalSourceWithoutMovingIt() async throws {
        let f = try await fixture(physical: true, peerName: "Folder"), a = f.coordinator
        _ = try await a.resolve(.init(base: try await a.read(f.folder), changes: [.assign(field: "parent", value: .unset)]))
        let choices = try await a.folderPathChoices(a.read(f.folder))
        let selected = try XCTUnwrap(choices.first { $0.destination == "Folder" })
        _ = try await a.resolveFolderPath(selected)
        let value = try await a.reviewFolderOperation(id: f.folder.id), review = try XCTUnwrap(value)
        let plan = try await a.prepareFolderReplan(review)
        XCTAssertEqual(plan.source, "Folder"); XCTAssertEqual(plan.destination, "Folder")
        let cancelled = SharedLibraryCoordinator(root: f.root, writerID: a.writerID,
            witnessDirectory: f.root.deletingLastPathComponent().appendingPathComponent("a-local"), afterCommit: { withUnsafeCurrentTask { $0?.cancel() } })
        do { _ = try await Task { try await cancelled.applyFolderReplan(plan) }.value; XCTFail("Expected accepted plan interruption") }
        catch is CancellationError { }
        let outcome = try await a.resumeFolderOperation(id: f.folder.id)
        XCTAssertEqual(outcome.result, .complete); XCTAssertNil(outcome.projectionError)
        let pending = try await a.reviewFolderOperation(id: f.folder.id)
        XCTAssertNil(pending)
        XCTAssertEqual(try Data(contentsOf: f.root.appendingPathComponent("Folder/A.mp3")), Data("Folder/A.mp3".utf8))
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.root.appendingPathComponent("Local").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.root.appendingPathComponent("Peer").path))
    }
    func testFolderRecoveryPreservesNewOwnerOfReleasedOriginalName() async throws {
        let f = try await fixture(physical: true, stage: "published"), a = f.coordinator
        try await a.createSharedFolder(named: "Folder")
        let foreign = Data("new owner's independent document".utf8), file = f.root.appendingPathComponent("Folder/Keep.txt")
        try foreign.write(to: file)
        let plan = try await prepared(f)
        XCTAssertEqual(plan.source, "Local"); XCTAssertEqual(plan.destination, "Target/Peer")
        let result = try await a.applyFolderReplan(plan)
        XCTAssertEqual(result.result, .complete); XCTAssertNil(result.projectionError)
        XCTAssertEqual(try Data(contentsOf: file), foreign)
        XCTAssertEqual(try Data(contentsOf: f.root.appendingPathComponent("Target/Peer/A.mp3")), Data("Folder/A.mp3".utf8))
    }
    func testFolderReplanUsesActualCaseSensitiveVolumeNamespace() async throws {
        guard let configured = ProcessInfo.processInfo.environment["DOCKTAPE_CASE_SENSITIVE_TEST_ROOT"] else {
            throw XCTSkip("Requires a disposable case-sensitive volume")
        }
        let base = URL(fileURLWithPath: configured)
        XCTAssertTrue((try base.resourceValues(forKeys: [.volumeSupportsCaseSensitiveNamesKey])).volumeSupportsCaseSensitiveNames == true)
        let f = try await fixture(physical: true, targetName: "Foo", otherName: "foo", parentBase: base), a = f.coordinator
        let choices = try await a.folderPathChoices(a.read(f.folder))
        let selected = try XCTUnwrap(choices.first { $0.destination == "Foo/Peer" })
        _ = try await a.resolveFolderPath(selected)
        let value = try await a.reviewFolderOperation(id: f.folder.id), review = try XCTUnwrap(value)
        let plan = try await a.prepareFolderReplan(review)
        let result = try await a.applyFolderReplan(plan)
        XCTAssertEqual(result.result, .complete); XCTAssertNil(result.projectionError)
        XCTAssertEqual(try Data(contentsOf: f.root.appendingPathComponent("Foo/Peer/A.mp3")), Data("Folder/A.mp3".utf8))
        XCTAssertTrue(FileManager.default.fileExists(atPath: f.root.appendingPathComponent("foo/Peer").path))
    }
    func testReleasedHistoricalNameOwnerChangeInvalidatesPreparedPlan() async throws {
        let f = try await fixture(physical: true, stage: "published"), a = f.coordinator
        try await a.createSharedFolder(named: "Folder")
        let plan = try await prepared(f)
        let folders = try await a.snapshots(kinds: [.folder])
        let foreign = try XCTUnwrap(folders.first { $0.state.id != f.folder.id && $0.state.value(for: "name") == .text("Folder") })
        _ = try await a.edit(.init(base: foreign, changes: [.assign(field: "name", value: .text("Elsewhere"))]))
        do { _ = try await a.applyFolderReplan(plan); XCTFail("Excluded historical path ownership must remain bound") } catch { }
        XCTAssertEqual(try Data(contentsOf: f.root.appendingPathComponent("Local/A.mp3")), Data("Folder/A.mp3".utf8))
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.root.appendingPathComponent("Target/Peer").path))
    }
    func testAcceptedOriginalSourceRetentionStillVerifiesInventoryDuringReplay() async throws {
        let f = try await fixture(physical: true, peerName: "Folder"), a = f.coordinator
        _ = try await a.resolve(.init(base: try await a.read(f.folder), changes: [.assign(field: "parent", value: .unset)]))
        let choices = try await a.folderPathChoices(a.read(f.folder))
        _ = try await a.resolveFolderPath(XCTUnwrap(choices.first { $0.destination == "Folder" }))
        let value = try await a.reviewFolderOperation(id: f.folder.id)
        let plan = try await a.prepareFolderReplan(XCTUnwrap(value))
        let cancelled = SharedLibraryCoordinator(root: f.root, writerID: a.writerID,
            witnessDirectory: f.root.deletingLastPathComponent().appendingPathComponent("a-local"), afterCommit: { withUnsafeCurrentTask { $0?.cancel() } })
        do { _ = try await Task { try await cancelled.applyFolderReplan(plan) }.value; XCTFail("Expected acceptance before replay") }
        catch is CancellationError { }
        let file = f.root.appendingPathComponent("Folder/.notes"), changed = Data("late external notes".utf8)
        try changed.write(to: file, options: .atomic)
        do { _ = try await a.resumeFolderOperation(id: f.folder.id); XCTFail("Retention phase must not skip its exact inventory") }
        catch SharedLibraryOperationError.contentChanged { }
        XCTAssertEqual(try Data(contentsOf: file), changed)
        XCTAssertEqual(try Data(contentsOf: f.root.appendingPathComponent("Folder/A.mp3")), Data("Folder/A.mp3".utf8))
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.root.appendingPathComponent("Local").path))
    }
    private func deliver(_ source: URL, to destination: URL, writer: UUID) throws {
        let tree = source.appendingPathComponent(".docktape").resolvingSymlinksInPath()
        let iterator = try XCTUnwrap(FileManager.default.enumerator(at: tree, includingPropertiesForKeys: [.isDirectoryKey]))
        for case let file as URL in iterator where file.pathExtension == "json" {
            guard (try file.resourceValues(forKeys: [.isDirectoryKey])).isDirectory != true else { continue }
            let bytes = try Data(contentsOf: file)
            let object = try XCTUnwrap(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
            let payload = object["payload"] as? [String: Any]
            let owner = (object["writerID"] as? String) ?? (payload?["writer"] as? String) ?? (object["founder"] as? String)
            guard owner.flatMap(UUID.init(uuidString:)) == writer else { continue }
            let target = destination.appendingPathComponent(".docktape/" + String(file.resolvingSymlinksInPath().path.dropFirst(tree.path.count + 1)))
            try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try bytes.write(to: target, options: .atomic)
        }
    }
}
