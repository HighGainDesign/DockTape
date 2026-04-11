// © 2026 High Gain Design. All rights reserved.

import Foundation

/// End-to-end pipeline: download files from device → convert HDA → transcribe + diarize.
/// Used by both the SwiftUI app and CLI. All state is managed internally.
public actor RecordingPipeline {
    private let recordingStore: RecordingStore
    private let transcriptStore: TranscriptStore

    private var transcriber: FluidTranscriber?
    private var diarizer: SortformerFluidDiarizer?

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
    }

    /// The directory where recordings and transcripts are stored.
    public nonisolated var storageDirectory: URL {
        recordingStore.baseDirectory
    }

    /// Initialize storage directories and load existing metadata.
    public func setup() async throws {
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

        for file in files {
            let alreadyHave = await recordingStore.isDownloaded(filename: file.filename)
            if alreadyHave {
                onEvent?(.skippedDownload(filename: file.filename))
                // Find by MP3 filename
                let mp3Name = file.filename.replacingOccurrences(of: ".hda", with: ".mp3")
                if let meta = await recordingStore.allRecordings().first(where: { $0.filename == mp3Name }) {
                    metas.append(meta)
                }
                continue
            }

            let sizeMB = String(format: "%.1f", Double(file.size) / 1_048_576)
            onEvent?(.downloading(filename: file.filename, sizeMB: sizeMB))

            do {
                let hdaData = try await deviceManager.downloadFile(entry: file)
                let meta = try await recordingStore.storeRecording(hdaData: hdaData, entry: file)
                metas.append(meta)
                onEvent?(.downloaded(filename: meta.filename))

                if deleteAfterDownload {
                    try await deviceManager.deleteFile(entry: file)
                }
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
    public func transcribeRecording(filename: String) async throws -> Transcript {
        guard let meta = await recordingStore.allRecordings().first(where: { $0.filename == filename }) else {
            throw HiDockError.fileNotFound(filename)
        }

        try await prepareModels()

        let mp3URL = await recordingStore.mp3URL(for: meta)
        let transcript = try await TranscriptionPipeline.transcribe(
            audioURL: mp3URL,
            recordingFilename: filename,
            transcriber: transcriber!,
            diarizer: diarizer
        )

        try await transcriptStore.save(transcript, mp3Filename: filename)
        try exportPlainText(transcript, basename: (filename as NSString).deletingPathExtension)

        return transcript
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
                let transcript = try await TranscriptionPipeline.transcribe(
                    audioURL: mp3URL,
                    recordingFilename: meta.filename,
                    transcriber: transcriber!,
                    diarizer: diarizer,
                    numSpeakers: numSpeakers
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
        if diarizer == nil {
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
