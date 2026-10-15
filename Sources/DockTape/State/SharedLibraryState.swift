// © 2026 High Gain Design. All rights reserved.
import Foundation
import Observation
import HiDockKit

/// One binding per selected library. Metadata enablement and writer enrollment
/// are explicit; ordinary legacy libraries do not acquire an installation ID.
@Observable
@MainActor
final class SharedLibraryState {
    enum Phase { case legacy, connecting, ready, readOnly, failed }
    private(set) var coordinator: SharedLibraryCoordinator?
    private(set) var root: URL?
    private(set) var phase: Phase = .legacy
    let review = SharedLibraryReviewState()
    var showsReview = false
    var revision: UInt64 = 0
    var message: String?
    var isBusy: Bool { phase == .connecting }
    private let identity: @Sendable () async throws -> SharedLibraryWriterIdentity
    private let witnessDirectory: URL
    private let trash: @Sendable (URL) throws -> Void
    private var installation: SharedLibraryWriterIdentity?
    private var request = UUID()
    private var eventsTask: Task<Void, Never>?
    private var refreshTask: Task<Void, Never>?

    init(identity: @escaping @Sendable () async throws -> SharedLibraryWriterIdentity, witnessDirectory: URL?,
         trash: @escaping @Sendable (URL) throws -> Void = { try SharedLibraryMaterializer.moveToTrash($0) }) {
        self.identity = identity
        self.trash = trash
        self.witnessDirectory = witnessDirectory ?? RecordingLibrarySession.defaultWitnessDirectory
    }
    func connect(root: URL, enable: Bool = false) async throws -> SharedLibraryCoordinator? {
        let target = root.standardizedFileURL.resolvingSymlinksInPath()
        if self.root == target, let coordinator, !enable { return coordinator }
        await close()
        let token = UUID(); request = token; self.root = target
        guard enable || FileManager.default.fileExists(atPath: target.appendingPathComponent(".docktape").path) else { return nil }
        phase = .connecting; message = nil
        do {
            let writer = try await identity()
            guard request == token, !Task.isCancelled else { throw CancellationError() }
            let candidate = SharedLibraryCoordinator(root: target, writerID: writer.writer, witnessDirectory: witnessDirectory, trash: trash)
            if enable { _ = try await candidate.enable() }
            let writable = try await candidate.mayEdit()
            guard request == token, !Task.isCancelled else { throw CancellationError() }
            installation = writer; coordinator = candidate
            phase = writable ? .ready : .readOnly
            revision &+= 1
            return candidate
        } catch {
            if request == token { phase = .failed; message = error.localizedDescription }
            throw error
        }
    }
    func refreshStatus() async throws {
        guard let coordinator else { return }
        let writable = try await coordinator.mayEdit()
        guard self.coordinator === coordinator else { return }
        phase = writable ? .ready : .readOnly
    }
    func requestAccess() async throws {
        guard let coordinator, let installation else { return }
        try await coordinator.requestEnrollment(requestID: installation.requestID, label: "Mac")
        try await refreshStatus()
    }
    func listen(onChange: @escaping @MainActor () async -> Void) async throws {
        guard let coordinator, eventsTask == nil else { return }
        let events = await coordinator.events()
        try await coordinator.startMonitoring()
        eventsTask = Task { [weak self] in
            for await event in events {
                guard !Task.isCancelled, let self, self.coordinator === coordinator else { break }
                switch event {
                case .loading: continue
                case .failure(let text): self.message = text
                case .entity:
                    self.refreshTask?.cancel()
                    self.refreshTask = Task { [weak self] in
                        do { try await Task.sleep(for: .milliseconds(150)) } catch { return }
                        guard let self, self.coordinator === coordinator, !Task.isCancelled else { return }
                        await onChange()
                    }
                }
            }
        }
    }
    func close() async {
        review.clear(); showsReview = false
        request = UUID()
        eventsTask?.cancel(); eventsTask = nil
        refreshTask?.cancel(); refreshTask = nil
        let previous = coordinator
        coordinator = nil; installation = nil; root = nil; phase = .legacy; message = nil
        revision &+= 1
        await previous?.stopMonitoring()
    }
}
