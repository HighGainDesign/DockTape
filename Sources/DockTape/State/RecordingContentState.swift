// © 2026 High Gain Design. All rights reserved.

import Foundation
import Observation

/// Selection-scoped state: a late cloud response cannot replace newer content.
@Observable
@MainActor
final class RecordingContentState<Content: Sendable> {
    private(set) var filename: String?
    private(set) var content: Content?
    private(set) var isLoading = false
    private(set) var isDownloading = false
    private(set) var errorMessage: String?
    private var requestID = UUID()

    func load(for filename: String,
              using loader: (@escaping @Sendable () async -> Void) async throws -> Content?) async {
        guard !Task.isCancelled else { return }
        let request = UUID()
        requestID = request
        self.filename = filename
        content = nil
        errorMessage = nil
        isDownloading = false
        isLoading = true
        do {
            let loaded = try await loader { [weak self] in
                await self?.markDownloading(for: request)
            }
            guard !Task.isCancelled, requestID == request else { return }
            content = loaded
            isLoading = false
            isDownloading = false
        } catch {
            guard requestID == request else { return }
            isLoading = false
            isDownloading = false
            if !Task.isCancelled, !(error is CancellationError) {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func markDownloading(for request: UUID) {
        guard requestID == request else { return }
        isDownloading = true
    }
}
