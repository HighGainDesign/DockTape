// © 2026 High Gain Design. All rights reserved.
import Foundation
import Observation
import HiDockKit

@Observable @MainActor
final class ExternalSidecarReviewState {
    struct Item: Identifiable {
        let id: String
        let title: String
        let review: SharedSidecarReview?
        let error: String?
        let bootstrap: SharedBootstrapProjectionReview?
        init(id: String, title: String, review: SharedSidecarReview? = nil, error: String? = nil,
             bootstrap: SharedBootstrapProjectionReview? = nil) {
            self.id = id; self.title = title; self.review = review; self.error = error; self.bootstrap = bootstrap
        }
    }
    private(set) var items: [Item] = []
    private(set) var isLoading = false
    private(set) var isApplying = false
    private(set) var message: String?
    private var coordinator: SharedLibraryCoordinator?
    private var request = UUID()
    private var action: Task<Bool, Never>?
    private var scan: Task<Void, Never>?

    func clear() {
        request = UUID(); scan?.cancel(); scan = nil; action?.cancel(); action = nil; coordinator = nil; items = []
        isLoading = false; isApplying = false; message = nil
    }
    func refresh(using coordinator: SharedLibraryCoordinator) async {
        guard !isApplying else { return }
        if self.coordinator !== coordinator { clear(); self.coordinator = coordinator }
        scan?.cancel()
        let ticket = UUID(); request = ticket; isLoading = true; message = nil
        let task = Task { @MainActor [self] in
            defer { if request == ticket { isLoading = false } }
            do {
                let snapshots = try await coordinator.snapshots(kinds: [.recording])
                guard request == ticket, self.coordinator === coordinator, !Task.isCancelled else { return }
                items = []
                await withTaskGroup(of: [Item].self) { group in
                    group.addTask {
                        do {
                            return try await coordinator.reviewBootstrapProjections().map {
                                Item(id: $0.id, title: $0.filename == "library.json" ? "Library metadata" : "Summary templates", bootstrap: $0)
                            }
                        } catch {
                            return [Item(id: "bootstrap-inspection", title: "Library metadata and templates",
                                error: "These files could not be checked. Wait for sync, then reload.")]
                        }
                    }
                    for snapshot in snapshots where snapshot.state.lifecycle == .alive {
                        group.addTask {
                            let entity = SharedEntityIdentity(id: snapshot.state.id, kind: .recording)
                            do {
                                return try await coordinator.reviewSidecars(entity).map {
                                    Item(id: $0.id, title: $0.filename + " · " + $0.component.rawValue.capitalized, review: $0, error: nil)
                                }
                            } catch {
                                let title: String
                                if case .text(let value)? = snapshot.state.value(for: "title") ?? snapshot.state.value(for: "initialPath") { title = value }
                                else { title = "Recording" }
                                return [Item(id: entity.id.uuidString, title: title, review: nil,
                                    error: "This recording could not be checked. Wait for sync, resolve competing edits if needed, then reload.")]
                            }
                        }
                    }
                    for await entries in group {
                        guard request == ticket, self.coordinator === coordinator, !Task.isCancelled else { continue }
                        items.append(contentsOf: entries)
                        items.sort { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
                    }
                }
            } catch {
                if request == ticket, self.coordinator === coordinator { message = "Files could not be checked. Wait for sync, then reload." }
            }
        }
        scan = task
        await withTaskCancellationHandler(operation: { await task.value }, onCancel: { task.cancel() })
        if request == ticket { scan = nil }
    }

    func apply(_ item: Item, useChangedFile: Bool, using coordinator: SharedLibraryCoordinator) async -> Bool {
        guard self.coordinator === coordinator, !isApplying, item.review != nil || (item.bootstrap != nil && !useChangedFile) else { return false }
        // Consent belongs to the completed row; an unrelated pending scan
        // cannot disable it or later restore its stale choices.
        scan?.cancel(); scan = nil
        let ticket = UUID(); request = ticket
        isLoading = false; isApplying = true; message = nil
        defer { if request == ticket { isApplying = false } }
        let task = Task { @MainActor [self] in
            do {
                try Task.checkCancellation()
                guard request == ticket, self.coordinator === coordinator else { return false }
                var publicationFailed = false
                if let review = item.review {
                    let accepted = try await coordinator.recoverSidecar(review, useChangedFile: useChangedFile)
                    do { _ = try await coordinator.projectOutputs(for: .init(id: accepted.state.id, kind: accepted.state.kind), component: review.component) }
                    catch { publicationFailed = true }
                } else if let bootstrap = item.bootstrap {
                    _ = try await coordinator.restoreBootstrapProjection(bootstrap)
                }
                guard request == ticket, self.coordinator === coordinator else { return true }
                items.removeAll { $0.id == item.id }
                message = publicationFailed
                    ? "Choice saved. Files could not be updated yet. Reload and retry after sync finishes."
                    : (useChangedFile ? "Changed file accepted." : "Current content restored.")
                return true
            } catch {
                guard request == ticket, self.coordinator === coordinator else { return false }
                if error as? SharedLibraryCoordinatorError == .externalChanged || error as? SharedLibraryCoordinatorError == .staleReview || error as? SharedLibraryRepositoryError == .staleRevision {
                    message = "The file or recording changed during review. Reload before choosing."
                } else if error as? SharedLibraryCoordinatorError == .enrollmentPending { message = "Join this shared library before making changes." }
                else if !(error is CancellationError) { message = "The file could not be recovered. Reload and try again." }
                return false
            }
        }
        action = task
        let result = await task.value
        if request == ticket { action = nil }
        return result
    }
}
