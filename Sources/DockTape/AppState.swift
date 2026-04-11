import SwiftUI
import HiDockKit

enum SidebarSelection: Hashable {
    case allRecordings
    case folder(String)
    case device
}

enum TranscriptStatus {
    case none
    case inProgress
    case done
    case failed
}

/// Thin coordinator that owns sub-state objects and handles cross-cutting actions.
@Observable
@MainActor
final class AppState {
    // var (not let) because SwiftUI @Bindable needs mutable keypaths through sub-objects
    var library: LibraryState
    var device: DeviceState
    var playback: PlaybackState
    var transcription: TranscriptionState
    var summarization: SummarizationState
    var templateStore: TemplateStore

    var selectedView: SidebarSelection = .allRecordings
    var selectedDetailTab: DetailPane.DetailTab = .info
    var triggerRename: Bool = false
    var errorMessage: String?
    var statusMessage: String = "No device connected"

    // Settings (persisted to UserDefaults)
    var autoDeleteAfterDownload: Bool = false {
        didSet { UserDefaults.standard.set(autoDeleteAfterDownload, forKey: "autoDeleteAfterDownload") }
    }
    var autoSyncClock: Bool = true {
        didSet { UserDefaults.standard.set(autoSyncClock, forKey: "autoSyncClock") }
    }

    private let monitor = USBDeviceMonitor()
    private var isConnecting: Bool = false
    private var pollingTask: Task<Void, Never>?

    init() {
        let customPath = UserDefaults.standard.url(forKey: "libraryLocation")
        let store = RecordingStore(baseDirectory: customPath)
        let transcriptStore = TranscriptStore(baseDirectory: store.baseDirectory)

        self.library = LibraryState(store: store, transcriptStore: transcriptStore)
        self.device = DeviceState()
        self.playback = PlaybackState()
        self.transcription = TranscriptionState(transcriptStore: transcriptStore)
        let summaryStore = SummaryStore(baseDirectory: store.baseDirectory)
        self.summarization = SummarizationState(summaryStore: summaryStore)
        self.templateStore = TemplateStore(baseDirectory: store.baseDirectory)

        self.autoDeleteAfterDownload = UserDefaults.standard.bool(forKey: "autoDeleteAfterDownload")
        self.autoSyncClock = UserDefaults.standard.object(forKey: "autoSyncClock") as? Bool ?? true
    }

    func setup() async throws {
        try await library.setup()
        try await summarization.summaryStore.loadAll()
        try? await templateStore.load()
        try? await templateStore.migrateFromUserDefaults(.standard)

        // Populate transcript statuses for recordings that already have transcripts on disk
        let transcribedFiles = await transcription.transcriptStore.allTranscribedFilenames()
        for filename in transcribedFiles {
            if transcription.statuses[filename] == nil {
                transcription.statuses[filename] = .done
            }
        }

        // Populate summary existence set
        let summarizedFiles = await summarization.summaryStore.allSummarizedFilenames()
        summarization.hasSummary = Set(summarizedFiles)
    }

    /// Refresh library, transcript statuses, and summary statuses from disk.
    /// Called on app activate to pick up external filesystem changes.
    func refreshAll() async {
        await library.refresh()
        try? await transcription.transcriptStore.loadAll()
        try? await summarization.summaryStore.loadAll()

        // Re-sync statuses from disk
        let transcribedFiles = await transcription.transcriptStore.allTranscribedFilenames()
        var newStatuses: [String: TranscriptStatus] = [:]
        for filename in transcribedFiles {
            newStatuses[filename] = .done
        }
        // Preserve in-progress statuses from current session
        for (file, status) in transcription.statuses where status == .inProgress {
            newStatuses[file] = .inProgress
        }
        transcription.statuses = newStatuses

        let summarizedFiles = await summarization.summaryStore.allSummarizedFilenames()
        summarization.hasSummary = Set(summarizedFiles)
    }

    // MARK: - Cross-cutting actions

    func downloadFile(_ file: FileEntry) async {
        do {
            try await device.downloadFile(file)
            await library.refresh()
            statusMessage = "Downloaded \(file.filename)"
        } catch {
            errorMessage = "Download failed: \(error.localizedDescription)"
        }
    }

    func syncAll() async {
        device.isSyncing = true
        do {
            let result = try await device.syncAll(
                deleteAfterDownload: autoDeleteAfterDownload
            ) { [weak self] progress in
                Task { @MainActor [weak self] in
                    self?.statusMessage = "Downloading \(progress.currentFile)..."
                }
            }
            device.isSyncing = false
            await library.refresh()

            if result.downloaded.isEmpty && result.failed.isEmpty {
                statusMessage = "Already up to date"
            } else {
                var msg = "Downloaded \(result.downloaded.count) file(s)"
                if !result.failed.isEmpty { msg += ", \(result.failed.count) failed" }
                statusMessage = msg
            }
        } catch {
            device.isSyncing = false
            errorMessage = error.localizedDescription
            statusMessage = "Sync failed"
        }
    }

    func deleteLocalRecording(_ rec: RecordingMetadata) async {
        if playback.playingFile == rec.filename {
            playback.stop()
        }
        do {
            try await library.deleteRecording(rec)
        } catch {
            errorMessage = "Delete failed: \(error.localizedDescription)"
        }
    }

    func deleteFromDevice(_ file: FileEntry) async {
        do {
            try await device.deleteFromDevice(file)
            statusMessage = "Deleted \(file.filename) from device"
        } catch {
            errorMessage = "Delete failed: \(error.localizedDescription)"
        }
    }

    func playRecording(_ rec: RecordingMetadata) {
        let url = library.store.baseDirectory.appendingPathComponent(rec.filename)
        playback.play(file: rec.filename, url: url)
    }

    func transcribeRecordings(_ recs: [RecordingMetadata]) async {
        let recsToSummarize = recs
        await transcription.transcribe(
            recordings: recs,
            baseDirectory: library.store.baseDirectory,
            onStatusMessage: { [weak self] msg in self?.statusMessage = msg },
            onError: { [weak self] msg in self?.errorMessage = msg },
            onComplete: { [weak self] in
                await self?.library.refresh()
                if let self,
                   UserDefaults.standard.bool(forKey: "autoSummarize") {
                    self.autoSummarizeRecordings(recsToSummarize)
                }
            }
        )
    }

    func summarizeRecordings(
        _ recs: [RecordingMetadata],
        template: Template,
        customPrompt: String? = nil,
        provider: any LLMProvider,
        model: String
    ) {
        summarization.summarize(
            recordings: recs,
            template: template,
            customPrompt: customPrompt,
            provider: provider,
            model: model,
            transcriptStore: transcription.transcriptStore,
            onError: { [weak self] msg in self?.errorMessage = msg },
            onComplete: {}
        )
    }

    /// Create an LLM provider from current Settings.
    private func makeSettingsProvider() -> (provider: any LLMProvider, model: String)? {
        let providerName = UserDefaults.standard.string(forKey: "aiProvider") ?? "anthropic"
        let apiKey = KeychainHelper.read(service: KeychainHelper.aiService, account: providerName) ?? ""

        if providerName != "custom" && apiKey.isEmpty { return nil }

        let baseURL = UserDefaults.standard.string(forKey: "aiCustomBaseURL") ?? "http://localhost:11434/v1"
        guard let provider = makeLLMProvider(name: providerName, apiKey: apiKey, baseURL: baseURL) else { return nil }

        let model: String
        if providerName == "custom" {
            model = UserDefaults.standard.string(forKey: "aiCustomModel") ?? ""
        } else {
            model = UserDefaults.standard.string(forKey: "aiModel") ?? "claude-sonnet-4-6"
        }

        return (provider, model)
    }

    /// Summarize with the default template for the recording's mode.
    func contextMenuSummarize(_ rec: RecordingMetadata) {
        guard let settings = makeSettingsProvider() else {
            errorMessage = "No API key configured. Go to Settings > AI to add one."
            return
        }

        Task {
            let template = await templateStore.defaultTemplate(forMode: rec.mode)
            summarizeRecordings([rec], template: template, provider: settings.provider, model: settings.model)
        }
    }

    /// Summarize with a specific template and optional custom prompt.
    func summarizeWithTemplate(_ rec: RecordingMetadata, template: Template, customPrompt: String? = nil) {
        guard let settings = makeSettingsProvider() else {
            errorMessage = "No API key configured. Go to Settings > AI to add one."
            return
        }
        summarizeRecordings([rec], template: template, customPrompt: customPrompt, provider: settings.provider, model: settings.model)
    }

    /// Auto-summarize recordings using Settings provider/model/template.
    private func autoSummarizeRecordings(_ recs: [RecordingMetadata]) {
        guard let settings = makeSettingsProvider() else { return }

        Task {
            let templateID = UserDefaults.standard.string(forKey: "autoSummarizeTemplate") ?? "meeting"
            for rec in recs {
                let template: Template
                if let stored = await templateStore.template(forID: templateID) {
                    template = stored
                } else {
                    template = await templateStore.defaultTemplate(forMode: rec.mode)
                }
                summarizeRecordings([rec], template: template, provider: settings.provider, model: settings.model)
            }
        }
    }

    func renameRecording(_ rec: RecordingMetadata, to name: String) async {
        do {
            let newFilename = try await library.renameRecording(rec, to: name)
            if playback.playingFile == rec.filename { playback.playingFile = newFilename }
            if transcription.transcribingFile == rec.filename { transcription.transcribingFile = newFilename }
            await summarization.summaryStore.rename(from: rec.filename, to: newFilename)
        } catch {
            errorMessage = "Rename failed: \(error.localizedDescription)"
        }
    }

    func updateSpeakerNames(for filename: String, names: [String: String]) async {
        do {
            try await library.updateSpeakerNames(for: filename, names: names)
        } catch {
            errorMessage = "Failed to save speaker names: \(error.localizedDescription)"
        }
    }

    // MARK: - Device Monitoring

    func startMonitoring() {
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
        guard !device.isConnected && !isConnecting else { return }
        isConnecting = true
        defer { isConnecting = false }

        await device.cleanup()
        statusMessage = "Connecting to \(usbDevice.model.rawValue)..."

        let delays: [Duration] = [.zero, .seconds(2), .seconds(3)]
        var lastError: Error?

        for (attempt, delay) in delays.enumerated() {
            if attempt > 0 {
                await device.cleanup()
                statusMessage = "Retrying connection (attempt \(attempt + 1)/\(delays.count))..."
                try? await Task.sleep(for: delay)
            }

            let model = DeviceModel(id: "\(usbDevice.vendorID):\(usbDevice.productID)", model: usbDevice.model)
            device.model = model

            do {
                let conn = USBConnection(vendorID: usbDevice.vendorID, productID: usbDevice.productID)
                try conn.open()
                device.usbConnection = conn

                let mgr = DeviceManager(device: model)
                await mgr.connect(via: conn)
                device.deviceManager = mgr
                device.syncEngine = SyncEngine(deviceManager: mgr, store: library.store)

                _ = try await mgr.queryDeviceInfo()
                _ = try await mgr.queryBattery()
                _ = try await mgr.queryCardInfo()
                _ = try await mgr.queryFileList()
                _ = try await mgr.querySettings()

                device.isConnected = true
                statusMessage = "\(model.model.rawValue) connected"
                errorMessage = nil

                if autoSyncClock { try? await mgr.syncTime() }
                startPolling()
                return
            } catch {
                lastError = error
            }
        }

        errorMessage = "Connection failed: \(lastError?.localizedDescription ?? "unknown error")"
        statusMessage = "Connection failed"
        await device.cleanup()
    }

    private func handleDeviceDisconnected() async {
        stopPolling()
        await device.cleanup()
        statusMessage = "Device disconnected"
        selectedView = .allRecordings
    }

    // MARK: - Polling

    private func startPolling() {
        stopPolling()
        pollingTask = Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(30))
                guard !Task.isCancelled, device.deviceManager != nil else { break }
                guard !device.isSyncing, device.downloadingFiles.isEmpty, !device.isFormattingCard else { continue }
                await device.refreshDevice()
                await library.refresh()
            }
        }
    }

    private func stopPolling() {
        pollingTask?.cancel()
        pollingTask = nil
    }

    // MARK: - Settings Actions

    func syncClock() async {
        do {
            try await device.syncClock()
            statusMessage = "Clock synced"
        } catch {
            errorMessage = "Clock sync failed: \(error.localizedDescription)"
        }
    }

    func formatCard() async {
        do {
            try await device.formatCard()
            statusMessage = "Card formatted"
        } catch {
            errorMessage = "Format failed: \(error.localizedDescription)"
        }
    }

    func updateDeviceSettings(_ settings: DeviceSettings) async {
        do {
            try await device.updateSettings(settings)
        } catch {
            errorMessage = "Settings update failed: \(error.localizedDescription)"
        }
    }

    func refreshDeviceTime() async {
        await device.refreshDeviceTime()
    }
}
