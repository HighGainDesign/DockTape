// © 2026 High Gain Design. All rights reserved.

import SwiftUI
import HiDockKit
import HiDockKitUSB

/// Device connection and file management state.
@Observable
@MainActor
final class DeviceState {
    var model: DeviceModel?
    var isConnected: Bool = false
    var statusMessage: String = "No device connected"
    var downloadingFiles: Set<String> = []
    var deletingFiles: Set<String> = []
    var selectedDeviceFile: String? = nil
    var selectedDeviceFiles: Set<String> = []
    var showDeviceInfo: Bool = false
    var isSyncing: Bool = false
    var isFormattingCard: Bool = false

    var deviceManager: DeviceManager?
    var syncEngine: SyncEngine?
    var usbConnection: USBConnection?

    var files: [FileEntry] {
        model?.files ?? []
    }

    /// Whether any device operation is in flight (download, delete, sync, format).
    var isDeviceBusy: Bool {
        !downloadingFiles.isEmpty || !deletingFiles.isEmpty || isSyncing || isFormattingCard
    }

    private func guardNotBusy() throws {
        if isDeviceBusy {
            throw HiDockError.transferFailed("Device is busy — wait for the current operation to finish.")
        }
    }

    func refreshDevice() async {
        guard let mgr = deviceManager, !isDeviceBusy else { return }
        _ = try? await mgr.queryBattery()
        _ = try? await mgr.queryCardInfo()
        _ = try? await mgr.queryFileList()
    }

    func downloadFile(_ file: FileEntry) async throws -> RecordingMetadata? {
        guard let engine = syncEngine else { throw HiDockError.noDevice }
        try guardNotBusy()
        downloadingFiles.insert(file.filename)
        defer { downloadingFiles.remove(file.filename) }
        return try await engine.downloadFile(file)
    }

    func deleteFromDevice(_ file: FileEntry) async throws {
        guard let mgr = deviceManager else { return }
        try guardNotBusy()
        deletingFiles.insert(file.filename)
        defer { deletingFiles.remove(file.filename) }
        try await mgr.deleteFile(entry: file)
        _ = try await mgr.queryFileList()
    }

    func syncAll(
        deleteAfterDownload: Bool,
        onProgress: @escaping @Sendable (SyncEngine.SyncProgress) -> Void
    ) async throws -> SyncEngine.SyncResult {
        guard let engine = syncEngine else {
            throw HiDockError.transferFailed("No sync engine")
        }
        try guardNotBusy()
        isSyncing = true
        defer { isSyncing = false }
        return try await engine.syncAll(deleteAfterDownload: deleteAfterDownload, onProgress: onProgress)
    }

    func syncClock() async throws {
        guard let mgr = deviceManager else { return }
        try guardNotBusy()
        try await mgr.syncTime()
        _ = try? await mgr.queryTime()
    }

    func formatCard() async throws {
        guard let mgr = deviceManager else { return }
        try guardNotBusy()
        isFormattingCard = true
        defer { isFormattingCard = false }
        try await mgr.formatCard()
    }

    func updateSettings(_ settings: DeviceSettings) async throws {
        guard let mgr = deviceManager else { return }
        try guardNotBusy()
        try await mgr.updateSettings(settings)
    }

    func refreshDeviceTime() async {
        guard let mgr = deviceManager, !isDeviceBusy else { return }
        _ = try? await mgr.queryTime()
    }

    func cleanup() async {
        if let mgr = deviceManager {
            await mgr.disconnect()
        }
        await usbConnection?.close()
        deviceManager = nil
        syncEngine = nil
        usbConnection = nil
        model = nil
        isConnected = false
    }
}
