// © 2026 High Gain Design. All rights reserved.
import Foundation
import Observation
import HiDockKit

@Observable @MainActor final class FolderFileReviewState {
    enum Action { case resume, acknowledge, prepareChildren }
    private(set) var items: [SharedFolderOperationReview] = []
    private(set) var isLoading = false
    private(set) var isWorking = false
    private(set) var inspectionFailed = false
    private(set) var message: String?
    private(set) var updatedPlan: FileReviewPreview<SharedFolderReplanReview>?
    private(set) var deletionScope: FileReviewPreview<SharedFolderDeletionScopeReview>?
    private(set) var cleanupPlan: FileReviewPreview<SharedFolderCleanupReview>?
    private var binding: SharedLibraryCoordinator?
    private var request = UUID()
    private var action: Task<Bool, Never>?
    private var workID = UUID()

    func clear() {
        request = UUID(); workID = UUID(); action?.cancel(); action = nil
        binding = nil; items = []; message = nil; updatedPlan = nil; deletionScope = nil; cleanupPlan = nil; isLoading = false; isWorking = false; inspectionFailed = false
    }
    func refresh(using coordinator: SharedLibraryCoordinator) async {
        if binding !== coordinator { clear(); binding = coordinator }
        let ticket = UUID(); request = ticket; isLoading = true; inspectionFailed = false; message = nil
        defer { if request == ticket { isLoading = false } }
        do {
            let views = try await coordinator.snapshots(kinds: [.folder])
            var rows: [SharedFolderOperationReview] = [], failures = 0
            for view in views {
                try Task.checkCancellation()
                guard view.state.value(for: "deletionRequest") != nil || view.state.fields.keys.contains(where: { $0.hasPrefix("materialization.files.") }) else { continue }
                do { if let row = try await coordinator.reviewFolderOperation(id: view.state.id) { rows.append(row) } }
                catch is CancellationError { throw CancellationError() }
                catch { failures += 1 }
            }
            guard binding === coordinator, request == ticket, !Task.isCancelled else { return }
            items = rows.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            if failures > 0 { inspectionFailed = true; message = "Some folder changes could not be inspected. Reload after sync finishes." }
        } catch {
            if binding === coordinator, request == ticket, !(error is CancellationError) {
                inspectionFailed = true; message = "Folder changes could not be loaded. Reload when the library is available."
            }
        }
    }
    func dismissUpdatedPlan() { guard !isWorking else { return }; updatedPlan = nil }
    func prepareUpdatedPlan(_ review: SharedFolderOperationReview, using coordinator: SharedLibraryCoordinator) async {
        guard binding === coordinator, !isLoading, !isWorking, review.canReplan else { return }
        let ticket = request, work = UUID(); workID = work; isWorking = true; message = nil
        defer { if binding === coordinator, workID == work { isWorking = false } }
        do {
            let prepared = try await coordinator.prepareFolderReplan(review)
            guard binding === coordinator, request == ticket, !Task.isCancelled else { return }
            deletionScope = nil; cleanupPlan = nil; updatedPlan = FileReviewPreview(review: prepared)
        } catch {
            if binding === coordinator, request == ticket, !(error is CancellationError) { message = "The directory plan could not be prepared. Reload after sync finishes; existing folders and files are preserved." }
        }
    }
    @discardableResult func applyUpdatedPlan(_ preview: FileReviewPreview<SharedFolderReplanReview>, using coordinator: SharedLibraryCoordinator) async -> Bool {
        guard binding === coordinator, !isLoading, !isWorking, updatedPlan?.id == preview.id else { return false }
        let prepared = preview.review
        let ticket = request, work = UUID(); workID = work; isWorking = true; message = nil
        let task = Task { [weak self] in
            do {
                try Task.checkCancellation()
                let outcome = try await coordinator.applyFolderReplan(prepared)
                guard let self, self.binding === coordinator, self.request == ticket, !Task.isCancelled else { return true }
                self.updatedPlan = nil
                await self.refresh(using: coordinator)
                guard self.binding === coordinator, self.workID == work, !Task.isCancelled else { return true }
                self.message = outcome.result == .complete && outcome.projectionError == nil ? "Updated folder plan completed." : "Updated folder plan accepted. Review remaining folder changes."
                return true
            } catch {
                guard let self, self.binding === coordinator, self.request == ticket else { return false }
                self.updatedPlan = nil
                await self.refresh(using: coordinator)
                guard self.binding === coordinator, self.workID == work, !Task.isCancelled else { return false }
                if !(error is CancellationError) { self.message = "The directory plan could not finish. Reload before trying again; existing files are preserved." }
                return false
            }
        }
        action = task
        let result = await task.value
        if binding === coordinator, workID == work { isWorking = false; action = nil }
        return result
    }
    func dismissDeletionScope() { guard !isWorking else { return }; deletionScope = nil }
    func prepareDeletionScope(_ review: SharedFolderOperationReview, using coordinator: SharedLibraryCoordinator) async {
        guard binding === coordinator, !isLoading, !isWorking, review.canReviewDeletionScope else { return }
        let ticket = request, work = UUID(); workID = work; isWorking = true; message = nil
        defer { if binding === coordinator, workID == work { isWorking = false } }
        do {
            let prepared = try await coordinator.prepareFolderDeletionScope(review)
            guard binding === coordinator, request == ticket, !Task.isCancelled else { return }
            updatedPlan = nil; cleanupPlan = nil; deletionScope = FileReviewPreview(review: prepared)
        } catch {
            if binding === coordinator, request == ticket, !(error is CancellationError) { message = "The child list could not be prepared. Reload after sync finishes; existing files are preserved." }
        }
    }
    @discardableResult func applyDeletionScope(_ preview: FileReviewPreview<SharedFolderDeletionScopeReview>, using coordinator: SharedLibraryCoordinator) async -> Bool {
        guard binding === coordinator, !isLoading, !isWorking, deletionScope?.id == preview.id else { return false }
        let prepared = preview.review
        let ticket = request, work = UUID(); workID = work; isWorking = true; message = nil
        let task = Task { [weak self] in
            do {
                try Task.checkCancellation()
                _ = try await coordinator.applyFolderDeletionScope(prepared)
                guard let self, self.binding === coordinator, self.request == ticket, !Task.isCancelled else { return true }
                self.deletionScope = nil
                await self.refresh(using: coordinator)
                guard self.binding === coordinator, self.workID == work, !Task.isCancelled else { return true }
                self.message = "Child list updated. Prepare child deletions separately; existing cleanup approvals remain required."
                return true
            } catch {
                guard let self, self.binding === coordinator, self.request == ticket else { return false }
                self.deletionScope = nil
                await self.refresh(using: coordinator)
                guard self.binding === coordinator, self.workID == work, !Task.isCancelled else { return false }
                if !(error is CancellationError) { self.message = "The folder, child list, receipt or participating Macs changed. Reload before reviewing it again; existing files are preserved." }
                return false
            }
        }
        action = task; let result = await task.value
        if binding === coordinator, workID == work { isWorking = false; action = nil }
        return result
    }
    func dismissCleanupPlan() { guard !isWorking else { return }; cleanupPlan = nil }
    func prepareCleanupPlan(_ review: SharedFolderOperationReview, using coordinator: SharedLibraryCoordinator) async {
        guard binding === coordinator, !isLoading, !isWorking, review.canReviewCleanupPlan else { return }
        let ticket = request, work = UUID(); workID = work; isWorking = true; message = nil
        defer { if binding === coordinator, workID == work { isWorking = false } }
        do {
            let prepared = try await coordinator.prepareFolderCleanupPlan(review)
            guard binding === coordinator, request == ticket, !Task.isCancelled else { return }
            updatedPlan = nil; deletionScope = nil; cleanupPlan = FileReviewPreview(review: prepared)
        } catch {
            if binding === coordinator, request == ticket, !(error is CancellationError) { message = "The cleanup plan is not ready. Finish related pending files and reload; existing directories and rename progress are preserved." }
        }
    }
    @discardableResult func applyCleanupPlan(_ preview: FileReviewPreview<SharedFolderCleanupReview>, using coordinator: SharedLibraryCoordinator) async -> Bool {
        guard binding === coordinator, !isLoading, !isWorking, cleanupPlan?.id == preview.id else { return false }
        let prepared = preview.review
        let ticket = request, work = UUID(); workID = work; isWorking = true; message = nil
        let task = Task { [weak self] in
            do {
                try Task.checkCancellation()
                _ = try await coordinator.applyFolderCleanupPlan(prepared)
                guard let self, self.binding === coordinator, self.request == ticket, !Task.isCancelled else { return true }
                self.cleanupPlan = nil
                await self.refresh(using: coordinator)
                guard self.binding === coordinator, self.workID == work, !Task.isCancelled else { return true }
                self.message = "Cleanup plan saved. Approve folder deletion separately on each participating Mac."
                return true
            } catch {
                guard let self, self.binding === coordinator, self.request == ticket else { return false }
                self.cleanupPlan = nil
                await self.refresh(using: coordinator)
                guard self.binding === coordinator, self.workID == work, !Task.isCancelled else { return false }
                if !(error is CancellationError) { self.message = "The directory, rename progress or participating Macs changed. Reload before reviewing cleanup again; existing files are preserved." }
                return false
            }
        }
        action = task; let result = await task.value
        if binding === coordinator, workID == work { isWorking = false; action = nil }
        return result
    }
    @discardableResult func perform(_ choice: Action, review: SharedFolderOperationReview, using coordinator: SharedLibraryCoordinator) async -> Bool {
        guard binding === coordinator, !isLoading, !isWorking, items.contains(where: { $0.id == review.id }) else { return false }
        let ticket = request, work = UUID(); workID = work; isWorking = true; message = nil
        let task = Task { [weak self] in
            do {
                try Task.checkCancellation()
                let text: String
                switch choice {
                case .acknowledge:
                    try await coordinator.acknowledgeReviewedFolderOperation(review)
                    text = "Folder deletion approval recorded on this Mac."
                case .resume, .prepareChildren:
                    let outcome: SharedFolderFileOutcome
                    if case .prepareChildren = choice { outcome = try await coordinator.prepareReviewedFolderChildren(review) }
                    else { outcome = try await coordinator.resumeReviewedFolderOperation(review) }
                    switch outcome.result {
                    case .complete: text = outcome.projectionError == nil ? "Folder change completed." : "Folder change completed. Readable files still need to be refreshed."
                    case .needsReplanning: text = "The folder plan changed. Reload and review its competing changes."
                    case .waitingForAcknowledgments:
                        if case .prepareChildren = choice { text = "Child deletions prepared. Review Pending Files for recording approvals; folder approval remains separate." }
                        else { text = "Waiting for approval from participating Macs. Review related pending recordings and folders." }
                    case .waitingForActiveWork: text = "Waiting for active work in this folder to finish."
                    case .waitingForFile(let path): text = "Waiting for " + path + " to become available."
                    case .directoryNotEmpty(let path): text = path + " still contains files that need review. Existing files are preserved."
                    }
                }
                guard let self, self.binding === coordinator, self.request == ticket, !Task.isCancelled else { return true }
                await self.refresh(using: coordinator)
                guard self.binding === coordinator, self.workID == work, !Task.isCancelled else { return true }
                self.message = text
                return true
            } catch {
                guard let self, self.binding === coordinator, self.request == ticket, !Task.isCancelled else { return false }
                await self.refresh(using: coordinator)
                guard self.binding === coordinator, self.workID == work, !Task.isCancelled else { return false }
                self.message = "The folder, plan or participating Macs changed. Reload before continuing; existing files are preserved."
                return false
            }
        }
        action = task
        let result = await task.value
        if binding === coordinator, workID == work { isWorking = false; action = nil }
        return result
    }
}
