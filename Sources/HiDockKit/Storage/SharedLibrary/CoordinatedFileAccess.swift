// © 2026 High Gain Design. All rights reserved.
import Foundation

/// Uses a fresh coordinator/queue per request, so a waiting file never owns a
/// library-wide serial queue. Accessor work must remain synchronous and finish
/// before returning; its resolved URL must not escape the coordinated scope.
public struct CoordinatedFileAccess: Sendable {
    public init() {}

    public struct Scope: Sendable {
        public let url: URL
        fileprivate let cancellation: Progress

        public func checkCancellation() throws {
            if cancellation.isCancelled { throw CancellationError() }
        }
    }

    // Foundation explicitly permits cancel() from any thread. All other access
    // to this coordinator belongs to its single request. There is no custom
    // shared mutable state or general-purpose unchecked actor replacement here.
    private final class Request: @unchecked Sendable {
        let coordinator = NSFileCoordinator()
        let cancellation = Progress(parent: nil, userInfo: nil)
        let intent: NSFileAccessIntent
        let queue = OperationQueue()

        init(url: URL, writing: Bool) {
            intent =
                writing
                ? .writingIntent(with: url, options: .forMerging)
                : .readingIntent(with: url, options: [])
            queue.maxConcurrentOperationCount = 1
            queue.qualityOfService = .userInitiated
        }

        func cancel() {
            cancellation.cancel()
            coordinator.cancel()
        }
    }

    public func read(at url: URL) async throws -> Data {
        guard try await RecordingFileAccess().waitUntilAvailable(at: url, knownToExist: true) else {
            throw CocoaError(.fileReadNoSuchFile)
        }
        let bytes = try await perform(at: url, writing: false) { scope in
            try scope.checkCancellation()
            let bytes = try Data(contentsOf: scope.url)
            try scope.checkCancellation()
            return bytes
        }
        try Task.checkCancellation()
        return bytes
    }

    /// Read a provider-owned promised/version URL through coordination directly.
    /// Its bytes need not exist locally before the provider grants this access.
    public func withRead<Output: Sendable>(
        at url: URL,
        accessor: @escaping @Sendable (Scope) throws -> Output
    ) async throws -> Output {
        let result = try await perform(at: url, writing: false, accessor: accessor)
        try Task.checkCancellation()
        return result
    }

    /// Check cancellation before committing a write. After its atomic commit
    /// point, return the accepted result even if cancellation raced with it;
    /// reporting a rollback that never happened would corrupt the caller's state.
    public func withWrite<Output: Sendable>(
        at url: URL,
        accessor: @escaping @Sendable (Scope) throws -> Output
    ) async throws -> Output {
        try await perform(at: url, writing: true, accessor: accessor)
    }

    private func perform<Output: Sendable>(
        at url: URL, writing: Bool,
        accessor: @escaping @Sendable (Scope) throws -> Output
    ) async throws -> Output {
        try Task.checkCancellation()
        let request = Request(url: url, writing: writing)
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                request.coordinator.coordinate(with: [request.intent], queue: request.queue) { error in
                    if let error {
                        let cocoa = error as NSError
                        if request.cancellation.isCancelled
                            || (cocoa.domain == NSCocoaErrorDomain && cocoa.code == NSUserCancelledError)
                        {
                            continuation.resume(throwing: CancellationError())
                        } else {
                            continuation.resume(throwing: error)
                        }
                        return
                    }
                    do {
                        let scope = Scope(url: request.intent.url, cancellation: request.cancellation)
                        try scope.checkCancellation()
                        continuation.resume(returning: try accessor(scope))
                    } catch {
                        continuation.resume(throwing: error)
                    }
                }
            }
        } onCancel: {
            request.cancel()
        }
    }
}
