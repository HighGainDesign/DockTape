import SwiftUI
import HiDockKit

struct LibraryView: View {
    @Bindable var state: AppState
    @State private var searchText = ""
    @AppStorage("librarySortBy") private var sortBy: LibrarySort = .dateNewest
    @AppStorage("libraryFilterMode") private var filterMode: String = ""
    @AppStorage("libraryFilterPeriod") private var filterPeriod: TimePeriod = .anyTime

    enum TimePeriod: String, CaseIterable {
        case anyTime = "Any Time"
        case today = "Today"
        case last7Days = "Last 7 Days"
        case last30Days = "Last 30 Days"

        var startDate: Date? {
            let cal = Calendar.current
            switch self {
            case .anyTime: return nil
            case .today: return cal.startOfDay(for: Date())
            case .last7Days: return cal.date(byAdding: .day, value: -7, to: cal.startOfDay(for: Date()))
            case .last30Days: return cal.date(byAdding: .day, value: -30, to: cal.startOfDay(for: Date()))
            }
        }
    }
    @State private var viewingTranscript: Transcript?
    @State private var viewingTranscriptFilename: String?
    @State private var renamingRecording: RecordingMetadata?
    @State private var renameText = ""
    @State private var selection = Set<String>()

    enum LibrarySort: String, CaseIterable {
        case dateNewest = "Newest First"
        case dateOldest = "Oldest First"
        case longest = "Longest First"
        case shortest = "Shortest First"
        case largest = "Largest First"
        case smallest = "Smallest First"
    }

    var body: some View {
        VStack(spacing: 0) {
            if state.recordings.isEmpty {
                ContentUnavailableView {
                    Label("No Recordings", systemImage: "waveform.slash")
                } description: {
                    if state.isConnected {
                        Text("Download recordings from your device to see them here.")
                    } else {
                        Text("Connect your HiDock and download recordings to get started.")
                    }
                }
            } else if filteredRecordings.isEmpty {
                ContentUnavailableView.search(text: searchText)
            } else {
                recordingList
            }
        }
        .searchable(text: $searchText, prompt: "Search recordings")
        .modifier(SearchFocusModifier(trigger: $state.isSearchFocused))
        .toolbar {
            toolbarContent
        }
        .navigationTitle("Library")
        .sheet(item: $viewingTranscript) { transcript in
            TranscriptViewer(
                transcript: transcript,
                onSeek: { time in state.seekPlayback(to: time) },
                onSaveSpeakerNames: { names in
                    if let filename = viewingTranscriptFilename {
                        Task { await state.updateSpeakerNames(for: filename, names: names) }
                    }
                }
            )
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
        .onAppear {
            if selection.isEmpty, let first = filteredRecordings.first {
                selection = [first.filename]
            }
        }
        .onChange(of: state.recordings.count) {
            if selection.isEmpty, let first = filteredRecordings.first {
                selection = [first.filename]
            }
        }
        .onKeyPress(.space) {
            guard viewingTranscript == nil else { return .ignored }
            guard let rec = selectedRecordings.first, selection.count == 1 else { return .ignored }
            Task { await state.playRecording(rec) }
            return .handled
        }
        .onKeyPress(.delete) {
            guard viewingTranscript == nil else { return .ignored }
            guard !selection.isEmpty else { return .ignored }
            Task {
                for rec in selectedRecordings {
                    await state.deleteLocalRecording(rec)
                }
                selection.removeAll()
            }
            return .handled
        }
        .onKeyPress(.return) {
            guard viewingTranscript == nil else { return .ignored }
            guard selection.count == 1, let rec = selectedRecordings.first else { return .ignored }
            let status = state.transcriptStatuses[rec.filename] ?? TranscriptStatus.none
            if status == .done {
                Task { viewingTranscriptFilename = rec.filename; viewingTranscript = await state.viewTranscript(for: rec) }
            }
            return .handled
        }
    }

    // MARK: - Recording List

    private var recordingList: some View {
        List(selection: $selection) {
            ForEach(filteredRecordings) { rec in
                LibraryRow(
                    recording: rec,
                    transcriptStatus: state.transcriptStatuses[rec.filename] ?? TranscriptStatus.none,
                    isTranscribing: state.transcribingFile == rec.filename,
                    isCurrentlyPlaying: state.playingFile == rec.filename && state.isPlaying
                )
                .tag(rec.filename)
                .contextMenu {
                    contextMenu(for: rec)
                }
            }
        }
        .listStyle(.inset(alternatesRowBackgrounds: true))
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        // Actions — always visible, disabled when not applicable
        ToolbarItemGroup(placement: .automatic) {
            let singleRec = selection.count == 1 ? selectedRecordings.first : nil
            let hasSelection = !selection.isEmpty
            let transcriptStatus = singleRec.flatMap { state.transcriptStatuses[$0.filename] } ?? TranscriptStatus.none
            let allTranscribed = hasSelection && selectedRecordings.allSatisfy {
                (state.transcriptStatuses[$0.filename] ?? TranscriptStatus.none) == .done
            }

            Button {
                if let rec = singleRec {
                    Task { await state.playRecording(rec) }
                }
            } label: {
                let playing = singleRec.map { state.playingFile == $0.filename && state.isPlaying } ?? false
                Label(playing ? "Pause" : "Play",
                      systemImage: playing ? "pause.fill" : "play.fill")
            }
            .disabled(singleRec == nil)
            .help("Play/Pause (Space)")

            // Transcript actions grouped together
            Button {
                if let rec = singleRec {
                    Task { viewingTranscriptFilename = rec.filename; viewingTranscript = await state.viewTranscript(for: rec) }
                }
            } label: {
                Label("Transcript", systemImage: "doc.text")
            }
            .disabled(singleRec == nil || transcriptStatus != .done)
            .help("View transcript (Return)")

            Button {
                let toTranscribe = selectedRecordings.filter {
                    (state.transcriptStatuses[$0.filename] ?? TranscriptStatus.none) != .done
                }
                Task {
                    await state.transcribeRecordings(toTranscribe)
                }
            } label: {
                Label("Transcribe", systemImage: "text.badge.plus")
            }
            .disabled(!hasSelection || allTranscribed)
            .help(allTranscribed ? "Already transcribed" : "Transcribe selected recording(s)")

            Button {
                if let rec = singleRec {
                    renameText = (rec.filename as NSString).deletingPathExtension
                    renamingRecording = rec
                }
            } label: {
                Label("Rename", systemImage: "pencil")
            }
            .disabled(singleRec == nil)
            .help("Rename recording")

            Button {
                if let rec = singleRec {
                    state.revealInFinder(rec)
                }
            } label: {
                Label("Reveal", systemImage: "folder")
            }
            .disabled(singleRec == nil)
            .help("Reveal in Finder")

            Button(role: .destructive) {
                Task {
                    for rec in selectedRecordings {
                        await state.deleteLocalRecording(rec)
                    }
                    selection.removeAll()
                }
            } label: {
                Label("Delete", systemImage: "trash")
            }
            .disabled(!hasSelection)
            .help("Delete selected (⌫)")

            Button {
                Task { await state.refreshRecordings() }
            } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
            }
            .keyboardShortcut("r", modifiers: .command)
            .help("Refresh library (⌘R)")
        }

        // Sort & Filter (trailing, before search)
        ToolbarItemGroup(placement: .primaryAction) {
            Menu {
                ForEach(LibrarySort.allCases, id: \.self) { sort in
                    Button {
                        sortBy = sort
                    } label: {
                        HStack {
                            Text(sort.rawValue)
                            if sortBy == sort {
                                Image(systemName: "checkmark")
                            }
                        }
                    }
                }
            } label: {
                Label("Sort", systemImage: "arrow.up.arrow.down")
            }
            .help("Sort recordings")

            Menu {
                Section("Type") {
                    Button("All") { filterMode = "" }
                    Button("Recording") { filterMode = "Rec" }
                    Button("Phone") { filterMode = "Pho" }
                    Button("Meeting") { filterMode = "Mee" }
                    Button("WIP") { filterMode = "Wip" }
                }
                Section("Date") {
                    ForEach(TimePeriod.allCases, id: \.self) { period in
                        Button {
                            filterPeriod = period
                        } label: {
                            HStack {
                                Text(period.rawValue)
                                if filterPeriod == period {
                                    Image(systemName: "checkmark")
                                }
                            }
                        }
                    }
                }
            } label: {
                let isActive = !filterMode.isEmpty || filterPeriod != .anyTime
                Label(filterLabel,
                      systemImage: isActive ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle")
            }
            .help("Filter by type or date")
        }
    }

    // MARK: - Context Menu

    @ViewBuilder
    private func contextMenu(for rec: RecordingMetadata) -> some View {
        let isPlaying = state.playingFile == rec.filename && state.isPlaying
        Button {
            Task { await state.playRecording(rec) }
        } label: {
            Label(isPlaying ? "Pause" : "Play", systemImage: isPlaying ? "pause.fill" : "play.fill")
        }

        Divider()

        let status = state.transcriptStatuses[rec.filename] ?? TranscriptStatus.none
        if state.transcribingFile == rec.filename {
            Button {
                state.cancelTranscription()
            } label: {
                Label("Cancel Transcription", systemImage: "xmark.circle")
            }
        } else {
            Button {
                Task { await state.transcribeRecording(rec) }
            } label: {
                Label(status == .done ? "Re-transcribe" : "Transcribe",
                      systemImage: "text.badge.plus")
            }
        }

        if status == .done {
            Button {
                Task { viewingTranscriptFilename = rec.filename; viewingTranscript = await state.viewTranscript(for: rec) }
            } label: {
                Label("View Transcript", systemImage: "doc.text")
            }
        }

        Divider()

        Button {
            renameText = (rec.filename as NSString).deletingPathExtension
            renamingRecording = rec
        } label: {
            Label("Rename...", systemImage: "pencil")
        }

        Button {
            state.revealInFinder(rec)
        } label: {
            Label("Reveal in Finder", systemImage: "folder")
        }

        Divider()

        Button(role: .destructive) {
            Task { await state.deleteLocalRecording(rec) }
        } label: {
            Label("Delete", systemImage: "trash")
        }
    }

    // MARK: - Helpers

    private var selectedRecordings: [RecordingMetadata] {
        state.recordings.filter { selection.contains($0.filename) }
    }

    private var filterLabel: String {
        if !filterMode.isEmpty && filterPeriod != .anyTime {
            return "\(modeDisplayName(filterMode)), \(filterPeriod.rawValue)"
        } else if !filterMode.isEmpty {
            return modeDisplayName(filterMode)
        } else if filterPeriod != .anyTime {
            return filterPeriod.rawValue
        }
        return "Filter"
    }

    private var filteredRecordings: [RecordingMetadata] {
        var recs = state.recordings

        if !filterMode.isEmpty {
            recs = recs.filter { $0.mode == filterMode }
        }

        if let startDate = filterPeriod.startDate {
            recs = recs.filter { ($0.recordedAt ?? .distantPast) >= startDate }
        }

        if !searchText.isEmpty {
            let query = searchText.lowercased()
            recs = recs.filter {
                $0.filename.lowercased().contains(query) ||
                $0.displayTitle.lowercased().contains(query) ||
                (modeDisplayName($0.mode)).lowercased().contains(query)
            }
        }

        switch sortBy {
        case .dateNewest:
            recs.sort { ($0.recordedAt ?? .distantPast) > ($1.recordedAt ?? .distantPast) }
        case .dateOldest:
            recs.sort { ($0.recordedAt ?? .distantPast) < ($1.recordedAt ?? .distantPast) }
        case .longest:
            recs.sort { $0.estimatedDuration > $1.estimatedDuration }
        case .shortest:
            recs.sort { $0.estimatedDuration < $1.estimatedDuration }
        case .largest:
            recs.sort { $0.fileSizeBytes > $1.fileSizeBytes }
        case .smallest:
            recs.sort { $0.fileSizeBytes < $1.fileSizeBytes }
        }

        return recs
    }

    private func modeDisplayName(_ mode: String) -> String {
        FilenameParsing.RecordingMode(rawValue: mode)?.displayName ?? mode
    }
}

// MARK: - Library Row (clean — content only, actions via context menu)

private struct LibraryRow: View {
    let recording: RecordingMetadata
    let transcriptStatus: TranscriptStatus
    let isTranscribing: Bool
    let isCurrentlyPlaying: Bool

    var body: some View {
        HStack(spacing: 12) {
            // Mode icon
            ZStack {
                Circle()
                    .fill(modeColor.opacity(0.15))
                    .frame(width: 36, height: 36)
                Image(systemName: modeIcon)
                    .foregroundStyle(modeColor)
                    .font(.system(size: 14))
            }

            // Info
            VStack(alignment: .leading, spacing: 3) {
                Text(recording.displayTitle)
                    .font(.body.weight(.medium))
                HStack(spacing: 8) {
                    Text(modeLabel)
                        .font(.caption)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1)
                        .background(modeColor.opacity(0.1))
                        .foregroundStyle(modeColor)
                        .clipShape(Capsule())

                    Label(formattedDuration, systemImage: "clock")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Label(formattedSize, systemImage: "doc")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            // Status indicators
            HStack(spacing: 8) {
                if isCurrentlyPlaying {
                    Image(systemName: "speaker.wave.2.fill")
                        .font(.caption)
                        .foregroundStyle(Color.accentColor)
                        .symbolEffect(.variableColor.iterative, isActive: true)
                }

                if isTranscribing {
                    ProgressView()
                        .controlSize(.small)
                }

                transcriptBadge
            }
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private var transcriptBadge: some View {
        switch transcriptStatus {
        case .done:
            Image(systemName: "text.badge.checkmark")
                .font(.caption)
                .foregroundStyle(.green)
                .help("Transcribed — right-click to view")
        case .inProgress:
            Image(systemName: "text.badge.plus")
                .font(.caption)
                .foregroundStyle(.orange)
        case .failed:
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.caption)
                .foregroundStyle(.red)
                .help("Transcription failed")
        case .none:
            EmptyView()
        }
    }

    private var modeLabel: String {
        FilenameParsing.RecordingMode(rawValue: recording.mode)?.displayName ?? recording.mode
    }

    private var modeIcon: String {
        switch recording.mode {
        case "Rec": return "mic.fill"
        case "Pho": return "phone.fill"
        case "Mee": return "person.3.fill"
        case "Wip": return "pencil.line"
        default: return "waveform"
        }
    }

    private var modeColor: Color {
        switch recording.mode {
        case "Rec": return .blue
        case "Pho": return .green
        case "Mee": return .purple
        case "Wip": return .orange
        default: return .secondary
        }
    }

    private var formattedDuration: String {
        DurationCalculator.formatDuration(recording.estimatedDuration)
    }

    private var formattedSize: String {
        ByteCountFormatter.string(fromByteCount: Int64(recording.fileSizeBytes), countStyle: .file)
    }
}
