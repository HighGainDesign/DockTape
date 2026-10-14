// © 2026 High Gain Design. All rights reserved.
import XCTest

@testable import HiDockKit

final class SharedLibraryCoordinatorTests: XCTestCase {
    private var roots: [URL] = []
    private var owners: [String: UUID] = [:]
    private let a = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
    private let b = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
    override func tearDown() {
        for root in roots { try? FileManager.default.removeItem(at: root) }
        roots = []
    }
    private func root(writer: UUID? = nil) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        roots.append(url)
        if let writer { owners[url.resolvingSymlinksInPath().path] = writer }
        return url
    }
    private func deliver(_ source: URL, to destination: URL) throws {
        let origin = try XCTUnwrap(owners[source.resolvingSymlinksInPath().path])
        let tree = source.resolvingSymlinksInPath().appendingPathComponent(".docktape")
        let enumerator = try XCTUnwrap(
            FileManager.default.enumerator(at: tree, includingPropertiesForKeys: [.isDirectoryKey]))
        for case let file as URL in enumerator {
            guard (try file.resourceValues(forKeys: [.isDirectoryKey])).isDirectory != true else { continue }
            let prefix = tree.path.hasSuffix("/") ? tree.path : tree.path + "/"
            let normalized = file.resolvingSymlinksInPath().path
            XCTAssertTrue(
                normalized.hasPrefix(prefix), "Enumerator must preserve source prefix: \(normalized), \(prefix)")
            let relative = String(normalized.dropFirst(prefix.count))
            let bytes = try Data(contentsOf: file)
            let object = try XCTUnwrap(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
            let payload = object["payload"] as? [String: Any]
            let owner =
                (object["writerID"] as? String) ?? (payload?["writer"] as? String) ?? (object["founder"] as? String)
            guard owner.flatMap(UUID.init(uuidString:)) == origin else { continue }
            let target = destination.appendingPathComponent(".docktape/" + relative)
            try FileManager.default.createDirectory(
                at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try bytes.write(to: target, options: .atomic)
        }
    }
    private func pair() async throws -> (
        URL, URL, SharedLibraryCoordinator, SharedLibraryCoordinator, SharedEntityIdentity
    ) {
        let left = try root(writer: a)
        let right = try root(writer: b)
        try Data("synthetic recording".utf8).write(to: left.appendingPathComponent("Meeting.mp3"))
        try Data("synthetic recording".utf8).write(to: right.appendingPathComponent("Meeting.mp3"))
        let one = SharedLibraryCoordinator(root: left, writerID: a)
        let manifest = try await one.enable()
        try deliver(left, to: right)
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: right.appendingPathComponent(".docktape/format.json").path),
            "Manifest must be delivered")
        let two = SharedLibraryCoordinator(root: right, writerID: b)
        try await two.requestEnrollment(requestID: UUID(), label: "Second Mac")
        try deliver(right, to: left)
        try await one.refresh()
        try deliver(left, to: right)
        try await two.refresh()
        let admitted = try await two.mayEdit()
        XCTAssertTrue(admitted)
        return (left, right, one, two, manifest.references[0].entity)
    }
    func testEnrollmentWaitsForExistingMacAndCurrentCheckpoint() async throws {
        let left = try root(writer: a)
        let right = try root(writer: b)
        let one = SharedLibraryCoordinator(root: left, writerID: a)
        _ = try await one.enable()
        try deliver(left, to: right)
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: right.appendingPathComponent(".docktape/format.json").path),
            "Manifest must be delivered")
        let two = SharedLibraryCoordinator(root: right, writerID: b)
        try await two.requestEnrollment(requestID: UUID(), label: "Second Mac")
        let waiting = try await two.mayEdit()
        XCTAssertFalse(waiting)
        try deliver(right, to: left)
        try await one.refresh()
        try deliver(left, to: right)
        try await two.refresh()
        let enrolled = try await two.mayEdit()
        XCTAssertTrue(enrolled)
    }
    func testAnObservedAdmissionSurvivesOlderFounderFileDeliveryAndRestart() async throws {
        let left = try root(writer: a)
        let right = try root(writer: b)
        let one = SharedLibraryCoordinator(root: left, writerID: a)
        _ = try await one.enable()
        let owner = ".docktape/members/\(a.uuidString.lowercased()).json"
        let old = try Data(contentsOf: left.appendingPathComponent(owner))
        try deliver(left, to: right)
        let two = SharedLibraryCoordinator(root: right, writerID: b)
        try await two.requestEnrollment(requestID: UUID(), label: "Second Mac")
        try deliver(right, to: left)
        try await one.refresh()
        try deliver(left, to: right)
        try await two.refresh()
        let admitted = try await two.mayEdit()
        XCTAssertTrue(admitted)
        try old.write(to: right.appendingPathComponent(owner), options: .atomic)
        let restarted = SharedLibraryCoordinator(root: right, writerID: b)
        let stillAdmitted = try await restarted.mayEdit()
        XCTAssertTrue(stillAdmitted, "Accepted membership must be durably observed in this writer's own file")
    }
    func testNewJoinDuringSameMacCertificateCommitRejectsStaleAdmission() async throws {
        let directory = try root()
        let manifest = try await LegacyLibraryBootstrap(root: directory, writerID: a).enable()
        let repository = SharedMemberRepository(root: directory, writer: a, manifest: manifest)
        let first = try await repository.load()
        var membership = first.membership
        try membership.requestJoin(.init(writer: b, label: "B"))
        let base = try await repository.commit(base: first, membership: membership)
        let proposal = try membership.proposal(checkpoint: "ready")
        let certificate = try membership.certify(
            proposal, votes: [a, b].map { .init(writer: $0, proposal: proposal.fingerprint, checkpoint: "ready") })
        var admitted = membership
        try admitted.accept(certificate)
        let current = try await repository.load()
        var changed = current.membership
        try changed.requestJoin(.init(writer: UUID(), label: "C"))
        _ = try await repository.commit(base: current, membership: changed)
        do {
            _ = try await repository.commit(base: base, membership: admitted)
            XCTFail("Do not accept a certificate after another local process added a join")
        } catch { XCTAssertEqual(error as? SharedMembershipError, .staleProposal) }
        let result = try await repository.load()
        XCTAssertFalse(result.membership.mayEdit(b))
    }

    func testRefreshAdvancesOnlyQuorumCheckpointsAndKeepsACommonViewDuringGenerationConflict() async throws {
        let (left, right, one, two, entity) = try await pair()
        let initial = try await two.read(entity)
        XCTAssertNotNil(initial.confirmedState, "Both writers acquired the same initial state")
        try deliver(right, to: left)
        try await one.refresh()
        let before = try await one.read(entity)
        let common = try SharedDocument(id: UUID(), json: Data("{\"text\":\"Common transcript\"}".utf8))
        _ = try await one.edit(.init(base: before, changes: [.generation(common, component: .transcript)]))
        try await one.refresh()
        let unconfirmed = try await one.read(entity)
        XCTAssertNil(
            unconfirmed.confirmedState?.currentDocument(for: .transcript),
            "An offline peer has not consented to the new generation")
        try deliver(left, to: right)
        try await two.refresh()
        try deliver(right, to: left)
        try await one.refresh()
        try deliver(left, to: right)
        try await two.refresh()
        let settled = try await one.read(entity)
        let other = try await two.read(entity)
        XCTAssertEqual(
            settled.confirmedState?.currentDocument(for: .transcript)?.json,
            Data("{\"text\":\"Common transcript\"}".utf8))
        let token = try await two.pinJob(entity, input: .transcript)
        try await two.refresh()
        try await two.validateJob(token)
        let lhs = try SharedDocument(id: UUID(), json: Data("{\"text\":\"Left\"}".utf8))
        let rhs = try SharedDocument(id: UUID(), json: Data("{\"text\":\"Right\"}".utf8))
        _ = try await one.edit(.init(base: settled, changes: [.generation(lhs, component: .transcript)]))
        _ = try await two.edit(.init(base: other, changes: [.generation(rhs, component: .transcript)]))
        let owned = right.appendingPathComponent(
            ".docktape/records/\(entity.id.uuidString.lowercased())/\(b.uuidString.lowercased()).json")
        let acceptedBytes = try Data(contentsOf: owned)
        try deliver(left, to: right)
        XCTAssertEqual(
            try Data(contentsOf: owned), acceptedBytes,
            "Sync must not send a stale cached B version back over B's own accepted edit")
        try deliver(right, to: left)
        try await one.refresh()
        try await two.refresh()
        let first = try await one.read(entity)
        let second = try await two.read(entity)
        XCTAssertNil(first.state.currentDocument(for: .transcript))
        XCTAssertEqual(
            first.confirmedState?.currentDocument(for: .transcript)?.json, Data("{\"text\":\"Common transcript\"}".utf8)
        )
        XCTAssertEqual(first.confirmedState, second.confirmedState)
    }

    func testRemoteGenerationsRefreshWithoutRelaunchAndOldJobCannotCommit() async throws {
        let (left, right, one, two, entity) = try await pair()
        let initial = try await one.read(entity)
        let document = try SharedDocument(id: UUID(), json: Data("{\"message\":\"First\"}".utf8))
        _ = try await one.edit(.init(base: initial, changes: [.generation(document, component: .transcript)]))
        try deliver(left, to: right)
        try await two.refresh()
        let observed = try await two.read(entity)
        XCTAssertEqual(observed.state.currentDocument(for: .transcript)?.json, Data("{\"message\":\"First\"}".utf8))
        let token = try await two.pinJob(entity, input: .transcript)
        let newer = try SharedDocument(id: UUID(), json: Data("{\"message\":\"Second\"}".utf8))
        let next = try await one.read(entity)
        _ = try await one.edit(.init(base: next, changes: [.generation(newer, component: .transcript)]))
        try deliver(left, to: right)
        try await two.refresh()
        let current = try await two.read(entity)
        XCTAssertEqual(current.state.currentDocument(for: .transcript)?.json, Data("{\"message\":\"Second\"}".utf8))
        do {
            try await two.validateJob(token)
            XCTFail("Old generation job must not publish")
        } catch { XCTAssertEqual(error as? SharedLibraryCoordinatorError, .staleJob) }
    }
    func testResolutionBasedOnOldReviewRejectsAnUnseenRemoteChange() async throws {
        let (left, right, one, two, entity) = try await pair()
        let x = try await one.read(entity)
        let y = try await two.read(entity)
        _ = try await one.edit(.init(base: x, changes: [.assign(field: "title", value: .text("Alpha"))]))
        _ = try await two.edit(.init(base: y, changes: [.assign(field: "title", value: .text("Beta"))]))
        try deliver(left, to: right)
        try deliver(right, to: left)
        try await one.refresh()
        try await two.refresh()
        let reviewed = try await one.read(entity)
        XCTAssertEqual(reviewed.state.fields["title"]?.values, [.text("Alpha"), .text("Beta")])
        let update = try await two.read(entity)
        _ = try await two.resolve(.init(base: update, changes: [.assign(field: "title", value: .text("Gamma"))]))
        try deliver(right, to: left)
        do {
            _ = try await one.resolve(
                .init(base: reviewed, changes: [.assign(field: "title", value: .text("Chosen old value"))]))
            XCTFail()
        } catch { XCTAssertEqual(error as? SharedLibraryCoordinatorError, .staleReview) }
        let final = try await one.read(entity)
        XCTAssertEqual(final.state.value(for: "title"), .text("Gamma"))
    }
    func testRealFilePresenterRefreshesRemoteStateWithoutExplicitRefreshOrRelaunch() async throws {
        let (left, _, one, _, entity) = try await pair()
        _ = try await one.read(entity)
        let stream = await one.events()
        let changed = expectation(description: "Actual coordinated peer write refreshes coordinator")
        let listener = Task {
            for await event in stream {
                if case .entity(_, let id, _) = event, id == entity {
                    let snapshot = try await one.read(entity)
                    if snapshot.state.value(for: "title") == .text("Remote change") {
                        changed.fulfill()
                        return
                    }
                }
            }
        }
        try await one.startMonitoring()
        let peer = SharedLibraryRepository(root: left, writerID: b)
        let before = try await peer.load(entity: entity)
        _ = try await peer.commit(
            .init(base: before, changes: [.assign(field: "title", value: .text("Remote change"))]))
        await fulfillment(of: [changed], timeout: 3)
        await one.stopMonitoring()
        listener.cancel()
        _ = try await listener.value
    }

    func testRefreshDoesNotRestoreDeletionAndUntrackedJSONIsOneStableCandidate() async throws {
        let (left, right, one, two, entity) = try await pair()
        let base = try await one.read(entity)
        let doc = try SharedDocument(id: UUID(), json: Data("{\"message\":\"Canonical\"}".utf8))
        _ = try await one.edit(.init(base: base, changes: [.generation(doc, component: .transcript)]))
        let url = left.appendingPathComponent("Meeting.transcript.json")
        let external = Data("{\"message\":\"External edit\"}".utf8)
        try external.write(to: url)
        let first = try await one.inspectExternal(entity, component: .transcript, at: url)
        let second = try await one.inspectExternal(entity, component: .transcript, at: url)
        XCTAssertNotNil(first)
        XCTAssertEqual(first, second)
        XCTAssertEqual(try Data(contentsOf: url), external)
        let observed = try await one.read(entity)
        _ = try await one.edit(.init(base: observed, changes: [.delete]))
        try deliver(left, to: right)
        try await two.refresh()
        let hidden = try await two.read(entity)
        XCTAssertEqual(hidden.state.lifecycle, .deleted)
        XCTAssertTrue(FileManager.default.fileExists(atPath: right.appendingPathComponent("Meeting.mp3").path))
    }
}
