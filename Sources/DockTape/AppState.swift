import SwiftUI
import AVFoundation
import Combine
import HiDockKit

enum SidebarSelection: Hashable {
    case library
    case onDevice
}

/// Root application state shared across all views.
@Observable
@MainActor
final class AppState {
    var device: DeviceModel?
    var recordings: [RecordingMetadata] = []
    var transcriptStatuses: [String: TranscriptStatus] = [:]  // filename -> status
    var isConnected: Bool = false
    var statusMessage: String = "No device connected"
    var showDownloadProgress: Bool = false
    var downloadProgress: Double = 0
    var downloadFilename: String = ""
    var isSyncing: Bool = false
    var errorMessage: String?
    var selectedView: SidebarSelection = .library
    var isSearchFocused: Bool = false
    var showDeviceInfo: Bool = false

    // Per-file operation tracking
    var downloadingFiles: Set<String> = []
    var deletingFiles: Set<String> = []
    var transcribingFile: String?
    var transcriptionPhase: String = ""
    private var transcriptionTask: Task<Void, Never>?
    private var pollingTask: Task<Void, Never>?

    // Audio playback (AVPlayer streams the file — won't block UI on large recordings)
    var playingFile: String?
    var playbackProgress: Double = 0
    var playbackDuration: Double = 0
    var isPlaying: Bool = false
    var playbackRate: Float = 1.0
    private var avPlayer: AVPlayer?
    private var playbackTimer: Timer?
    private var endOfPlaybackObserver: NSObjectProtocol?

    // Transcription queue
    var transcriptionQueue: [RecordingMetadata] = []
    var transcriptionQueueIndex: Int = 0
    var transcriptionStartTime: Date?

    // Settings
    var autoDeleteAfterDownload: Bool = false
    var autoSyncClock: Bool = true

    let store: RecordingStore
    let transcriptStore: TranscriptStore
    private let monitor = USBDeviceMonitor()
    private var deviceManager: DeviceManager?
    private var syncEngine: SyncEngine?
    private var usbConnection: USBConnection?
    private var pipeline: RecordingPipeline?

    init() {
        let customPath = UserDefaults.standard.url(forKey: "libraryLocation")
        let store = RecordingStore(baseDirectory: customPath)
        self.store = store
        self.transcriptStore = TranscriptStore(baseDirectory: store.baseDirectory)
    }

    func setup() async throws {
        try await store.setup()
        try await transcriptStore.loadAll()
        await refreshRecordings()
    }

    func refreshRecordings() async {
        recordings = await store.allRecordings()
        // Reload transcripts from disk so we detect external additions/deletions
        try? await transcriptStore.loadAll()
        await refreshTranscriptStatuses()
    }

    func refreshTranscriptStatuses() async {
        var statuses: [String: TranscriptStatus] = [:]
        for rec in recordings {
            // Preserve in-progress/failed statuses from active transcription
            if let existing = transcriptStatuses[rec.filename],
               existing == .inProgress || existing == .failed {
                statuses[rec.filename] = existing
                continue
            }
            let has = await transcriptStore.hasTranscript(for: rec.filename)
            statuses[rec.filename] = has ? .done : TranscriptStatus.none
        }
        transcriptStatuses = statuses
    }

    // MARK: - Device Monitoring

    private var isConnecting: Bool = false

    func startMonitoring() {
        // Start IOKit hotplug monitor first (non-blocking) so it's ready for events
        monitor.start(
            onConnect: { [weak self] usbDevice in
                Task { @MainActor [weak self] in
                    try? await Task.sleep(for: .seconds(2))
                    await self?.handleDeviceConnected(usbDevice)
                }
            },
            onDisconnect: { [weak self] _ in
                Task { @MainActor [weak self] in
                    await self?.handleDeviceDisconnected()
                }
            }
        )
        // Also do an immediate scan in case the device is already connected.
        // IOKit's drain may also fire onConnect for existing devices, but the
        // guard in handleDeviceConnected prevents double-connecting.
        Task {
            let devices = USBDeviceMonitor.findConnectedDevices()
            if let first = devices.first {
                await handleDeviceConnected(first)
            }
        }
    }

    func stopMonitoring() {
        monitor.stop()
    }

    private func handleDeviceConnected(_ usbDevice: USBDeviceMonitor.USBDevice) async {
        guard !isConnected && !isConnecting else { return }
        isConnecting = true
        defer { isConnecting = false }

        await cleanupConnection()

        statusMessage = "Connecting to \(usbDevice.model.rawValue)..."

        // Retry with increasing delays — device may still be initializing after plug-in
        let delays: [Duration] = [.zero, .seconds(2), .seconds(3)]
        var lastError: Error?

        for (attempt, delay) in delays.enumerated() {
            if attempt > 0 {
                await cleanupConnection()
                statusMessage = "Retrying connection (attempt \(attempt + 1)/\(delays.count))..."
                try? await Task.sleep(for: delay)
            }

            let model = DeviceModel(id: "\(usbDevice.vendorID):\(usbDevice.productID)", model: usbDevice.model)
            device = model

            do {
                try await openAndQuery(usbDevice: usbDevice, model: model)
                errorMessage = nil  // Clear any prior error on success
                return
            } catch {
                lastError = error
            }
        }

        // All attempts failed
        errorMessage = "Connection failed: \(lastError?.localizedDescription ?? "unknown error")"
        statusMessage = "Connection failed"
        await cleanupConnection()
    }

    private func openAndQuery(usbDevice: USBDeviceMonitor.USBDevice, model: DeviceModel) async throws {
        let conn = USBConnection(vendorID: usbDevice.vendorID, productID: usbDevice.productID)
        try conn.open()
        usbConnection = conn

        let mgr = DeviceManager(device: model)
        await mgr.connect(via: conn)
        deviceManager = mgr
        syncEngine = SyncEngine(deviceManager: mgr, store: store)

        _ = try await mgr.queryDeviceInfo()
        _ = try await mgr.queryBattery()
        _ = try await mgr.queryCardInfo()
        _ = try await mgr.queryFileList()
        _ = try await mgr.querySettings()

        isConnected = true
        statusMessage = "\(model.model.rawValue) connected"

        if autoSyncClock {
            try? await mgr.syncTime()
        }

        startPolling()
    }

    private func handleDeviceDisconnected() async {
        await cleanupConnection()
        statusMessage = "Device disconnected"
        selectedView = .library
    }

    private func cleanupConnection() async {
        stopPolling()
        if let mgr = deviceManager {
            await mgr.disconnect()
        }
        await usbConnection?.close()
        deviceManager = nil
        syncEngine = nil
        usbConnection = nil
        device = nil
        isConnected = false
    }

    // MARK: - Sync All

    func syncAll() async {
        guard let engine = syncEngine else { return }
        isSyncing = true
        showDownloadProgress = true
        errorMessage = nil

        do {
            let result = try await engine.syncAll(
                deleteAfterDownload: autoDeleteAfterDownload
            ) { [weak self] progress in
                Task { @MainActor [weak self] in
                    self?.downloadFilename = progress.currentFile
                    self?.downloadProgress = progress.overallFraction
                }
            }

            showDownloadProgress = false
            isSyncing = false
            await refreshRecordings()

            if result.downloaded.isEmpty && result.failed.isEmpty {
                statusMessage = "Already up to date"
            } else {
                var msg = "Downloaded \(result.downloaded.count) file(s)"
                if !result.failed.isEmpty {
                    msg += ", \(result.failed.count) failed"
                }
                statusMessage = msg
            }
        } catch {
            showDownloadProgress = false
            isSyncing = false
            errorMessage = error.localizedDescription
            statusMessage = "Sync failed"
        }
    }

    // MARK: - Single File Download

    func downloadFile(_ file: FileEntry) async {
        guard let engine = syncEngine else { return }
        downloadingFiles.insert(file.filename)

        do {
            _ = try await engine.downloadFile(file)
            await refreshRecordings()
            statusMessage = "Downloaded \(file.filename)"
        } catch {
            errorMessage = "Download failed: \(error.localizedDescription)"
        }

        downloadingFiles.remove(file.filename)
    }

    // MARK: - Delete from Device

    func deleteFromDevice(_ file: FileEntry) async {
        guard let mgr = deviceManager else { return }
        deletingFiles.insert(file.filename)

        do {
            try await mgr.deleteFile(entry: file)
            // Refresh device file list
            _ = try await mgr.queryFileList()
            statusMessage = "Deleted \(file.filename) from device"
        } catch {
            errorMessage = "Delete failed: \(error.localizedDescription)"
        }

        deletingFiles.remove(file.filename)
    }

    // MARK: - Delete Local Recording

    func deleteLocalRecording(_ rec: RecordingMetadata) async {
        do {
            try await store.deleteRecording(filename: rec.filename)
            try await transcriptStore.delete(for: rec.filename)
            await refreshRecordings()
        } catch {
            errorMessage = "Delete failed: \(error.localizedDescription)"
        }
    }

    // MARK: - Play Recording

    /// Toggle play/pause — instant, no actor hop.
    func togglePlayPause() {
        guard let player = avPlayer else { return }
        if isPlaying {
            player.pause()
            isPlaying = false
        } else {
            player.rate = playbackRate
            isPlaying = true
        }
    }

    func playRecording(_ rec: RecordingMetadata) async {
        // If already playing this file, just toggle
        if playingFile == rec.filename, avPlayer != nil {
            togglePlayPause()
            return
        }

        // Stop current playback
        stopPlayback()

        // Compute URL directly — baseDirectory is nonisolated, no actor hop needed
        let url = store.baseDirectory.appendingPathComponent(rec.filename)

        let playerItem = AVPlayerItem(url: url)
        playerItem.preferredForwardBufferDuration = 2  // Only buffer 2s before starting
        let player = AVPlayer(playerItem: playerItem)
        player.automaticallyWaitsToMinimizeStalling = false  // Start playback immediately

        avPlayer = player
        playingFile = rec.filename
        isPlaying = true

        // Get duration once the asset is ready
        Task {
            if let duration = try? await playerItem.asset.load(.duration),
               duration.isNumeric {
                self.playbackDuration = CMTimeGetSeconds(duration)
            }
        }

        // Timer-based progress updates — fires reliably in .common mode
        // even when the window is not key
        playbackTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let player = self.avPlayer else { return }
                let time = CMTimeGetSeconds(player.currentTime())
                if time.isFinite {
                    self.playbackProgress = time
                }
            }
        }
        RunLoop.main.add(playbackTimer!, forMode: .common)

        // End-of-playback notification
        endOfPlaybackObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: playerItem,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.stopPlayback()
            }
        }

        player.rate = playbackRate
    }

    func stopPlayback() {
        playbackTimer?.invalidate()
        playbackTimer = nil
        if let obs = endOfPlaybackObserver {
            NotificationCenter.default.removeObserver(obs)
            endOfPlaybackObserver = nil
        }
        avPlayer?.pause()
        avPlayer = nil
        playingFile = nil
        isPlaying = false
        playbackProgress = 0
        playbackDuration = 0
    }

    func seekPlayback(to time: Double) {
        let cmTime = CMTime(seconds: time, preferredTimescale: 600)
        avPlayer?.seek(to: cmTime, toleranceBefore: .zero, toleranceAfter: .zero)
        playbackProgress = time
    }

    func setPlaybackRate(_ rate: Float) {
        playbackRate = rate
        if isPlaying {
            avPlayer?.rate = rate
        }
    }

    // MARK: - Rename Recording

    func renameRecording(_ rec: RecordingMetadata, to name: String) async {
        do {
            let oldFilename = rec.filename
            let newFilename = try await store.renameRecording(filename: oldFilename, to: name)
            // Re-key transcript cache
            await transcriptStore.rename(from: oldFilename, to: newFilename)
            // Update any active state referencing the old filename
            if playingFile == oldFilename { playingFile = newFilename }
            if transcribingFile == oldFilename { transcribingFile = newFilename }
            if let status = transcriptStatuses.removeValue(forKey: oldFilename) {
                transcriptStatuses[newFilename] = status
            }
            await refreshRecordings()
        } catch {
            errorMessage = "Rename failed: \(error.localizedDescription)"
        }
    }

    // MARK: - Reveal in Finder

    func revealInFinder(_ rec: RecordingMetadata) {
        let url = store.baseDirectory.appendingPathComponent(rec.filename)
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    // MARK: - Transcription

    func transcribeRecordings(_ recs: [RecordingMetadata]) async {
        // Append to queue (skip duplicates already queued)
        let existingFilenames = Set(transcriptionQueue.map(\.filename))
        let newRecs = recs.filter { !existingFilenames.contains($0.filename) }
        transcriptionQueue.append(contentsOf: newRecs)

        // Mark newly queued items as in-progress
        for rec in newRecs {
            transcriptStatuses[rec.filename] = .inProgress
        }

        // If a transcription task is already running, it will pick up the new items
        guard transcriptionTask == nil else { return }

        transcriptionStartTime = Date()

        let task = Task {
            do {
                if pipeline == nil {
                    transcriptionPhase = "Loading models (first time takes ~1 min)..."
                    statusMessage = transcriptionPhase
                    pipeline = RecordingPipeline(baseDirectory: store.baseDirectory)
                    try await pipeline!.setup()
                }

                // Drain the queue — new items may be appended while we're running
                while transcriptionQueueIndex < transcriptionQueue.count {
                    try Task.checkCancellation()

                    let index = transcriptionQueueIndex
                    let rec = transcriptionQueue[index]
                    let total = transcriptionQueue.count

                    await MainActor.run {
                        transcribingFile = rec.filename
                        transcriptStatuses[rec.filename] = .inProgress
                        transcriptionStartTime = Date()
                        let progress = total > 1 ? " (\(index + 1)/\(total))" : ""
                        transcriptionPhase = "Transcribing\(progress)..."
                        statusMessage = "Transcribing \(rec.filename)\(progress)..."
                    }

                    // Delete existing transcript if re-transcribing
                    try? await transcriptStore.delete(for: rec.filename)

                    let transcript = try await pipeline!.transcribeRecording(filename: rec.filename)

                    try Task.checkCancellation()

                    // Pipeline saved to disk via its own store; update our cache too
                    try? await transcriptStore.save(transcript, mp3Filename: rec.filename)
                    await MainActor.run {
                        transcriptStatuses[rec.filename] = .done
                        transcriptionQueueIndex += 1
                    }
                }

                await MainActor.run {
                    let count = transcriptionQueue.count
                    statusMessage = count == 1 ? "Transcription complete" : "Transcribed \(count) recordings"
                    transcribingFile = nil
                    transcriptionPhase = ""
                    transcriptionQueue = []
                    transcriptionQueueIndex = 0
                    transcriptionStartTime = nil
                    transcriptionTask = nil
                }
            } catch is CancellationError {
                await MainActor.run {
                    if let file = transcribingFile {
                        transcriptStatuses[file] = TranscriptStatus.none
                    }
                    statusMessage = "Transcription cancelled"
                    transcribingFile = nil
                    transcriptionPhase = ""
                    transcriptionQueue = []
                    transcriptionQueueIndex = 0
                    transcriptionStartTime = nil
                    transcriptionTask = nil
                }
            } catch {
                await MainActor.run {
                    if let file = transcribingFile {
                        transcriptStatuses[file] = .failed
                    }
                    errorMessage = "Transcription failed: \(error.localizedDescription)"
                    statusMessage = "Transcription failed"
                    transcribingFile = nil
                    transcriptionPhase = ""
                    transcriptionQueue = []
                    transcriptionQueueIndex = 0
                    transcriptionStartTime = nil
                    transcriptionTask = nil
                }
            }
        }
        transcriptionTask = task
    }

    func transcribeRecording(_ rec: RecordingMetadata) async {
        await transcribeRecordings([rec])
    }

    func cancelTranscription() {
        transcriptionTask?.cancel()
        transcriptionTask = nil
        // Reset status for the current file and any remaining queued items
        if let file = transcribingFile {
            transcriptStatuses[file] = TranscriptStatus.none
        }
        for rec in transcriptionQueue.dropFirst(transcriptionQueueIndex + 1) {
            transcriptStatuses[rec.filename] = TranscriptStatus.none
        }
        transcribingFile = nil
        transcriptionPhase = ""
        transcriptionQueue = []
        transcriptionQueueIndex = 0
        transcriptionStartTime = nil
        statusMessage = "Transcription cancelled"
    }

    func viewTranscript(for rec: RecordingMetadata) async -> Transcript? {
        await transcriptStore.transcript(for: rec.filename)
    }

    func updateSpeakerNames(for filename: String, names: [String: String]) async {
        do {
            // Detect speakers that were given the same name → merge them
            var nameToIDs: [String: [String]] = [:]
            for (sid, name) in names {
                nameToIDs[name, default: []].append(sid)
            }

            for (_, ids) in nameToIDs where ids.count > 1 {
                let sorted = ids.sorted()
                let targetID = sorted[0]
                for sourceID in sorted.dropFirst() {
                    try await transcriptStore.mergeSpeakers(
                        for: filename, source: sourceID, into: targetID)
                }
            }

            // Update remaining names (merge already removed merged IDs)
            let current = await transcriptStore.transcript(for: filename)
            if let current {
                var finalNames: [String: String] = [:]
                for sid in current.speakerIDs {
                    finalNames[sid] = names[sid] ?? sid
                }
                try await transcriptStore.updateSpeakerNames(for: filename, names: finalNames)
            }
        } catch {
            errorMessage = "Failed to save speaker names: \(error.localizedDescription)"
        }
    }

    // MARK: - Format Card

    var isFormattingCard: Bool = false

    func formatCard() async {
        guard let mgr = deviceManager else { return }
        isFormattingCard = true
        do {
            try await mgr.formatCard()
            statusMessage = "Card formatted"
        } catch {
            errorMessage = "Format failed: \(error.localizedDescription)"
        }
        isFormattingCard = false
    }

    // MARK: - Clock Sync

    func syncClock() async {
        guard let mgr = deviceManager else { return }
        do {
            try await mgr.syncTime()
            // Re-query so deviceTime reflects the newly synced time
            _ = try? await mgr.queryTime()
            statusMessage = "Clock synced"
        } catch {
            errorMessage = "Clock sync failed: \(error.localizedDescription)"
        }
    }

    func refreshDeviceTime() async {
        guard let mgr = deviceManager else { return }
        _ = try? await mgr.queryTime()
    }

    // MARK: - Device Settings

    func updateDeviceSettings(_ settings: DeviceSettings) async {
        guard let mgr = deviceManager else { return }
        do {
            try await mgr.updateSettings(settings)
        } catch {
            errorMessage = "Settings update failed: \(error.localizedDescription)"
        }
    }

    // MARK: - Device Status Polling

    private func startPolling() {
        stopPolling()
        pollingTask = Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(30))
                guard !Task.isCancelled, let mgr = deviceManager else { break }
                // Skip polling during active file transfers to avoid contention
                guard !isSyncing, downloadingFiles.isEmpty, !isFormattingCard else { continue }
                _ = try? await mgr.queryBattery()
                _ = try? await mgr.queryCardInfo()
                _ = try? await mgr.queryFileList()
                await refreshRecordings()
            }
        }
    }

    private func stopPolling() {
        pollingTask?.cancel()
        pollingTask = nil
    }

    /// Manual refresh of device state (file list, battery, storage).
    func refreshDevice() async {
        guard let mgr = deviceManager else { return }
        _ = try? await mgr.queryBattery()
        _ = try? await mgr.queryCardInfo()
        _ = try? await mgr.queryFileList()
    }

    // MARK: - Helpers

    func isDownloaded(_ filename: String) -> Bool {
        let mp3Name = filename.hasSuffix(".hda")
            ? filename.replacingOccurrences(of: ".hda", with: ".mp3")
            : filename
        return recordings.contains { $0.filename == mp3Name }
    }
}

enum TranscriptStatus {
    case none
    case inProgress
    case done
    case failed
}
