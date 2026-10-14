// © 2026 High Gain Design. All rights reserved.
import Foundation

/// Foundation calls presenters on their operation queue. Mutable debounce state
/// belongs to an actor; this narrow NSObject bridge has only immutable fields.
/// Activation/full refresh remains required for changes made outside coordination.
public final class SharedLibraryChangeMonitor: NSObject, NSFilePresenter, @unchecked Sendable {
    public let presentedItemURL: URL?
    public let presentedItemOperationQueue: OperationQueue
    private let debounce: Debounce

    public init(root: URL, delay: Duration = .milliseconds(150), onChange: @escaping @Sendable () async -> Void) {
        presentedItemURL = root.standardizedFileURL.resolvingSymlinksInPath()
        presentedItemOperationQueue = OperationQueue()
        presentedItemOperationQueue.maxConcurrentOperationCount = 1
        debounce = Debounce(delay: delay, callback: onChange)
        super.init()
        NSFileCoordinator.addFilePresenter(self)
    }
    public func close() async {
        NSFileCoordinator.removeFilePresenter(self)
        await debounce.close()
    }
    deinit {
        NSFileCoordinator.removeFilePresenter(self)
        let debounce = self.debounce
        Task { await debounce.close() }
    }
    private func changed() {
        let debounce = self.debounce
        Task { await debounce.schedule() }
    }
    public func presentedItemDidChange() { changed() }
    public func presentedItemDidMove(to newURL: URL) { changed() }
    public func presentedItemDidChangeUbiquityAttributes(_ attributes: Set<URLResourceKey>) { changed() }
    public func presentedItemDidGain(_ version: NSFileVersion) { changed() }
    public func presentedItemDidLose(_ version: NSFileVersion) { changed() }
    public func presentedItemDidResolveConflict(_ version: NSFileVersion) { changed() }
    public func presentedSubitemDidAppear(at url: URL) { changed() }
    public func presentedSubitemDidChange(at url: URL) { changed() }
    public func presentedSubitem(at oldURL: URL, didMoveTo newURL: URL) { changed() }
    public func presentedSubitem(at url: URL, didGain version: NSFileVersion) { changed() }
    public func presentedSubitem(at url: URL, didLose version: NSFileVersion) { changed() }
    public func presentedSubitem(at url: URL, didResolveConflict version: NSFileVersion) { changed() }

    private actor Debounce {
        let delay: Duration
        let callback: @Sendable () async -> Void
        var active = true
        var pending: Task<Void, Never>?
        init(delay: Duration, callback: @escaping @Sendable () async -> Void) {
            self.delay = delay
            self.callback = callback
        }
        func schedule() {
            guard active else { return }
            pending?.cancel()
            let delay = self.delay
            let callback = self.callback
            pending = Task {
                do { try await Task.sleep(for: delay) } catch { return }
                guard !Task.isCancelled else { return }
                await callback()
            }
        }
        func close() {
            active = false
            pending?.cancel()
            pending = nil
        }
    }
}
