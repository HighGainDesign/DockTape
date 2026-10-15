// © 2026 High Gain Design. All rights reserved.
import Foundation
import Observation
import HiDockKit

@Observable @MainActor final class FolderFileReviewState {
    enum Action { case resume, acknowledge }
    private(set) var items: [SharedFolderOperationReview] = []
    private(set) var isLoading = false
    private(set) var isWorking = false
    private(set) var inspectionFailed = false
    private(set) var message: String?
    private var binding: SharedLibraryCoordinator?
    private var request = UUID()
    private var action: Task<Bool, Never>?
    private var workID = UUID()

    func clear() {
        request = UUID(); workID = UUID(); action?.cancel(); action = nil
        binding = nil; items = []; message = nil; isLoading = false; isWorking = false; inspectionFailed = false
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
                case .resume:
                    let outcome = try await coordinator.resumeReviewedFolderOperation(review)
                    switch outcome.result {
                    case .complete: text = outcome.projectionError == nil ? "Folder change completed." : "Folder change completed. Readable files still need to be refreshed."
                    case .needsReplanning: text = "The folder plan changed. Reload and review its competing changes."
                    case .waitingForAcknowledgments: text = "Waiting for approval from participating Macs. Review related pending recordings and folders."
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
