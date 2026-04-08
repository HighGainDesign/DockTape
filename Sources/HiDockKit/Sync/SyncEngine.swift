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
        public let skipped: [String]        // already downloaded
        public let failed: [(String, String)] // (filename, error description)
        public let deletedFromDevice: [String]
    }

    /// Get the list of files on the device that haven't been downloaded yet.
    public func pendingFiles() async throws -> [FileEntry] {
        let deviceFiles = try await deviceManager.queryFileList()
        var pending: [FileEntry] = []
        for file in deviceFiles {
            let alreadyHave = await store.isDownloaded(filename: file.filename)
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

        for file in deviceFiles {
            let alreadyHave = await store.isDownloaded(filename: file.filename)
            if alreadyHave {
                skipped.append(file.filename)
            } else {
                toDownload.append(file)
            }
        }

        let totalFiles = toDownload.count
        var downloaded: [RecordingMetadata] = []
        var failed: [(String, String)] = []
        var deleted: [String] = []

        // Download each new file
        for (i, file) in toDownload.enumerated() {
            try Task.checkCancellation()
            onProgress?(SyncProgress(phase: .downloading, currentFile: file.filename, fileIndex: i, totalFiles: totalFiles, bytesDownloaded: 0, bytesTotal: Int(file.size)))

            do {
                let hdaData = try await deviceManager.downloadFile(entry: file)

                onProgress?(SyncProgress(phase: .converting, currentFile: file.filename, fileIndex: i, totalFiles: totalFiles, bytesDownloaded: Int(file.size), bytesTotal: Int(file.size)))

                let meta = try await store.storeRecording(hdaData: hdaData, entry: file)
                downloaded.append(meta)

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

        return SyncResult(downloaded: downloaded, skipped: skipped, failed: failed, deletedFromDevice: deleted)
    }

    /// Download a single specific file.
    public func downloadFile(
        _ file: FileEntry,
        deleteAfterDownload: Bool = false,
        onProgress: (@Sendable (SyncProgress) -> Void)? = nil
    ) async throws -> RecordingMetadata {
        onProgress?(SyncProgress(phase: .downloading, currentFile: file.filename, fileIndex: 0, totalFiles: 1, bytesDownloaded: 0, bytesTotal: Int(file.size)))

        let hdaData = try await deviceManager.downloadFile(entry: file)

        onProgress?(SyncProgress(phase: .converting, currentFile: file.filename, fileIndex: 0, totalFiles: 1, bytesDownloaded: Int(file.size), bytesTotal: Int(file.size)))

        let meta = try await store.storeRecording(hdaData: hdaData, entry: file)

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
