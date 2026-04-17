// © 2026 High Gain Design. All rights reserved.

import SwiftUI
import HiDockKit

/// Column 3: Progressive detail view with tabs, player bar, and transcription bar.
struct DetailPane: View {
    @Bindable var state: AppState
    @State private var userHasPickedTab: Bool = false
    @State private var programmaticTabSwitchCount: Int = 0
    @State private var transcript: Transcript?
    @State private var renamingRecording: RecordingMetadata?
    @State private var renameText: String = ""
    @State private var confirmRetranscribe: RecordingMetadata?
    @State private var userTemplates: [Template] = []
    @State private var customPromptText: String = ""
    @State private var showCustomPromptSheet: Bool = false
    @State private var customPromptRecording: RecordingMetadata?

    var body: some View {
        VStack(spacing: 0) {
            detailContent
                .frame(maxHeight: .infinity)

            if state.playback.playingFile != nil {
                NowPlayingBar(state: state)
            }

            if state.transcription.transcribingFile != nil {
                TranscriptionBar(state: state)
            }

            if state.summarization.isSummarizing {
                SummarizationBar(state: state)
            }
        }
        .alert("Error", isPresented: Binding(
            get: { state.errorMessage != nil },
            set: { if !$0 { state.errorMessage = nil } }
        )) {
            Button("Dismiss", role: .cancel) { state.errorMessage = nil }
        } message: {
            Text(state.errorMessage ?? "")
        }
    }

    @ViewBuilder
    private var detailContent: some View {
        switch state.selectedView {
        case .allRecordings, .folder:
            recordingDetail
        case .device:
            deviceDetail
        }
    }

    // MARK: - Recording Detail

    @ViewBuilder
    private var recordingDetail: some View {
        let selectedCount = state.library.selectedRecordings.count
        if selectedCount == 0 {
            ContentUnavailableView {
                Label("No Selection", systemImage: "doc.text")
            } description: {
                Text("Select a recording to see details.")
            }
        } else if selectedCount > 1 {
            let recs = state.library.recordings.filter { state.library.selectedRecordings.contains($0.filename) }
            MultiSelectSummary(
                recordings: recs,
                transcriptionStatuses: state.transcription.statuses,
                summaryStatuses: state.summarization.hasSummary
            )
        } else if let filename = state.library.selectedRecording,
                  let rec = state.library.recordings.first(where: { $0.filename == filename }) {
            singleRecordingDetail(rec)
        } else {
            ContentUnavailableView {
                Label("No Selection", systemImage: "doc.text")
            } description: {
                Text("Select a recording to see details.")
            }
        }
    }

    private func singleRecordingDetail(_ rec: RecordingMetadata) -> some View {
        VStack(spacing: 0) {
            // Header with title
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(rec.displayTitle)
                        .font(.title2.weight(.semibold))
                    if let date = rec.recordedAt {
                        HStack(spacing: 4) {
                            Text(date, style: .date)
                            Text(date, style: .time)
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                }
                Spacer()
            }
            .padding()

            // Tab bar
            Picker("Detail", selection: $state.selectedDetailTab) {
                ForEach(availableTabs(for: rec), id: \.self) { tab in
                    Text(tab.rawValue).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal)

            Divider()
                .padding(.top, 8)

            // Tab content
            tabContent(for: rec)
        }
        .onChange(of: state.library.selectedRecording) { _, newFilename in
            if let filename = newFilename {
                Task {
                    self.transcript = await state.library.transcript(for: filename)

                    ensureTabAvailable(for: rec)
                }
            } else {
                state.selectedDetailTab = .info
            }
        }
        .task(id: rec.filename) {
            transcript = await state.library.transcript(for: rec.filename)
            if let t = transcript {
                state.playback.segmentTimestamps = t.segments.map { (start: $0.startTime, end: $0.endTime) }
            } else {
                state.playback.segmentTimestamps = []
            }
            userTemplates = await state.templateStore.userCreatedTemplates()

            if !userHasPickedTab {
                // First load: auto-select best tab
                programmaticTabSwitchCount += 1
                state.selectedDetailTab = transcript != nil ? .transcript : .info
            } else {
                ensureTabAvailable(for: rec)
            }
        }
        .onChange(of: state.selectedDetailTab) { old, new in
            // Only mark as user-picked if this wasn't a programmatic switch
            if programmaticTabSwitchCount > 0 {
                programmaticTabSwitchCount -= 1
            } else {
                userHasPickedTab = true
            }
        }
        .onChange(of: state.transcription.statuses[rec.filename]) { _, newStatus in
            // Reload transcript and auto-switch when transcription completes
            if newStatus == .done {
                Task {
                    self.transcript = await state.library.transcript(for: rec.filename)
                    programmaticTabSwitchCount += 1
                    state.selectedDetailTab = .transcript
                }
            }
        }
        .onChange(of: state.summarization.hasSummary.contains(rec.filename)) { _, hasSummary in
            if hasSummary {
                programmaticTabSwitchCount += 1
                state.selectedDetailTab = .summary
            }
        }
        .onChange(of: state.triggerRename) { _, trigger in
            if trigger, renamingRecording == nil {
                renameText = (rec.filename as NSString).deletingPathExtension
                renamingRecording = rec
                state.triggerRename = false
            }
        }
        .onChange(of: state.triggerCustomPrompt) { _, trigger in
            if trigger, let rec = state.library.recordings.first(where: { $0.filename == state.library.selectedRecording }) {
                customPromptRecording = rec
                customPromptText = ""
                showCustomPromptSheet = true
                state.triggerCustomPrompt = false
            }
        }
        .alert("Rename Recording", isPresented: Binding(
            get: { renamingRecording != nil },
            set: { if !$0 { renamingRecording = nil } }
        )) {
            TextField("Name", text: $renameText)
            Button("Cancel", role: .cancel) { renamingRecording = nil }
            Button("Save") {
                if let rec = renamingRecording {
                    Task { await state.renameRecording(rec, to: renameText) }
                }
                renamingRecording = nil
            }
        } message: {
            Text("Enter a display name for this recording.")
        }
        .alert("Re-transcribe?", isPresented: Binding(
            get: { confirmRetranscribe != nil },
            set: { if !$0 { confirmRetranscribe = nil } }
        )) {
            Button("Cancel", role: .cancel) { confirmRetranscribe = nil }
            Button("Re-transcribe") {
                if let rec = confirmRetranscribe {
                    Task { await state.transcribeRecordings([rec]) }
                }
                confirmRetranscribe = nil
            }
        } message: {
            Text("This recording already has a transcript. Re-transcribing will replace it.")
        }
        .sheet(isPresented: $showCustomPromptSheet) {
            VStack(spacing: 16) {
                Text("Custom Prompt")
                    .font(.headline)
                Text("Enter instructions for how to summarize this recording.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                TextEditor(text: $customPromptText)
                    .font(.body.monospaced())
                    .frame(minWidth: 400, minHeight: 120)
                    .border(.separator)
                HStack {
                    Button("Cancel") {
                        showCustomPromptSheet = false
                    }
                    .keyboardShortcut(.cancelAction)
                    Spacer()
                    Button("Summarize") {
                        if let rec = customPromptRecording {
                            let customTemplate = Template(
                                id: "custom",
                                name: "Custom",
                                description: "One-shot custom prompt",
                                promptText: "",
                                isBuiltIn: false
                            )
                            state.summarizeWithTemplate(rec, template: customTemplate, customPrompt: customPromptText)
                        }
                        showCustomPromptSheet = false
                    }
                    .keyboardShortcut(.defaultAction)
                    .disabled(customPromptText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .padding()
            .frame(minWidth: 450)
        }
    }

    private func availableTabs(for rec: RecordingMetadata) -> [DetailTab] {
        let status = state.transcription.statuses[rec.filename] ?? .none
        if status == .done || transcript != nil {
            return [.info, .transcript, .summary]
        }
        return [.info]
    }

    @ViewBuilder
    private func tabContent(for rec: RecordingMetadata) -> some View {
        switch state.selectedDetailTab {
        case .info:
            InfoTabView(
                recording: rec,
                transcriptStatus: state.transcription.statuses[rec.filename] ?? .none
            )

        case .transcript:
            if let transcript {
                TranscriptViewer(
                    transcript: transcript,
                    playbackState: state.playback,
                    activeSegmentIndex: state.playback.activeSegmentIndex,
                    onSeek: { time in
                        if state.playback.playingFile == rec.filename {
                            state.playback.seek(to: time)
                        } else {
                            let url = state.library.store.baseDirectory.appendingPathComponent(rec.filename)
                            state.playback.play(file: rec.filename, url: url)
                            state.playback.seek(to: time)
                        }
                    },
                    onSaveSpeakerNames: { names in
                        Task {
                            try? await state.updateSpeakerNames(for: rec.filename, names: names)
                            self.transcript = await state.library.transcript(for: rec.filename)
                        }
                    },
                    onSplitSpeaker: { segID, allFollowing in
                        Task {
                            try? await state.library.transcriptStore.splitSpeaker(for: rec.filename, segmentID: segID, allFollowing: allFollowing)
                            self.transcript = await state.library.transcript(for: rec.filename)
                        }
                    },
                    onMergeSpeaker: { sourceSID, targetSID in
                        Task {
                            try? await state.library.transcriptStore.mergeSpeakers(for: rec.filename, source: sourceSID, into: targetSID)
                            self.transcript = await state.library.transcript(for: rec.filename)
                        }
                    }
                )
            } else {
                ContentUnavailableView {
                    Label("No Transcript", systemImage: "doc.text")
                } description: {
                    Text("Transcribe this recording to see the transcript.")
                }
            }

        case .summary:
            SummaryTabView(state: state, recording: rec)

        }
    }

    /// If the user's current tab isn't available for this recording, fall back.
    private func ensureTabAvailable(for rec: RecordingMetadata) {
        let available = availableTabs(for: rec)
        if !available.contains(state.selectedDetailTab) {
            state.selectedDetailTab = available.last ?? .info
        }
    }

    // MARK: - Device Detail

    @ViewBuilder
    private var deviceDetail: some View {
        let selectedCount = state.device.selectedDeviceFiles.count
        if selectedCount == 0 {
            if state.device.isConnected {
                ContentUnavailableView {
                    Label("No Selection", systemImage: "doc")
                } description: {
                    Text("Select a file to see details.")
                }
            } else {
                ContentUnavailableView {
                    Label("Connect Your HiDock", systemImage: "cable.connector.horizontal")
                } description: {
                    Text("Plug in your HiDock P1, P1 Mini, H1, or H1E via USB to get started.")
                }
            }
        } else if selectedCount > 1 {
            deviceMultiSelect
        } else if let filename = state.device.selectedDeviceFile,
                  let file = state.device.files.first(where: { $0.filename == filename }) {
            deviceFileDetail(file)
        } else {
            ContentUnavailableView {
                Label("No Selection", systemImage: "doc")
            } description: {
                Text("Select a file to see details.")
            }
        }
    }

    private var deviceMultiSelect: some View {
        let files = state.device.files.filter { state.device.selectedDeviceFiles.contains($0.filename) }
        let totalSize = files.reduce(0) { $0 + $1.size }
        return VStack(spacing: 20) {
            Spacer()
            Image(systemName: "doc.on.doc.fill")
                .font(.system(size: 48))
                .foregroundStyle(.secondary)
            Text("\(files.count) files selected")
                .font(.title2.weight(.medium))
            Text("Total size: \(ByteCountFormatter.string(fromByteCount: Int64(totalSize), countStyle: .file))")
                .foregroundStyle(.secondary)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func deviceFileDetail(_ file: FileEntry) -> some View {
        let parsed = FilenameParsing.parse(file.filename)
        return Form {
            Section("File") {
                LabeledContent("Filename", value: file.filename)
                if let date = parsed.date {
                    LabeledContent("Date") {
                        Text(date, style: .date)
                        Text(date, style: .time)
                    }
                }
                LabeledContent("Mode", value: parsed.mode.displayName)
                LabeledContent("Size", value: ByteCountFormatter.string(fromByteCount: Int64(file.size), countStyle: .file))
                LabeledContent("Est. Duration", value: DurationCalculator.formatDuration(DurationCalculator.estimateDuration(fileSize: UInt64(file.size))))
            }

            Section("Status") {
                LabeledContent("Downloaded") {
                    if state.library.isDownloaded(file.filename) {
                        Label("Yes", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    } else {
                        Text("No").foregroundStyle(.secondary)
                    }
                }
            }

            Section {
                Button {
                    Task { await state.downloadFile(file) }
                } label: {
                    Label("Import", systemImage: "arrow.down.circle")
                }
                .disabled(state.device.downloadingFiles.contains(file.filename))
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Now Playing Bar

struct NowPlayingBar: View {
    @Bindable var state: AppState
    @State private var isDragging: Bool = false
    @State private var dragValue: Double = 0

    var body: some View {
        VStack(spacing: 0) {
            Divider()
            VStack(spacing: 6) {
                HStack(spacing: 12) {
                    Button {
                        state.playback.togglePlayPause()
                    } label: {
                        Image(systemName: state.playback.isPlaying ? "pause.fill" : "play.fill")
                            .frame(width: 20)
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel(state.playback.isPlaying ? "Pause" : "Play")

                    if let file = state.playback.playingFile {
                        let rec = state.library.recordings.first { $0.filename == file }
                        Text(rec?.displayTitle ?? file)
                            .font(.caption.weight(.medium))
                            .lineLimit(1)
                    }

                    Spacer()

                    // Time display driven by TimelineView for smooth updates
                    TimelineView(.animation(minimumInterval: 1.0 / 10, paused: !state.playback.isPlaying)) { _ in
                        let currentTime = isDragging ? dragValue : state.playback.currentTime
                        let duration = state.playback.duration

                        Text("\(formatTime(currentTime)) / \(formatTime(duration))")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }

                    Menu {
                        ForEach(PlaybackState.speeds, id: \.self) { speed in
                            Button {
                                state.playback.setRate(speed)
                            } label: {
                                HStack {
                                    Text(speedLabel(speed))
                                    if state.playback.rate == speed { Image(systemName: "checkmark") }
                                }
                            }
                        }
                    } label: {
                        Text(speedLabel(state.playback.rate))
                            .font(.caption.monospacedDigit().weight(.medium))
                            .frame(minWidth: 30)
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                    .help("Playback speed")

                    Button {
                        state.playback.stop()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel("Stop playback")
                }

                // Scrubber driven by TimelineView for smooth updates
                if state.playback.duration > 0 {
                    TimelineView(.animation(minimumInterval: 1.0 / 10, paused: !state.playback.isPlaying)) { _ in
                        let currentTime = isDragging ? dragValue : state.playback.currentTime
                        let duration = state.playback.duration

                        Slider(
                            value: Binding(
                                get: { currentTime },
                                set: { newValue in
                                    isDragging = true
                                    dragValue = newValue
                                    state.playback.seek(to: newValue)
                                }
                            ),
                            in: 0...max(duration, 0.01)
                        )
                        .controlSize(.mini)
                        .accessibilityLabel("Playback position")
                        .accessibilityValue(formatTime(currentTime))
                    }
                    .onChange(of: state.playback.isPlaying) { _, isPlaying in
                        // When playback resumes, stop overriding with drag value
                        if isPlaying { isDragging = false }
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(.bar)
        }
    }

    private func speedLabel(_ rate: Float) -> String {
        if rate == 1.0 { return "1\u{00D7}" }
        if rate == floor(rate) { return "\(Int(rate))\u{00D7}" }
        return String(format: "%.2g\u{00D7}", rate)
    }

    private func formatTime(_ seconds: Double) -> String {
        guard seconds.isFinite && seconds >= 0 else { return "0:00" }
        let total = Int(seconds)
        let m = total / 60
        let s = total % 60
        return String(format: "%d:%02d", m, s)
    }
}

// MARK: - Transcription Progress Bar

struct TranscriptionBar: View {
    @Bindable var state: AppState

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let elapsed = state.transcription.startTime.map {
                context.date.timeIntervalSince($0)
            } ?? 0

            let queueTotal = state.transcription.queue.count
            let queueIndex = state.transcription.queueIndex

            VStack(spacing: 0) {
                Divider()

                // Progress bar
                if queueTotal > 1 {
                    ProgressView(value: Double(queueIndex), total: Double(queueTotal))
                        .tint(.orange)
                        .controlSize(.small)
                        .padding(.horizontal, 16)
                        .padding(.top, 6)
                } else {
                    ProgressView()
                        .progressViewStyle(.linear)
                        .tint(.orange)
                        .controlSize(.small)
                        .padding(.horizontal, 16)
                        .padding(.top, 6)
                }

                HStack(spacing: 12) {
                    if let file = state.transcription.transcribingFile {
                        let rec = state.library.recordings.first { $0.filename == file }
                        VStack(alignment: .leading, spacing: 1) {
                            HStack(spacing: 6) {
                                Text(state.transcription.phase)
                                    .font(.caption.weight(.medium))
                                if queueTotal > 1 {
                                    Text("\(queueIndex + 1) of \(queueTotal)")
                                        .font(.caption.monospacedDigit())
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 1)
                                        .background(.orange.opacity(0.15))
                                        .clipShape(Capsule())
                                }
                            }
                            if let rec {
                                Text(rec.displayTitle)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }

                    Spacer()

                    Text(formatElapsed(elapsed))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)

                    Button {
                        state.transcription.cancel()
                    } label: {
                        Label("Cancel", systemImage: "xmark.circle.fill")
                            .font(.caption)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 6)
                .background(.orange.opacity(0.08))
            }
        }
    }

    private func formatElapsed(_ seconds: TimeInterval) -> String {
        let total = Int(seconds)
        let m = total / 60
        let s = total % 60
        return String(format: "%d:%02d", m, s)
    }
}

// MARK: - Summarization Progress Bar

struct SummarizationBar: View {
    @Bindable var state: AppState

    var body: some View {
        let queueTotal = state.summarization.queueCount
        let queueIndex = state.summarization.queueIndex

        VStack(spacing: 0) {
            Divider()

            // Progress bar
            if queueTotal > 1 {
                ProgressView(value: Double(queueIndex), total: Double(queueTotal))
                    .tint(.purple)
                    .controlSize(.small)
                    .padding(.horizontal, 16)
                    .padding(.top, 6)
            } else {
                ProgressView()
                    .progressViewStyle(.linear)
                    .tint(.purple)
                    .controlSize(.small)
                    .padding(.horizontal, 16)
                    .padding(.top, 6)
            }

            HStack(spacing: 12) {
                if let file = state.summarization.summarizingFile {
                    let rec = state.library.recordings.first { $0.filename == file }
                    VStack(alignment: .leading, spacing: 1) {
                        HStack(spacing: 6) {
                            Text(state.summarization.phase)
                                .font(.caption.weight(.medium))
                            if queueTotal > 1 {
                                Text("\(queueIndex + 1) of \(queueTotal)")
                                    .font(.caption.monospacedDigit())
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 1)
                                    .background(.purple.opacity(0.15))
                                    .clipShape(Capsule())
                            }
                        }
                        if let rec {
                            Text(rec.displayTitle)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                Spacer()

                Button {
                    state.summarization.cancel()
                } label: {
                    Label("Cancel", systemImage: "xmark.circle.fill")
                        .font(.caption)
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 6)
            .background(.bar)
        }
    }
}
