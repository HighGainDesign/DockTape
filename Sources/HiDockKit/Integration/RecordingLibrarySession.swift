// © 2026 High Gain Design. All rights reserved.
import Foundation

public enum RecordingLibrarySessionError: Error, LocalizedError, Sendable {
    case enrollmentRequired, notShared
    public var errorDescription: String? {
        switch self {
        case .enrollmentRequired: return "This Mac has read-only access. Request shared-library access and let an enrolled Mac sync before importing or transcribing."
        case .notShared: return "This folder has not been enabled as a shared library."
        }
    }
}

/// CLI and other short-lived hosts use the same authority and local identity as
/// the app. Opening a legacy library never enables a shared format implicitly.
public struct RecordingLibrarySession: Sendable {
    public let recordings: RecordingStore
    public let transcripts: TranscriptStore
    public let pipeline: RecordingPipeline
    public let coordinator: SharedLibraryCoordinator?
    private let installation: SharedLibraryWriterIdentity?

    public static var defaultWitnessDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("DockTape/SharedLibraries/Witnesses")
    }
    public static func open(root: URL, enable: Bool = false, witnessDirectory: URL? = nil,
                            identity: @escaping @Sendable () async throws -> SharedLibraryWriterIdentity = { try await SharedWriterIdentityFactory().load() }) async throws -> Self {
        let root = root.standardizedFileURL.resolvingSymlinksInPath()
        let coordinator: SharedLibraryCoordinator?
        let writer: SharedLibraryWriterIdentity?
        if enable || FileManager.default.fileExists(atPath: root.appendingPathComponent(".docktape").path) {
            let installation = try await identity()
            writer = installation
            let candidate = SharedLibraryCoordinator(root: root, writerID: installation.writer,
                witnessDirectory: witnessDirectory ?? defaultWitnessDirectory)
            if enable { _ = try await candidate.enable() }
            // Validates schema/membership; failure must never fall back to legacy stores.
            _ = try await candidate.mayEdit()
            try await candidate.refresh()
            coordinator = candidate
        } else { coordinator = nil; writer = nil }
        let recordings = RecordingStore(baseDirectory: root, shared: coordinator.map { SharedRecordingMetadataAdapter(coordinator: $0) })
        let transcripts = TranscriptStore(baseDirectory: root, shared: coordinator.map { SharedSidecarAdapter(coordinator: $0) })
        let pipeline = RecordingPipeline(recordingStore: recordings, transcriptStore: transcripts, shared: coordinator)
        try await pipeline.setup()
        return .init(recordings: recordings, transcripts: transcripts, pipeline: pipeline, coordinator: coordinator, installation: writer)
    }
    /// Hosts call this before connecting a device or loading transcription models.
    public func requireWritable() async throws {
        if let coordinator, try await !coordinator.mayEdit() { throw RecordingLibrarySessionError.enrollmentRequired }
    }
    public func requestAccess() async throws {
        guard let coordinator, let installation else { throw RecordingLibrarySessionError.notShared }
        try await coordinator.requestEnrollment(requestID: installation.requestID, label: "Mac")
    }
    public func refresh() async throws {
        if let coordinator { try await coordinator.refresh() }
        try await pipeline.setup()
    }
}
