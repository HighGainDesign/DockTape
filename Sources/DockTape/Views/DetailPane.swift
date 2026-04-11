import SwiftUI
import HiDockKit

/// Column 3: Progressive detail view with tabs, player bar, and transcription bar.
struct DetailPane: View {
    @Bindable var state: AppState
    @State private var userHasPickedTab: Bool = false
    @State private var transcript: Transcript?
    @State private var renamingRecording: RecordingMetadata?
    @State private var renameText: String = ""
    @State private var confirmRetranscribe: RecordingMetadata?
    @State private var userTemplates: [Template] = []
    @State private var customPromptText: String = ""
    @State private var showCustomPromptSheet: Bool = false
    @State private var customPromptRecording: RecordingMetadata?

    enum DetailTab: String, CaseIterable {
        case info = "Info"
        case transcript = "Transcript"
        case summary = "Summary"
    }

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
                onTranscribe: {
                    let toTranscribe = recs.filter {
                        (state.transcription.statuses[$0.filename] ?? .none) != .done
                    }
                    Task { await state.transcribeRecordings(toTranscribe) }
                },
                onDelete: {
                    Task {
                        for rec in recs { await state.deleteLocalRecording(rec) }
                        state.library.selectedRecordings.removeAll()
                    }
                }
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

    /// Toolbar button with icon + text label, bordered.
    private func toolbarButton(_ systemImage: String, _ label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(label, systemImage: systemImage)
                .font(.caption)
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .help(label)
    }

    private func singleRecordingDetail(_ rec: RecordingMetadata) -> some View {
        let isPlaying = state.playback.playingFile == rec.filename && state.playback.isPlaying
        let hasTranscript = (state.transcription.statuses[rec.filename] ?? .none) == .done || transcript != nil

        return VStack(spacing: 0) {
            // Detail toolbar
            VStack(spacing: 0) {
                HStack(spacing: 12) {
                    toolbarButton(isPlaying ? "pause.fill" : "play.fill", isPlaying ? "Pause" : "Play") {
                        state.playRecording(rec)
                    }

                    toolbarButton("text.badge.plus", "Transcribe") {
                        if hasTranscript {
                            confirmRetranscribe = rec
                        } else {
                            Task { await state.transcribeRecordings([rec]) }
                        }
                    }

                    Menu {
                        Section("Built-in") {
                            ForEach(TemplateStore.builtInDefaults) { template in
                                Button(template.name) {
                                    state.summarizeWithTemplate(rec, template: template)
                                }
                            }
                        }
                        if !userTemplates.isEmpty {
                            Section("My Templates") {
                                ForEach(userTemplates) { template in
                                    Button(template.name) {
                                        state.summarizeWithTemplate(rec, template: template)
                                    }
                                }
                            }
                        }
                        Divider()
                        Button("Custom prompt...") {
                            customPromptRecording = rec
                            customPromptText = ""
                            showCustomPromptSheet = true
                        }
                    } label: {
                        Label("Summarize", systemImage: "sparkles")
                            .font(.caption)
                    }
                    .menuStyle(.borderedButton)
                    .controlSize(.small)
                    .fixedSize()
                    .help("Summarize with template")
                    .disabled(!hasTranscript)

                    Spacer()

                    toolbarButton("pencil", "Rename") {
                        renameText = (rec.filename as NSString).deletingPathExtension
                        renamingRecording = rec
                    }

                    toolbarButton("folder", "Reveal") {
                        state.library.revealInFinder(rec)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .frame(minHeight: 28)
                .background(.bar)
                Divider()
            }

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
                    syncSegmentTimestamps(for: filename)
                    ensureTabAvailable(for: rec)
                }
            } else {
                state.playback.setSegmentTimestamps([])
                state.selectedDetailTab = .info
            }
        }
        .task(id: rec.filename) {
            transcript = await state.library.transcript(for: rec.filename)
            userTemplates = await state.templateStore.userCreatedTemplates()
            syncSegmentTimestamps(for: rec.filename)
            if !userHasPickedTab {
                // First load: auto-select best tab
                state.selectedDetailTab = transcript != nil ? .transcript : .info
            } else {
                ensureTabAvailable(for: rec)
            }
        }
        .onChange(of: state.selectedDetailTab) { _, _ in
            userHasPickedTab = true
        }
        .onChange(of: state.transcription.statuses[rec.filename]) { _, newStatus in
            // Reload transcript when transcription completes for this recording
            if newStatus == .done {
                Task {
                    self.transcript = await state.library.transcript(for: rec.filename)
                    syncSegmentTimestamps(for: rec.filename)
                }
            }
        }
        .onChange(of: state.playback.playingFile) { _, newFile in
            // Sync timestamps when playback starts/stops for this recording
            if newFile == rec.filename {
                syncSegmentTimestamps(for: rec.filename)
            } else {
                state.playback.setSegmentTimestamps([])
            }
        }
        .onChange(of: state.triggerRename) { _, trigger in
            if trigger, renamingRecording == nil {
                renameText = (rec.filename as NSString).deletingPathExtension
                renamingRecording = rec
                state.triggerRename = false
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
                            let prompt = Template.buildCustomPrompt(customPromptText)
                            let customTemplate = Template(
                                id: "custom",
                                name: "Custom",
                                description: "One-shot custom prompt",
                                promptText: customPromptText,
                                isBuiltIn: false
                            )
                            state.summarizeWithTemplate(rec, template: customTemplate)
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
                        Task { try? await state.updateSpeakerNames(for: rec.filename, names: names) }
                        Task { self.transcript = await state.library.transcript(for: rec.filename) }
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

    // TODO: Currently a no-op — setSegmentTimestamps is stubbed out while progress
    // tracking is disabled. Re-enable when playback progress is fixed (AppKit migration).
    private func syncSegmentTimestamps(for filename: String) {
        if let transcript, state.playback.playingFile == nil || state.playback.playingFile == filename {
            state.playback.setSegmentTimestamps(transcript.segments.map(\.startTime))
        } else {
            state.playback.setSegmentTimestamps([])
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
            HStack(spacing: 12) {
                Button {
                    Task {
                        for file in files { await state.downloadFile(file) }
                    }
                } label: {
                    Label("Import All", systemImage: "arrow.down.circle")
                }
                .buttonStyle(.bordered)

                Button(role: .destructive) {
                    Task {
                        for file in files { await state.deleteFromDevice(file) }
                        state.device.selectedDeviceFiles.removeAll()
                    }
                } label: {
                    Label("Delete All", systemImage: "trash")
                }
                .buttonStyle(.bordered)
            }
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

    var body: some View {
        VStack(spacing: 0) {
            Divider()
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
                        .font(.caption)
                        .lineLimit(1)
                }

                Spacer()

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
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(.bar)
        }
    }

    private func speedLabel(_ rate: Float) -> String {
        if rate == 1.0 { return "1x" }
        if rate == floor(rate) { return "\(Int(rate))x" }
        return String(format: "%.2gx", rate)
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

            VStack(spacing: 0) {
                Divider()
                HStack(spacing: 12) {
                    ProgressView()
                        .controlSize(.small)
                        .accessibilityLabel("Transcribing")

                    if let file = state.transcription.transcribingFile {
                        let rec = state.library.recordings.first { $0.filename == file }
                        VStack(alignment: .leading, spacing: 1) {
                            HStack(spacing: 6) {
                                Text(state.transcription.phase)
                                    .font(.caption.weight(.medium))
                                if state.transcription.queue.count > 1 {
                                    Text("\(state.transcription.queueIndex + 1) of \(state.transcription.queue.count)")
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
                .padding(.vertical, 8)
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
        VStack(spacing: 0) {
            Divider()
            HStack(spacing: 12) {
                ProgressView()
                    .controlSize(.small)
                    .accessibilityLabel("Summarizing")

                if let file = state.summarization.summarizingFile {
                    let rec = state.library.recordings.first { $0.filename == file }
                    VStack(alignment: .leading, spacing: 1) {
                        HStack(spacing: 6) {
                            Text(state.summarization.phase)
                                .font(.caption.weight(.medium))
                            if state.summarization.queueCount > 1 {
                                Text("\(state.summarization.queueIndex + 1) of \(state.summarization.queueCount)")
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
            .padding(.vertical, 8)
            .background(.bar)
        }
    }
}
