// © 2026 High Gain Design. All rights reserved.

import Foundation

/// Orchestrates file synchronization between a HiDock device and local storage.
/// Handles: scan → diff → download → convert → optionally delete from device.
///
/// Usage:
///   let engine = SyncEngine(deviceManager: mgr, store: store)
///   let results = try await engine.syncAll(deleteAfterDownload: false) { progress in
///       print("Progress: \(progress)")
///   }
public actor SyncEngine {
    private let deviceManager: DeviceManager
    private let store: RecordingStore

    public init(deviceManager: DeviceManager, store: RecordingStore) {
        self.deviceManager = deviceManager
        self.store = store
    }

    /// Progress update sent during sync operations.
    public struct SyncProgress: Sendable {
        public let phase: Phase
        public let currentFile: String
        public let fileIndex: Int       // 0-based
        public let totalFiles: Int
        public let bytesDownloaded: Int
        public let bytesTotal: Int

        public enum Phase: Sendable {
            case scanning
            case downloading
            case converting
            case deleting
            case complete
        }

        public var overallFraction: Double {
            guard totalFiles > 0 else { return 0 }
            let fileFraction = bytesTotal > 0 ? Double(bytesDownloaded) / Double(bytesTotal) : 1.0
            return (Double(fileIndex) + fileFraction) / Double(totalFiles)
        }
    }

    /// Result of a sync operation.
    public struct SyncResult: Sendable {
        public let downloaded: [RecordingMetadata]
        public let skipped: [String]        // verified identical audio
        public let reimported: [String]     // existing audio repaired in place
        public let failed: [(String, String)] // (filename, error description)
        public let deletedFromDevice: [String]
    }

    /// Get the list of files on the device that haven't been downloaded yet.
    public func pendingFiles() async throws -> [FileEntry] {
        let deviceFiles = try await deviceManager.queryFileList()
        var pending: [FileEntry] = []
        for file in deviceFiles {
            let alreadyHave = try await store.matchesVerifiedImport(file)
            if !alreadyHave {
                pending.append(file)
            }
        }
        return pending
    }

    /// Sync all new files from the device.
    public func syncAll(
        deleteAfterDownload: Bool = false,
        onProgress: (@Sendable (SyncProgress) -> Void)? = nil
    ) async throws -> SyncResult {
        // Scan
        onProgress?(SyncProgress(phase: .scanning, currentFile: "", fileIndex: 0, totalFiles: 0, bytesDownloaded: 0, bytesTotal: 0))

        let deviceFiles = try await deviceManager.queryFileList()
        var toDownload: [FileEntry] = []
        var skipped: [String] = []
        var failed: [(String, String)] = []

        for file in deviceFiles {
            try Task.checkCancellation()
            do {
                if try await store.matchesVerifiedImport(file) {
                    skipped.append(file.filename)
                } else {
                    toDownload.append(file)
                }
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                failed.append((file.filename, error.localizedDescription))
            }
        }

        let totalFiles = toDownload.count
        var downloaded: [RecordingMetadata] = []
        var reimported: [String] = []
        var deleted: [String] = []

        // Download each new file
        for (i, file) in toDownload.enumerated() {
            try Task.checkCancellation()
            onProgress?(SyncProgress(phase: .downloading, currentFile: file.filename, fileIndex: i, totalFiles: totalFiles, bytesDownloaded: 0, bytesTotal: Int(file.size)))

            do {
                let wasImported = await store.isDownloaded(filename: file.filename)
                let hdaData = try await deviceManager.downloadFile(entry: file)

                onProgress?(SyncProgress(phase: .converting, currentFile: file.filename, fileIndex: i, totalFiles: totalFiles, bytesDownloaded: Int(file.size), bytesTotal: Int(file.size)))

                guard let meta = try await store.importRecording(hdaData: hdaData, entry: file) else {
                    skipped.append(file.filename)
                    continue
                }
                downloaded.append(meta)
                if wasImported { reimported.append(meta.filename) }

                if deleteAfterDownload {
                    onProgress?(SyncProgress(phase: .deleting, currentFile: file.filename, fileIndex: i, totalFiles: totalFiles, bytesDownloaded: Int(file.size), bytesTotal: Int(file.size)))
                    try await deviceManager.deleteFile(entry: file)
                    deleted.append(file.filename)
                }
            } catch {
                failed.append((file.filename, error.localizedDescription))
            }
        }

        onProgress?(SyncProgress(phase: .complete, currentFile: "", fileIndex: totalFiles, totalFiles: totalFiles, bytesDownloaded: 0, bytesTotal: 0))

        return SyncResult(downloaded: downloaded, skipped: skipped, reimported: reimported, failed: failed, deletedFromDevice: deleted)
    }

    /// Import one file; nil means verified identical audio was skipped.
    /// Unknown source checksums require a transfer before comparing MP3 bytes.
    public func downloadFile(
        _ file: FileEntry,
        deleteAfterDownload: Bool = false,
        onProgress: (@Sendable (SyncProgress) -> Void)? = nil
    ) async throws -> RecordingMetadata? {
        if try await store.matchesVerifiedImport(file) { return nil }
        onProgress?(SyncProgress(phase: .downloading, currentFile: file.filename, fileIndex: 0, totalFiles: 1, bytesDownloaded: 0, bytesTotal: Int(file.size)))

        let hdaData = try await deviceManager.downloadFile(entry: file)

        onProgress?(SyncProgress(phase: .converting, currentFile: file.filename, fileIndex: 0, totalFiles: 1, bytesDownloaded: Int(file.size), bytesTotal: Int(file.size)))

        guard let meta = try await store.importRecording(hdaData: hdaData, entry: file) else { return nil }

        if deleteAfterDownload {
            onProgress?(SyncProgress(phase: .deleting, currentFile: file.filename, fileIndex: 0, totalFiles: 1, bytesDownloaded: Int(file.size), bytesTotal: Int(file.size)))
            try await deviceManager.deleteFile(entry: file)
        }

        onProgress?(SyncProgress(phase: .complete, currentFile: file.filename, fileIndex: 1, totalFiles: 1, bytesDownloaded: 0, bytesTotal: 0))

        return meta
    }

    /// Delete files from the device (bulk).
    public func deleteFromDevice(_ files: [FileEntry]) async throws -> [String] {
        var deleted: [String] = []
        for file in files {
            try await deviceManager.deleteFile(entry: file)
            deleted.append(file.filename)
        }
        return deleted
    }
}
