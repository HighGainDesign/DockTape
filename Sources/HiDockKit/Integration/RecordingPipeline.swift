// © 2026 High Gain Design. All rights reserved.

import Foundation

/// End-to-end pipeline: download files from device → convert HDA → transcribe + diarize.
/// Used by both the SwiftUI app and CLI. All state is managed internally.
public actor RecordingPipeline {
    private let recordingStore: RecordingStore
    private let transcriptStore: TranscriptStore

    private var transcriber: (any TranscriptionEngine)?
    private var diarizer: (any DiarizationEngine)?
    private let shared: SharedLibraryCoordinator?
    private let usesDefaultDiarizer: Bool
    public private(set) var projectionError: String?

    /// Events emitted during pipeline execution for UI/CLI display.
    public enum Event: Sendable {
        case downloading(filename: String, sizeMB: String)
        case downloaded(filename: String)
        case skippedDownload(filename: String)
        case downloadFailed(filename: String, error: String)
        case loadingModels
        case modelsReady
        case transcribing(filename: String, duration: String)
        case transcribed(filename: String, segments: Int, speakers: Int, elapsed: String)
        case skippedTranscription(filename: String)
        case transcriptionFailed(filename: String, error: String)
        case complete(fileCount: Int)
    }

    public init(baseDirectory: URL? = nil) {
        let store = RecordingStore(baseDirectory: baseDirectory)
        self.recordingStore = store
        self.transcriptStore = TranscriptStore(baseDirectory: store.baseDirectory)
        self.shared = nil
        self.usesDefaultDiarizer = true
    }

    /// Reuse the caller's actual stores; supplied engines are already prepared.
    public init(recordingStore: RecordingStore, transcriptStore: TranscriptStore,
                shared: SharedLibraryCoordinator? = nil, transcriber: (any TranscriptionEngine)? = nil,
                diarizer: (any DiarizationEngine)? = nil) {
        self.recordingStore = recordingStore
        self.transcriptStore = transcriptStore
        self.shared = shared
        self.transcriber = transcriber
        self.diarizer = diarizer
        self.usesDefaultDiarizer = transcriber == nil
    }

    /// The directory where recordings and transcripts are stored.
    public nonisolated var storageDirectory: URL {
        recordingStore.baseDirectory
    }

    /// Initialize storage directories and load existing metadata.
    public func setup() async throws {
        guard recordingStore.baseDirectory.standardizedFileURL.resolvingSymlinksInPath() == transcriptStore.baseDirectory.standardizedFileURL.resolvingSymlinksInPath(),
              shared == nil || shared?.root == recordingStore.baseDirectory.standardizedFileURL.resolvingSymlinksInPath() else { throw SharedLibraryCoordinatorError.differentBinding }
        try await recordingStore.setup()
        try await transcriptStore.loadAll()
    }

    // MARK: - Full Pipeline (Download + Transcribe)

    /// Download all new files from device, then optionally transcribe.
    public func downloadAndTranscribeAll(
        deviceManager: DeviceManager,
        skipTranscription: Bool = false,
        deleteAfterDownload: Bool = false,
        numSpeakers: Int? = nil,
        onEvent: (@Sendable (Event) -> Void)? = nil
    ) async throws {
        // Phase 1: Download
        let files = try await deviceManager.queryFileList()
        var metas: [RecordingMetadata] = []

        let imports = SyncEngine(deviceManager: deviceManager, store: recordingStore)
        for file in files {
            try Task.checkCancellation()
            let sizeMB = String(format: "%.1f", Double(file.size) / 1_048_576)
            do {
                let meta = try await imports.downloadFile(file, deleteAfterDownload: deleteAfterDownload) { progress in
                    if progress.phase == .downloading { onEvent?(.downloading(filename: file.filename, sizeMB: sizeMB)) }
                }
                if let meta {
                    metas.append(meta)
                    onEvent?(.downloaded(filename: meta.filename))
                } else {
                    onEvent?(.skippedDownload(filename: file.filename))
                    if let existing = try await recordingStore.existingRecording(for: file) { metas.append(existing) }
                }
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                onEvent?(.downloadFailed(filename: file.filename, error: error.localizedDescription))
            }
        }

        guard !skipTranscription else {
            onEvent?(.complete(fileCount: metas.count))
            return
        }

        // Phase 2: Transcribe
        try await transcribeMetadatas(metas, numSpeakers: numSpeakers, onEvent: onEvent)
    }

    // MARK: - Transcription Only

    /// Transcribe all local recordings that don't have transcripts yet.
    public func transcribeAllLocal(
        numSpeakers: Int? = nil,
        onEvent: (@Sendable (Event) -> Void)? = nil
    ) async throws {
        let metas = await recordingStore.allRecordings()
        try await transcribeMetadatas(metas, numSpeakers: numSpeakers, onEvent: onEvent)
    }

    /// Transcribe a single recording by MP3 filename.
    public func transcribeRecording(filename requestedFilename: String, numSpeakers: Int? = nil, reference: SharedRecordingReference? = nil) async throws -> Transcript {
        let filename: String
        if let reference { guard let shared else { throw SharedLibraryCoordinatorError.differentBinding }; filename = try await shared.resolve(reference) }
        else { filename = requestedFilename }
        if shared == nil { try LegacyLibraryFileAccess.requireLegacyRoot(recordingStore.baseDirectory) }
        guard let meta = await recordingStore.allRecordings().first(where: { $0.filename == filename }) else { throw HiDockError.fileNotFound(filename) }
        let url = recordingStore.baseDirectory.appendingPathComponent(filename)
        var job: SharedLibraryJobToken?
        do {
            if let shared {
                let view = try await shared.recording(at: filename)
                if let reference, reference.libraryID != view.libraryID || reference.entityID != view.state.id { throw SharedLibraryCoordinatorError.differentBinding }
                job = try await shared.pinJob(.init(id: view.state.id, kind: .recording), output: .transcript, audioURL: url)
            }
            try await prepareModels()
            let mode = job?.recordingMode ?? meta.mode
            let transcript = try await TranscriptionPipeline.transcribe(audioURL: url, recordingFilename: filename,
                transcriber: transcriber!, diarizer: mode == "Wip" ? nil : diarizer, numSpeakers: mode == "Wip" ? 1 : numSpeakers)
            try Task.checkCancellation()
            try await transcriptStore.save(transcript, mp3Filename: filename, job: job)
            if let shared {
                if let job { await shared.finishJob(job) }
                do { _ = try await shared.projectOutputs(); projectionError = nil } catch { projectionError = error.localizedDescription }
            } else { try exportPlainText(transcript, basename: (filename as NSString).deletingPathExtension) }
            return transcript
        } catch {
            if let shared, let job { await shared.finishJob(job) }
            throw error
        }
    }

    // MARK: - Queries

    /// Get transcript for a recording by MP3 filename.
    public func transcript(for filename: String) async -> Transcript? {
        await transcriptStore.transcript(for: filename)
    }

    /// Get all recordings.
    public func allRecordings() async -> [RecordingMetadata] {
        await recordingStore.allRecordings()
    }

    /// Get the MP3 URL for a recording.
    public func mp3URL(for meta: RecordingMetadata) async -> URL {
        await recordingStore.mp3URL(for: meta)
    }

    // MARK: - Private

    private func transcribeMetadatas(
        _ metas: [RecordingMetadata],
        numSpeakers: Int? = nil,
        onEvent: (@Sendable (Event) -> Void)?
    ) async throws {
        if shared != nil {
            var count = 0
            for meta in metas {
                if await transcriptStore.hasTranscript(for: meta.filename) { onEvent?(.skippedTranscription(filename: meta.filename)); count += 1; continue }
                onEvent?(.transcribing(filename: meta.filename, duration: DurationCalculator.formatDuration(meta.estimatedDuration)))
                let start = CFAbsoluteTimeGetCurrent()
                do {
                    let result = try await transcribeRecording(filename: meta.filename, numSpeakers: numSpeakers)
                    count += 1
                    onEvent?(.transcribed(filename: meta.filename, segments: result.segments.count, speakers: result.speakerIDs.count,
                        elapsed: String(format: "%.1f", CFAbsoluteTimeGetCurrent() - start)))
                } catch { onEvent?(.transcriptionFailed(filename: meta.filename, error: error.localizedDescription)) }
            }
            onEvent?(.complete(fileCount: count)); return
        }
        try LegacyLibraryFileAccess.requireLegacyRoot(recordingStore.baseDirectory)
        onEvent?(.loadingModels)
        try await prepareModels()
        onEvent?(.modelsReady)

        var processedCount = 0
        for meta in metas {
            let hasTranscript = await transcriptStore.hasTranscript(for: meta.filename)
            if hasTranscript {
                onEvent?(.skippedTranscription(filename: meta.filename))
                processedCount += 1
                continue
            }

            let duration = DurationCalculator.formatDuration(meta.estimatedDuration)
            onEvent?(.transcribing(filename: meta.filename, duration: duration))

            let startTime = CFAbsoluteTimeGetCurrent()
            let mp3URL = await recordingStore.mp3URL(for: meta)

            do {
                let skipDiarization = meta.mode == "Wip"
                let transcript = try await TranscriptionPipeline.transcribe(
                    audioURL: mp3URL,
                    recordingFilename: meta.filename,
                    transcriber: transcriber!,
                    diarizer: skipDiarization ? nil : diarizer,
                    numSpeakers: skipDiarization ? 1 : numSpeakers
                )

                let elapsed = String(format: "%.1f", CFAbsoluteTimeGetCurrent() - startTime)
                onEvent?(.transcribed(
                    filename: meta.filename,
                    segments: transcript.segments.count,
                    speakers: transcript.speakerIDs.count,
                    elapsed: elapsed
                ))

                try await transcriptStore.save(transcript, mp3Filename: meta.filename)
                try exportPlainText(transcript, basename: (meta.filename as NSString).deletingPathExtension)
                processedCount += 1
            } catch {
                onEvent?(.transcriptionFailed(filename: meta.filename, error: error.localizedDescription))
            }
        }

        onEvent?(.complete(fileCount: processedCount))
    }

    private func exportPlainText(_ transcript: Transcript, basename: String) throws {
        let txtURL = recordingStore.baseDirectory.appendingPathComponent("\(basename).txt")
        let plainText = TranscriptExporter.exportPlainText(transcript: transcript)
        try plainText.write(to: txtURL, atomically: true, encoding: .utf8)
    }

    private func prepareModels() async throws {
        if transcriber == nil {
            let t = FluidTranscriber(modelVersion: .v3)
            try await t.prepare()
            transcriber = t
        }
        if diarizer == nil && usesDefaultDiarizer {
            let d = SortformerFluidDiarizer()
            do {
                try await d.prepare()
                diarizer = d
            } catch {
                // Diarization is optional — continue without it
            }
        }
    }
}
