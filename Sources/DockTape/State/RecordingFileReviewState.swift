// © 2026 High Gain Design. All rights reserved.
import Foundation
import Observation
import HiDockKit

@Observable @MainActor final class RecordingFileReviewState {
    enum Action { case resume, acknowledge }
    private(set) var items: [SharedRecordingOperationReview] = []
    private(set) var isLoading = false
    private(set) var isWorking = false
    private(set) var inspectionFailed = false
    private(set) var message: String?
    private(set) var updatedPlan: SharedRecordingReplanReview?
    private var binding: SharedLibraryCoordinator?
    private var request = UUID()
    private var action: Task<Bool, Never>?
    private var workID = UUID()

    func clear() {
        request = UUID(); workID = UUID(); action?.cancel(); action = nil
        binding = nil; items = []; message = nil; updatedPlan = nil; isLoading = false; isWorking = false; inspectionFailed = false
    }
    func refresh(using coordinator: SharedLibraryCoordinator) async {
        if binding !== coordinator { clear(); binding = coordinator }
        let ticket = UUID(); request = ticket; isLoading = true; message = nil; inspectionFailed = false
        defer { if request == ticket { isLoading = false } }
        do {
            let views = try await coordinator.snapshots(kinds: [.recording])
            var rows: [SharedRecordingOperationReview] = [], failures = 0
            for view in views where view.state.fields.keys.contains(where: { $0.hasPrefix("materialization.") }) {
                try Task.checkCancellation()
                do { if let row = try await coordinator.reviewRecordingOperation(id: view.state.id) { rows.append(row) } }
                catch is CancellationError { throw CancellationError() }
                catch { failures += 1 }
            }
            guard request == ticket, binding === coordinator, !Task.isCancelled else { return }
            items = rows.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
            if failures > 0 { inspectionFailed = true; message = "Some pending file changes could not be inspected. Reload after sync finishes or join this library before continuing." }
        } catch {
            if request == ticket, binding === coordinator, !(error is CancellationError) { inspectionFailed = true; message = "Pending file changes could not be loaded. Reload after the library is available." }
        }
    }
    func dismissUpdatedPlan() {
        guard !isWorking else { return }
        updatedPlan = nil
    }
    func prepareUpdatedPlan(_ review: SharedRecordingOperationReview, using coordinator: SharedLibraryCoordinator) async {
        guard binding === coordinator, !isLoading, !isWorking, review.canReplan else { return }
        let ticket = request; let work = UUID(); workID = work; isWorking = true; message = nil
        defer { if binding === coordinator, workID == work { isWorking = false } }
        do {
            let prepared = try await coordinator.prepareRecordingReplan(review)
            guard binding === coordinator, request == ticket, !Task.isCancelled else { return }
            updatedPlan = prepared
        } catch {
            if binding === coordinator, request == ticket, !(error is CancellationError) {
                message = "The updated plan could not be prepared. Reload after sync finishes; existing files are preserved."
            }
        }
    }
    @discardableResult func applyUpdatedPlan(using coordinator: SharedLibraryCoordinator) async -> Bool {
        guard binding === coordinator, !isLoading, !isWorking, let prepared = updatedPlan else { return false }
        let ticket = request; let work = UUID(); workID = work; isWorking = true; message = nil
        let task = Task { [weak self] in
            do {
                try Task.checkCancellation()
                let outcome = try await coordinator.applyRecordingReplan(prepared)
                guard let self, self.binding === coordinator, self.request == ticket, !Task.isCancelled else { return true }
                self.updatedPlan = nil
                await self.refresh(using: coordinator)
                self.message = outcome.result == .complete && outcome.projectionError == nil
                    ? "Updated file plan completed." : "Updated plan accepted. Review any remaining pending file changes."
                return true
            } catch {
                guard let self, self.binding === coordinator, self.request == ticket else { return false }
                self.updatedPlan = nil
                await self.refresh(using: coordinator)
                if !(error is CancellationError) {
                    self.message = "The updated plan could not finish. Review the current pending change before trying again; existing files are preserved."
                }
                return false
            }
        }
        action = task
        let result = await task.value
        if binding === coordinator, workID == work { isWorking = false; action = nil }
        return result
    }
    @discardableResult func perform(_ choice: Action, review: SharedRecordingOperationReview, using coordinator: SharedLibraryCoordinator) async -> Bool {
        guard binding === coordinator, !isLoading, !isWorking else { return false }
        let ticket = request; let work = UUID(); workID = work; isWorking = true; message = nil
        let task = Task { [weak self] in
            do {
                try Task.checkCancellation()
                let text: String
                switch choice {
                case .acknowledge:
                    try await coordinator.acknowledgeReviewedRecordingOperation(review)
                    text = "Approval recorded on this Mac."
                case .resume:
                    let outcome = try await coordinator.resumeReviewedRecordingOperation(review)
                    switch outcome.result {
                    case .complete: text = outcome.projectionError == nil ? "File change completed." : "File change completed. Readable files still need to be refreshed."
                    case .needsReplanning: text = "This plan changed. Reload it for another review."
                    case .waitingForAcknowledgments: text = "Waiting for approval from participating Macs."
                    case .waitingForActiveWork: text = "Waiting for active work to finish."
                    case .waitingForFile(let path): text = "Waiting for " + path + " to become available."
                    case .directoryNotEmpty(let path): text = path + " still contains files that need review."
                    }
                }
                guard let self, self.binding === coordinator, self.request == ticket, !Task.isCancelled else { return true }
                await self.refresh(using: coordinator)
                self.message = text
                return true
            } catch {
                guard let self, self.binding === coordinator, self.request == ticket else { return false }
                if error as? SharedLibraryCoordinatorError == .staleReview || error as? SharedLibraryOperationError == .staleAuthority {
                    self.message = "The recording, plan or participating Macs changed. Reload before deciding."
                } else if !(error is CancellationError) { self.message = "The file change could not continue. Reload its review; existing files are preserved." }
                return false
            }
        }
        action = task
        let result = await task.value
        if binding === coordinator, workID == work { isWorking = false; action = nil }
        return result
    }
}
