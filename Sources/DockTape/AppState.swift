// © 2026 High Gain Design. All rights reserved.

import SwiftUI
import HiDockKit
import HiDockKitUSB

// MARK: - AI Provider Configuration

/// Reads AI provider settings from UserDefaults + Keychain.
struct AIProviderConfig {
    let providerName: String
    let apiKey: String
    let baseURL: String
    let model: String

    static func fromUserDefaults(_ defaults: UserDefaults = .standard) -> AIProviderConfig {
        let name = defaults.string(forKey: "aiProvider") ?? "anthropic"
        let key = KeychainHelper.read(service: KeychainHelper.aiService, account: name) ?? ""
        let base = defaults.string(forKey: "aiCustomBaseURL") ?? "http://localhost:11434/v1"
        let model: String
        if name == "custom" {
            model = defaults.string(forKey: "aiCustomModel") ?? ""
        } else {
            model = defaults.string(forKey: "aiModel") ?? "claude-sonnet-4-6"
        }
        return AIProviderConfig(providerName: name, apiKey: key, baseURL: base, model: model)
    }

    func makeProvider() -> (any LLMProvider)? {
        if providerName != "custom" && apiKey.isEmpty { return nil }
        return makeLLMProvider(name: providerName, apiKey: apiKey, baseURL: baseURL)
    }
}

// MARK: - Sidebar & Detail Tab

enum SidebarSelection: Hashable {
    case allRecordings
    case folder(String)
    case device
}

enum DetailTab: String, CaseIterable {
    case info = "Info"
    case transcript = "Transcript"
    case summary = "Summary"
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
    var sharedLibrary: SharedLibraryState

    var selectedView: SidebarSelection = .allRecordings
    var selectedDetailTab: DetailTab = .info
    var triggerRename: Bool = false
    var triggerCustomPrompt: Bool = false
    var triggerMerge: Bool = false
    var mergeFilenames: [String] = []
    private var mergeReferences: [String: SharedRecordingReference] = [:]
    private var mergeLibraryRoot: URL?
    var showMergeDeletePrompt: Bool = false
    var showMigrationPrompt: Bool = false
    var syncProgress: Double? = nil  // 0.0–1.0 during sync, nil when idle
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
    private(set) var playbackTranscriptTask: Task<Void, Never>?
    private var playbackTranscriptRequestID = UUID()

    init(baseDirectory: URL? = nil,
         sharedIdentity: @escaping @Sendable () async throws -> SharedLibraryWriterIdentity = { try await SharedWriterIdentityFactory().load() },
         sharedWitnessDirectory: URL? = nil) {
        self.sharedLibrary = SharedLibraryState(identity: sharedIdentity, witnessDirectory: sharedWitnessDirectory)
        let defaults = UserDefaults.standard

        // One-time migration: determine storage mode for pre-iCloud installs
        let mode: StorageMode
        if let stored = defaults.string(forKey: "storageMode"),
           let parsed = StorageMode(rawValue: stored) {
            mode = parsed
        } else {
            // First launch after iCloud update — migrate
            let migrated = StorageLocationResolver.migratedMode(from: defaults)
            defaults.set(migrated.rawValue, forKey: "storageMode")
            mode = migrated

            // Show migration prompt if switching to iCloud but local recordings exist
            if migrated == .icloud && StorageLocationResolver.hasLocalRecordings {
                showMigrationPrompt = true
            }
        }

        // Resolve custom URL from security-scoped bookmark if available
        let customURL: URL?
        if mode == .custom, let bookmarkData = defaults.data(forKey: "libraryLocationBookmark") {
            var isStale = false
            if let resolved = try? URL(resolvingBookmarkData: bookmarkData, options: .withSecurityScope, relativeTo: nil, bookmarkDataIsStale: &isStale) {
                _ = resolved.startAccessingSecurityScopedResource()
                customURL = resolved
                // Refresh bookmark if stale
                if isStale, let fresh = try? resolved.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil) {
                    defaults.set(fresh, forKey: "libraryLocationBookmark")
                }
            } else {
                customURL = defaults.url(forKey: "libraryLocation")
            }
        } else {
            customURL = defaults.url(forKey: "libraryLocation")
        }
        let baseDir = baseDirectory ?? StorageLocationResolver.resolve(mode: mode, customURL: customURL)

        let store = RecordingStore(baseDirectory: baseDir)
        let transcriptStore = TranscriptStore(baseDirectory: store.baseDirectory)

        self.library = LibraryState(store: store, transcriptStore: transcriptStore)
        self.device = DeviceState()
        self.playback = PlaybackState()
        self.transcription = TranscriptionState(transcriptStore: transcriptStore)
        let summaryStore = SummaryStore(baseDirectory: store.baseDirectory)
        self.summarization = SummarizationState(summaryStore: summaryStore)
        self.templateStore = TemplateStore(baseDirectory: store.baseDirectory)

        self.autoDeleteAfterDownload = defaults.bool(forKey: "autoDeleteAfterDownload")
        self.autoSyncClock = defaults.object(forKey: "autoSyncClock") as? Bool ?? true
    }

    private func requireWritableLibrary() -> Bool {
        if sharedLibrary.phase == .ready { return true }
        if sharedLibrary.phase == .legacy,
           !FileManager.default.fileExists(atPath: library.store.baseDirectory.appendingPathComponent(".docktape").path) { return true }
        errorMessage = sharedLibrary.phase == .readOnly
            ? "This library is read-only. Join it in Settings and wait for the other Macs to connect."
            : "Wait for shared library setup to finish, or retry it in Settings."
        return false
    }

    func enableSharedLibrary() async -> Bool {
        guard !device.isDeviceBusy, !transcription.isTranscribing, !summarization.isSummarizing, !sharedLibrary.isBusy else {
            errorMessage = "Wait for the current operation to finish before enabling a shared library."
            return false
        }
        do {
            if let coordinator = try await sharedLibrary.connect(root: library.store.baseDirectory, enable: true) {
                attachSharedStores(coordinator)
            }
            try await setup()
            if let coordinator = sharedLibrary.coordinator { _ = try await coordinator.projectOutputs() }
            return true
        } catch { errorMessage = "Shared library setup failed: \(error.localizedDescription)"; return false }
    }

    private func attachSharedStores(_ coordinator: SharedLibraryCoordinator) {
        playback.stop()
        playback.acquireLease = { filename, url in
            let expected = coordinator.root.appendingPathComponent(filename).standardizedFileURL.resolvingSymlinksInPath()
            guard url.standardizedFileURL.resolvingSymlinksInPath() == expected else { throw SharedLibraryCoordinatorError.differentBinding }
            let view = try await coordinator.recording(at: filename)
            let token = try await coordinator.pinJob(.init(id: view.state.id, kind: .recording))
            return .init(validate: { try await coordinator.validateJob(token) }, release: { await coordinator.finishJob(token) })
        }
        let previous = library
        let store = RecordingStore(baseDirectory: coordinator.root, shared: SharedRecordingMetadataAdapter(coordinator: coordinator))
        let transcripts = TranscriptStore(baseDirectory: coordinator.root, shared: SharedSidecarAdapter(coordinator: coordinator))
        library = LibraryState(store: store, transcriptStore: transcripts, sharedCoordinator: coordinator)
        library.selectedFolder = previous.selectedFolder
        library.selectedRecording = previous.selectedRecording
        library.selectedRecordings = previous.selectedRecordings
        transcription = TranscriptionState(transcriptStore: transcripts, recordingStore: store, shared: coordinator)
        summarization = SummarizationState(summaryStore: SummaryStore(baseDirectory: coordinator.root, shared: SharedSidecarAdapter(coordinator: coordinator)), shared: coordinator)
        templateStore = TemplateStore(baseDirectory: coordinator.root, shared: SharedTemplateAdapter(coordinator: coordinator))
        if let manager = device.deviceManager { device.syncEngine = SyncEngine(deviceManager: manager, store: store) }
    }

    func setup() async throws {
        if let coordinator = try await sharedLibrary.connect(root: library.store.baseDirectory), library.sharedCoordinator !== coordinator {
            attachSharedStores(coordinator)
        }
        try await library.setup()
        try await summarization.summaryStore.loadAll()
        try await templateStore.load()
        if sharedLibrary.coordinator == nil { try await templateStore.migrateFromUserDefaults(.standard) }

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
        try await sharedLibrary.listen { [weak self] in await self?.refreshAll(refreshShared: false) }
    }

    /// Refresh library, transcript statuses, and summary statuses from disk.
    /// Called on app activate to pick up external filesystem changes.
    func refreshAll(refreshShared: Bool = true) async {
        let currentLibrary = library, currentTranscription = transcription, currentSummary = summarization
        let currentTemplates = templateStore, bound = sharedLibrary.coordinator
        func stillBound() -> Bool { library === currentLibrary && sharedLibrary.coordinator === bound }
        if let bound {
            do {
                if refreshShared { try await bound.refresh() }
                guard stillBound() else { return }
                try await sharedLibrary.refreshStatus()
                guard stillBound() else { return }
                try await currentTemplates.load()
                guard stillBound() else { return }
                if sharedLibrary.phase == .ready { _ = try await bound.projectOutputs() }
                guard stillBound() else { return }
                sharedLibrary.message = nil
            } catch { if stillBound() { sharedLibrary.message = error.localizedDescription } }
        }
        await currentLibrary.refresh()
        guard stillBound() else { return }
        if bound != nil { sharedLibrary.revision &+= 1 }
        try? await currentTranscription.transcriptStore.loadAll()
        try? await currentSummary.summaryStore.loadAll()
        guard stillBound() else { return }
        let transcribedFiles = await currentTranscription.transcriptStore.allTranscribedFilenames()
        guard stillBound() else { return }
        var newStatuses: [String: TranscriptStatus] = [:]
        for filename in transcribedFiles { newStatuses[filename] = .done }
        for (file, status) in currentTranscription.statuses where status == .inProgress { newStatuses[file] = .inProgress }
        currentTranscription.statuses = newStatuses
        let summarizedFiles = await currentSummary.summaryStore.allSummarizedFilenames()
        guard stillBound() else { return }
        currentSummary.hasSummary = Set(summarizedFiles)
    }

    /// Switch storage location and re-initialize all stores.
    /// Does NOT move files — the user manages that via Finder.
    @discardableResult
    func switchStorageLocation(to mode: StorageMode, customURL: URL? = nil) async -> Bool {
        guard !device.isDeviceBusy, !transcription.isTranscribing, !summarization.isSummarizing, !sharedLibrary.isBusy else {
            errorMessage = "Wait for the current operation to finish before changing storage."
            return false
        }
        // A pending cloud playback request belongs to the old library.
        playbackTranscriptRequestID = UUID()
        playbackTranscriptTask?.cancel()
        playbackTranscriptTask = nil
        playback.stop()
        playback.acquireLease = nil
        let defaults = UserDefaults.standard
        defaults.set(mode.rawValue, forKey: "storageMode")

        if mode == .custom, let url = customURL {
            defaults.set(url, forKey: "libraryLocation")
            if let bookmark = try? url.bookmarkData(options: .withSecurityScope,
                                                   includingResourceValuesForKeys: nil, relativeTo: nil) {
                defaults.set(bookmark, forKey: "libraryLocationBookmark")
            } else {
                defaults.removeObject(forKey: "libraryLocationBookmark")
            }
        }

        let baseDir = StorageLocationResolver.resolve(mode: mode, customURL: customURL)

        await sharedLibrary.close()
        let store = RecordingStore(baseDirectory: baseDir)
        let transcriptStore = TranscriptStore(baseDirectory: store.baseDirectory)

        self.library = LibraryState(store: store, transcriptStore: transcriptStore)
        self.transcription = TranscriptionState(transcriptStore: transcriptStore)
        let summaryStore = SummaryStore(baseDirectory: store.baseDirectory)
        self.summarization = SummarizationState(summaryStore: summaryStore)
        self.templateStore = TemplateStore(baseDirectory: store.baseDirectory)
        if let manager = device.deviceManager {
            device.syncEngine = SyncEngine(deviceManager: manager, store: store)
        }

        do {
            try await setup()
            return true
        } catch {
            errorMessage = "Failed to load library: \(error.localizedDescription)"
            return false
        }
    }

    /// Whether iCloud was requested but is currently unavailable.
    var isICloudUnavailable: Bool {
        let mode = UserDefaults.standard.string(forKey: "storageMode")
        return mode == "icloud" && !StorageLocationResolver.isICloudAvailable
    }

    // MARK: - Cross-cutting actions

    func downloadFile(_ file: FileEntry) async {
        guard requireWritableLibrary() else { return }
        do {
            let wasImported = library.isDownloaded(file.filename)
            let importDirectory = library.store.baseDirectory
            statusMessage = "Checking \(file.filename)…"
            let changed = try await device.downloadFile(file)
            if let changed, library.store.baseDirectory == importDirectory,
               playback.playingFile == changed.filename {
                playback.stop()
            }
            await library.refresh()
            if changed == nil {
                statusMessage = "Already imported — audio matches \(file.filename)"
            } else if wasImported {
                statusMessage = "Re-imported \(file.filename). Review its transcript and summary."
            } else {
                statusMessage = "Imported \(file.filename)"
            }
        } catch {
            errorMessage = "Import failed: \(error.localizedDescription)"
        }
    }

    func syncAll() async {
        guard requireWritableLibrary() else { return }
        let importDirectory = library.store.baseDirectory
        syncProgress = 0
        do {
            let result = try await device.syncAll(
                deleteAfterDownload: autoDeleteAfterDownload
            ) { [weak self] progress in
                Task { @MainActor [weak self] in
                    self?.statusMessage = "Importing \(progress.currentFile) (\(progress.fileIndex + 1)/\(progress.totalFiles))..."
                    self?.syncProgress = progress.overallFraction
                }
            }
            syncProgress = nil
            if library.store.baseDirectory == importDirectory, let filename = playback.playingFile,
               result.downloaded.contains(where: { $0.filename == filename }) {
                playback.stop()
            }
            await library.refresh()

            if result.downloaded.isEmpty && result.failed.isEmpty {
                statusMessage = "Already up to date"
            } else {
                var msg = "Imported \(result.downloaded.count) recording(s)"
                if !result.reimported.isEmpty { msg += ", \(result.reimported.count) repaired; review their transcripts and summaries" }
                if !result.failed.isEmpty { msg += ", \(result.failed.count) failed" }
                statusMessage = msg
                if !result.failed.isEmpty {
                    let details = result.failed.prefix(5).map { "\($0.0): \($0.1)" }.joined(separator: "\n")
                    let remaining = result.failed.count > 5 ? "\nAnd \(result.failed.count - 5) more file(s)." : ""
                    errorMessage = "Import All finished with \(result.failed.count) error(s).\n\n" + details + remaining
                }
            }
        } catch {
            syncProgress = nil
            errorMessage = "Sync failed: \(error.localizedDescription)"
            statusMessage = "Sync failed"
        }
    }

    func deleteLocalRecording(_ rec: RecordingMetadata) async {
        if playback.playingFile == rec.filename {
            playback.stop()
        }
        do {
            try await library.deleteRecording(rec)
            try? await summarization.summaryStore.delete(for: rec.filename)
            summarization.hasSummary.remove(rec.filename)
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
        playbackTranscriptRequestID = UUID()
        let request = playbackTranscriptRequestID
        playbackTranscriptTask?.cancel()
        playbackTranscriptTask = Task { [weak self] in
            await self?.refreshPlaybackTranscript(for: rec.filename, requestID: request)
        }
    }

    private func refreshPlaybackTranscript(for filename: String, requestID: UUID? = nil) async {
        let request = requestID ?? playbackTranscriptRequestID
        let readingLibrary = library
        let transcript = await readingLibrary.transcript(for: filename)
        guard library === readingLibrary, playbackTranscriptRequestID == request else { return }
        playback.setSegmentTimestamps(
            transcript?.segments.map { (start: $0.startTime, end: $0.endTime) } ?? [],
            for: filename
        )
    }

    func transcribeRecordings(_ recs: [RecordingMetadata]) async {
        guard requireWritableLibrary() else { return }
        let recsToSummarize = recs
        await transcription.transcribe(
            recordings: recs,
            baseDirectory: library.store.baseDirectory,
            onStatusMessage: { [weak self] msg in self?.statusMessage = msg },
            onError: { [weak self] msg in self?.errorMessage = msg },
            onComplete: { [weak self] in
                await self?.library.refresh()
                if let self, let filename = self.playback.playingFile {
                    await self.refreshPlaybackTranscript(for: filename)
                }
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
        guard requireWritableLibrary() else { return }
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
        let config = AIProviderConfig.fromUserDefaults()
        guard let provider = config.makeProvider() else { return nil }
        return (provider, config.model)
    }

    /// Summarize with the default template for the recording's mode.
    /// Auto-transcribes first if needed.
    func contextMenuSummarize(_ rec: RecordingMetadata) {
        guard makeSettingsProvider() != nil else {
            errorMessage = "No API key configured. Go to Settings > AI to add one."
            return
        }

        Task {
            let template = await templateStore.defaultTemplate(forMode: rec.mode)
            summarizeWithTemplate(rec, template: template)
        }
    }

    /// Summarize with a specific template and optional custom prompt.
    /// Auto-transcribes first if the recording has no transcript.
    func summarizeWithTemplate(_ rec: RecordingMetadata, template: Template, customPrompt: String? = nil) {
        guard requireWritableLibrary() else { return }
        guard let settings = makeSettingsProvider() else {
            errorMessage = "No API key configured. Go to Settings > AI to add one."
            return
        }

        let needsTranscript = (transcription.statuses[rec.filename] ?? .none) != .done

        if needsTranscript {
            // Transcribe first, then summarize on completion
            Task {
                await transcription.transcribe(
                    recordings: [rec],
                    baseDirectory: library.store.baseDirectory,
                    onStatusMessage: { [weak self] msg in self?.statusMessage = msg },
                    onError: { [weak self] msg in self?.errorMessage = msg },
                    onComplete: { [weak self] in
                        await self?.library.refresh()
                        self?.summarizeRecordings([rec], template: template, customPrompt: customPrompt, provider: settings.provider, model: settings.model)
                    }
                )
            }
        } else {
            summarizeRecordings([rec], template: template, customPrompt: customPrompt, provider: settings.provider, model: settings.model)
        }
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
        let originalSelection = library.selectedRecordings
        do {
            let newFilename = try await library.renameRecording(rec, to: name)
            try await didRelocateRecording(from: rec.filename, to: newFilename, originalSelection: originalSelection)
        } catch {
            errorMessage = "Rename failed: \(error.localizedDescription)"
        }
    }

    func moveRecording(_ rec: RecordingMetadata, toFolder folder: String?) async {
        let originalSelection = library.selectedRecordings
        do {
            let newFilename = try await library.moveRecording(filename: rec.filename, toFolder: folder)
            try await didRelocateRecording(from: rec.filename, to: newFilename, originalSelection: originalSelection)
        } catch {
            errorMessage = "Move failed: \(error.localizedDescription)"
        }
    }

    func renameFolder(from oldName: String, to newName: String) async {
        let affected = library.recordings.filter { $0.filename.hasPrefix(oldName + "/") }
        do {
            let actualName = try await library.renameFolder(from: oldName, to: newName)
            if selectedView == .folder(oldName) { selectedView = .folder(actualName) }
            for rec in affected {
                let newFilename = actualName + rec.filename.dropFirst(oldName.count)
                try await didRelocateRecording(from: rec.filename, to: newFilename,
                                                originalSelection: library.selectedRecordings)
            }
        } catch {
            errorMessage = "Folder rename failed: \(error.localizedDescription)"
        }
    }

    private func didRelocateRecording(from oldFilename: String, to newFilename: String,
                                      originalSelection: Set<String>) async throws {
        if playback.playingFile == oldFilename { playback.playingFile = newFilename }
        if transcription.transcribingFile == oldFilename { transcription.transcribingFile = newFilename }
        if sharedLibrary.coordinator == nil { try await summarization.summaryStore.rename(from: oldFilename, to: newFilename) }
        else { try await summarization.summaryStore.loadAll() }
        if let status = transcription.statuses.removeValue(forKey: oldFilename) {
            transcription.statuses[newFilename] = status
        }
        if summarization.hasSummary.remove(oldFilename) != nil {
            summarization.hasSummary.insert(newFilename)
        }
        if originalSelection.contains(oldFilename),
           library.selectedRecordings == originalSelection || library.selectedRecordings.isEmpty {
            library.selectedRecordings = Set(originalSelection.map {
                $0 == oldFilename ? newFilename : $0
            })
            if library.selectedRecordings.count == 1 { library.selectedRecording = newFilename }
        }
        if library.selectedRecording == oldFilename { library.selectedRecording = newFilename }
        if playback.playingFile == newFilename { await refreshPlaybackTranscript(for: newFilename) }
    }

    // MARK: - Merge Recordings

    /// Initiate merge flow for the currently selected recordings.
    func startMerge() {
        let selected = library.selectedRecordings
        guard selected.count >= 2 else {
            errorMessage = "Select at least 2 recordings to merge."
            return
        }
        // Sort by recorded date (earliest first)
        let sorted = library.recordings
            .filter { selected.contains($0.filename) }
            .sorted { ($0.recordedAt ?? .distantFuture) < ($1.recordedAt ?? .distantFuture) }
        mergeFilenames = sorted.map(\.filename)
        mergeReferences = Dictionary(uniqueKeysWithValues: sorted.compactMap { recording in
            recording.reference.map { (recording.filename, $0) }
        })
        mergeLibraryRoot = library.store.baseDirectory
        triggerMerge = true
    }

    /// Execute the merge with the given name. Called after the rename dialog.
    func executeMerge(as name: String) async {
        guard requireWritableLibrary() else { return }
        guard mergeFilenames.count >= 2 else { return }
        guard mergeLibraryRoot == library.store.baseDirectory else {
            errorMessage = "The library changed. Select the recordings to merge again."
            return
        }

        statusMessage = "Merging \(mergeFilenames.count) recordings..."
        do {
            let merged = try await library.store.mergeRecordings(filenames: mergeFilenames, as: name, references: mergeReferences)
            statusMessage = "Merged \(mergeFilenames.count) recordings into \(merged.filename)"
            await library.refresh()
            // Select the merged recording
            library.selectedRecordings = [merged.filename]
            // Prompt to delete originals
            showMergeDeletePrompt = true
        } catch {
            errorMessage = "Merge failed: \(error.localizedDescription)"
        }
    }

    func clearMergeSelection() {
        mergeFilenames = []; mergeReferences = [:]; mergeLibraryRoot = nil
    }

    /// Delete the original identities after a merge, even if names changed.
    func deleteMergeOriginals() async {
        guard requireWritableLibrary() else { return }
        guard mergeLibraryRoot == library.store.baseDirectory else {
            errorMessage = "The library changed. The original recordings were left in place."
            return
        }
        for original in mergeFilenames {
            do {
                let filename: String
                if let shared = sharedLibrary.coordinator {
                    guard let reference = mergeReferences[original] else { throw SharedLibraryCoordinatorError.staleJob }
                    filename = try await shared.resolve(reference)
                } else { filename = original }
                if playback.playingFile == filename { playback.stop() }
                try await library.store.deleteRecordingAndSidecars(filename: filename, reference: mergeReferences[original])
                if sharedLibrary.coordinator == nil {
                    try await transcription.transcriptStore.delete(for: filename)
                    try await summarization.summaryStore.delete(for: filename)
                }
                summarization.hasSummary.remove(filename)
            } catch {
                errorMessage = "Failed to delete \(original): \(error.localizedDescription)"
            }
        }
        clearMergeSelection()
        await library.refresh()
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
                try await conn.open()
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
