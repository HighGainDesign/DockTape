// © 2026 High Gain Design. All rights reserved.
import AppKit
import HiDockKit

extension DockTapeSharedReviewTests {
    final class HeldWrite: @unchecked Sendable {
        private let condition = NSCondition()
        private var entered = false
        private var released = false
        var waiting: Bool { condition.lock(); defer { condition.unlock() }; return entered }
        func release() { condition.lock(); released = true; condition.broadcast(); condition.unlock() }
        func hold(_ file: URL) throws {
            var error: NSError?, timedOut = false
            NSFileCoordinator().coordinate(writingItemAt: file, options: .forReplacing, error: &error) { _ in
                condition.lock(); entered = true; condition.broadcast()
                let deadline = Date().addingTimeInterval(40)
                while !released { if !condition.wait(until: deadline) { timedOut = true; break } }
                condition.unlock()
            }
            if let error { throw error }
            if timedOut { throw Failure(message: "Owned review read hold timed out") }
        }
    }
    actor AfterCommitHold {
        let hold: HeldWrite, file: URL
        var armed = false
        var worker: Task<Void, Error>?
        init(hold: HeldWrite, file: URL) { self.hold = hold; self.file = file }
        func arm() { armed = true }
        func committed() async {
            guard armed else { return }; armed = false
            let hold = hold, file = file
            worker = Task.detached { try hold.hold(file) }
            while !hold.waiting { try? await Task.sleep(for: .milliseconds(1)) }
        }
        func finish() async throws { hold.release(); try await worker?.value }
    }
    enum FolderPreviewKind { case plan, scope, cleanup }
    @MainActor static func replacedFolderPreviewChecks(_ kind: FolderPreviewKind, model: FolderFileReviewState,
        review: SharedFolderOperationReview, using coordinator: SharedLibraryCoordinator) async throws {
        let before = try await coordinator.read(.init(id: review.id, kind: .folder))
        let deferred: @MainActor () async -> Bool
        switch kind {
        case .plan:
            let prepared = model.updatedPlan
            deferred = { guard let prepared else { return false }; return await model.applyUpdatedPlan(prepared, using: coordinator) }
            model.dismissUpdatedPlan(); await model.prepareUpdatedPlan(review, using: coordinator)
            try expect(model.updatedPlan != nil, "Reopened folder location preview must remain usable")
        case .scope:
            let prepared = model.deletionScope
            deferred = { guard let prepared else { return false }; return await model.applyDeletionScope(prepared, using: coordinator) }
            model.dismissDeletionScope(); await model.prepareDeletionScope(review, using: coordinator)
            try expect(model.deletionScope != nil, "Reopened folder child list must remain usable")
        case .cleanup:
            let prepared = model.cleanupPlan
            deferred = { guard let prepared else { return false }; return await model.applyCleanupPlan(prepared, using: coordinator) }
            model.dismissCleanupPlan(); await model.prepareCleanupPlan(review, using: coordinator)
            try expect(model.cleanupPlan != nil, "Reopened folder cleanup preview must remain usable")
        }
        let message = model.message
        try expect(!(await deferred()), "Cancelled folder preview must not apply its reopened replacement")
        let after = try await coordinator.read(.init(id: review.id, kind: .folder))
        try expect(after.fingerprint == before.fingerprint && model.message == message && !model.isWorking,
            "Stale folder Apply must preserve current state, feedback and work")
        switch kind {
        case .plan: try expect(model.updatedPlan != nil, "Stale folder Apply must preserve new location preview")
        case .scope: try expect(model.deletionScope != nil, "Stale folder Apply must preserve new child-list preview")
        case .cleanup: try expect(model.cleanupPlan != nil, "Stale folder Apply must preserve new cleanup preview")
        }
    }
    @MainActor static func fileReviewDispatchChecks(parent: URL, previewOnly: Bool = false, feedbackOnly: Bool = false) async throws {
        if !feedbackOnly {
            let result = try await queuedPreview(parent.appendingPathComponent("preview"))
            try expect(result["accepted"] as? Bool == false && result["unexpectedBMove"] as? Bool == false && result["AIntermediateRetained"] as? Bool == true,
                "Queued Apply for preview A must reject a replacement valid preview B and preserve both sources")
        }
        if !previewOnly {
            let result = try await lateFeedback(parent.appendingPathComponent("feedback"))
            try expect(result["oldFeedbackInB"] as? Bool == false && result["BOriginalRetained"] as? Bool == true && result["AAlive"] as? Bool == true,
                "Old post-action refresh must not publish A feedback into a model rebound to B")
            let current = try await lateFeedback(parent.appendingPathComponent("feedback-current"), rebind: false)
            try expect(current["accepted"] as? Bool == true && current["originalFeedbackShown"] as? Bool == true && current["AAlive"] as? Bool == true,
                "A current accepted Keep must retain its normal feedback")
        }
        print("Actual file review dispatch passed: replaced preview consent and late feedback stay with their original context.")
    }
    @MainActor static func queuedPreview(_ parent: URL) async throws -> [String: Any] {
        let root = parent.appendingPathComponent("library")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        for name in ["A", "B"] { try Data("Synthetic \(name) original".utf8).write(to: root.appendingPathComponent(name + ".mp3")) }
        let coordinator = SharedLibraryCoordinator(root: root, writerID: UUID(), witnessDirectory: parent.appendingPathComponent("local"))
        _ = try await coordinator.enable(); _ = try await coordinator.projectOutputs()
        for name in ["A", "B"] {
            let id = try await coordinator.reference(to: name + ".mp3").entityID
            do { _ = try await coordinator.relocateRecording(filename: name + ".mp3", title: name + "-intermediate", afterMutation: { _ in throw Failure(message: "actual interrupted move") }) }
            catch let failure as Failure { try expect(failure.message == "actual interrupted move", "Unexpected relocation failure") }
            _ = try await coordinator.edit(.init(base: try await coordinator.read(.init(id: id, kind: .recording)), changes: [.assign(field: "title", value: .text(name + "-final"))]))
        }
        let model = RecordingFileReviewState()
        await model.refresh(using: coordinator)
        guard let a = model.items.first(where: { $0.title == "A-final" }), let b = model.items.first(where: { $0.title == "B-final" }) else { throw Failure(message: "Missing independent actual replans") }
        await model.prepareUpdatedPlan(a, using: coordinator)
        try expect(model.updatedPlan?.review.destination == "A-final.mp3", "A preview must be displayed first")
        guard let displayedA = model.updatedPlan else { throw Failure(message: "Missing displayed A preview") }
        let queuedAApply = { @MainActor in await model.applyUpdatedPlan(displayedA, using: coordinator) }
        model.dismissUpdatedPlan()
        await model.prepareUpdatedPlan(b, using: coordinator)
        try expect(model.updatedPlan?.review.destination == "B-final.mp3", "B replacement preview must be current")
        guard let displayedB = model.updatedPlan else { throw Failure(message: "Missing replacement B preview") }
        let feedback = model.message, accepted = await queuedAApply()
        let unexpectedBMove = FileManager.default.fileExists(atPath: root.appendingPathComponent("B-final.mp3").path)
        let aRetained = FileManager.default.fileExists(atPath: root.appendingPathComponent("A-intermediate.mp3").path)
        try expect(!accepted && !unexpectedBMove && aRetained, "Queued Apply for A cannot apply replacement B")
        try expect(model.updatedPlan?.id == displayedB.id && model.message == feedback && !model.isWorking, "Stale Apply preserves the current B preview and feedback")
        try expect(await model.applyUpdatedPlan(displayedB, using: coordinator), "Displayed B preview applies normally")
        try expect(try Data(contentsOf: root.appendingPathComponent("B-final.mp3")) == Data("Synthetic B original".utf8), "Current B Apply preserves its audio")
        guard let currentA = model.items.first(where: { $0.id == a.id }) else { throw Failure(message: "A must remain pending after B applies") }
        await model.prepareUpdatedPlan(currentA, using: coordinator)
        guard let cancelledA = model.updatedPlan else { throw Failure(message: "Missing current A preview") }
        model.dismissUpdatedPlan(); await model.prepareUpdatedPlan(currentA, using: coordinator)
        guard let reopenedA = model.updatedPlan else { throw Failure(message: "Missing reopened A preview") }
        try expect(!(await model.applyUpdatedPlan(cancelledA, using: coordinator)), "Cancelled same-entity preview cannot apply the reopened one")
        try expect(model.updatedPlan?.id == reopenedA.id && FileManager.default.fileExists(atPath: root.appendingPathComponent("A-intermediate.mp3").path), "Cancelled preview preserves current review and original")
        try expect(await model.applyUpdatedPlan(reopenedA, using: coordinator), "Reopened A applies after its own approval")
        try expect(try Data(contentsOf: root.appendingPathComponent("A-final.mp3")) == Data("Synthetic A original".utf8), "Current A Apply preserves its audio")
        return ["accepted": accepted, "unexpectedBMove": unexpectedBMove, "AIntermediateRetained": aRetained]
    }
    @MainActor static func lateFeedback(_ parent: URL, rebind: Bool = true) async throws -> [String: Any] {
        let root = parent.appendingPathComponent("a"), other = parent.appendingPathComponent("b"), witness = parent.appendingPathComponent("a-local")
        for directory in [root, other] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try Data("Synthetic feedback original".utf8).write(to: directory.appendingPathComponent("Meeting.mp3"))
        }
        let writer = UUID(), seed = SharedLibraryCoordinator(root: root, writerID: writer, witnessDirectory: witness)
        _ = try await seed.enable(); _ = try await seed.projectOutputs()
        let entity = SharedEntityIdentity(id: try await seed.reference(to: "Meeting.mp3").entityID, kind: .recording)
        _ = try await seed.edit(.init(base: try await seed.read(entity), changes: [.delete]))
        let file = root.appendingPathComponent(".docktape/records/" + entity.id.uuidString.lowercased() + "/" + writer.uuidString.lowercased() + ".json")
        let hold = HeldWrite(); defer { hold.release() }
        let trigger = AfterCommitHold(hold: hold, file: file)
        let a = SharedLibraryCoordinator(root: root, writerID: writer, witnessDirectory: witness, afterCommit: { await trigger.committed() })
        let b = SharedLibraryCoordinator(root: other, writerID: UUID(), witnessDirectory: parent.appendingPathComponent("b-local"))
        _ = try await b.enable(); _ = try await b.projectOutputs()
        let baseline = RecordingFileReviewState()
        await baseline.refresh(using: b)
        try expect(baseline.message == nil, "B fixture must have no initial failure feedback")
        let model = RecordingFileReviewState()
        await model.refresh(using: a)
        try expect(model.deletionPreparations.count == 1, "Actual tombstone must need file review")
        await trigger.arm()
        let action = Task { @MainActor in await model.keepForReview(id: entity.id, using: a) }
        let limit = ContinuousClock.now.advanced(by: .seconds(15))
        while !(hold.waiting && model.isLoading) {
            guard ContinuousClock.now < limit else { hold.release(); _ = await action.value; throw Failure(message: "Action did not reach real held post-action refresh") }
            try await Task.sleep(for: .milliseconds(5))
        }
        if rebind { model.clear(); await model.refresh(using: b) }
        let beforeRelease = model.message
        print("B_POST_REFRESH: message=\(model.message ?? "none"), working=\(model.isWorking), rows=\(model.items.count)"); fflush(stdout)
        try await trigger.finish()
        let accepted = await action.value
        let currentA = try await a.read(entity)
        return ["accepted": accepted, "oldFeedbackInB": rebind && (model.message?.contains("Recording kept") == true || beforeRelease?.contains("Recording kept") == true),
            "originalFeedbackShown": !rebind && model.message?.contains("Recording kept") == true,
            "AAlive": currentA.state.lifecycle == .alive,
            "message": model.message ?? "none", "BOriginalRetained": FileManager.default.fileExists(atPath: other.appendingPathComponent("Meeting.mp3").path)]
    }
}
