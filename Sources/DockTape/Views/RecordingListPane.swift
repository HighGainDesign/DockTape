import SwiftUI
import HiDockKit

/// Column 2: Shows recording list or device file list depending on sidebar selection.
struct RecordingListPane: View {
    @Bindable var state: AppState
    @State private var searchText = ""
    @AppStorage("librarySortBy") private var sortBy: LibrarySort = .dateNewest
    @AppStorage("libraryFilterMode") private var filterMode: String = ""
    @AppStorage("libraryFilterPeriod") private var filterPeriod: TimePeriod = .anyTime

    var body: some View {
        Group {
            switch state.selectedView {
            case .allRecordings, .folder:
                recordingsContent
            case .device:
                deviceContent
            }
        }
    }

    // MARK: - Recordings Content

    @ViewBuilder
    private var recordingsContent: some View {
        let recs = filteredRecordings
        List(selection: $state.library.selectedRecordings) {
            if state.library.recordings.isEmpty {
                // Empty library — no recordings at all
            } else {
                ForEach(recs) { rec in
                    RecordingRow(
                        recording: rec,
                        transcriptStatus: state.transcription.statuses[rec.filename] ?? .none,
                        isTranscribing: state.transcription.transcribingFile == rec.filename,
                        isCurrentlyPlaying: state.playback.playingFile == rec.filename && state.playback.isPlaying,
                        hasSummary: state.summarization.hasSummary.contains(rec.filename)
                    )
                    .tag(rec.filename)
                    .contextMenu { recordingContextMenu(for: rec) }
                    .draggable(rec.filename)
                }
            }
        }
        .listStyle(.inset(alternatesRowBackgrounds: true))
        .overlay {
            if state.library.recordings.isEmpty {
                ContentUnavailableView {
                    Label("No Recordings", systemImage: "waveform.slash")
                } description: {
                    if state.device.isConnected {
                        Text("Download recordings from your device to see them here.")
                    } else {
                        Text("Connect your HiDock and download recordings to get started.")
                    }
                }
            } else if recs.isEmpty {
                ContentUnavailableView.search(text: searchText)
            }
        }
        .searchable(text: $searchText, prompt: "Search recordings")
        .modifier(SearchFocusModifier(trigger: $state.library.isSearchFocused))
        .safeAreaInset(edge: .top, spacing: 0) { recordingListToolbar }
        .navigationTitle(recordingTitle)
        .onChange(of: state.selectedView) { _, _ in
            // Clear selection when switching sidebar sections
            state.library.selectedRecordings.removeAll()
            state.library.selectedRecording = nil
        }
        .onChange(of: state.library.selectedRecordings) { _, newValue in
            // Sync single selection for detail pane
            if newValue.count == 1 {
                state.library.selectedRecording = newValue.first
            } else if newValue.isEmpty {
                state.library.selectedRecording = nil
            }
        }
        .onKeyPress(.space) {
            guard state.library.selectedRecordings.count == 1,
                  let filename = state.library.selectedRecordings.first,
                  let rec = state.library.recordings.first(where: { $0.filename == filename })
            else { return .ignored }
            state.playRecording(rec)
            return .handled
        }
        .onKeyPress(.delete) {
            guard !state.library.selectedRecordings.isEmpty else { return .ignored }
            Task {
                for filename in state.library.selectedRecordings {
                    if let rec = state.library.recordings.first(where: { $0.filename == filename }) {
                        await state.deleteLocalRecording(rec)
                    }
                }
                state.library.selectedRecordings.removeAll()
            }
            return .handled
        }
    }

    private var recordingTitle: String {
        switch state.selectedView {
        case .allRecordings: return "All Recordings"
        case .folder(let name): return name
        case .device: return ""
        }
    }

    // MARK: - Device Content

    @ViewBuilder
    private var deviceContent: some View {
        let files = filteredDeviceFiles
        if state.device.files.isEmpty {
            ContentUnavailableView {
                Label("No Files on Device", systemImage: "tray")
            } description: {
                if let model = state.device.model {
                    Text("Your \(model.model.rawValue) has no recordings.")
                }
            }
        } else if files.isEmpty {
            ContentUnavailableView.search(text: searchText)
        } else {
            deviceFileList(files)
        }
    }

    private func deviceFileList(_ files: [FileEntry]) -> some View {
        List(selection: $state.device.selectedDeviceFiles) {
            ForEach(files) { file in
                DeviceFileRow(
                    file: file,
                    isDownloaded: state.library.isDownloaded(file.filename),
                    isDownloading: state.device.downloadingFiles.contains(file.filename),
                    isDeleting: state.device.deletingFiles.contains(file.filename)
                )
                .tag(file.filename)
                .contextMenu { deviceFileContextMenu(for: file) }
            }
        }
        .listStyle(.inset(alternatesRowBackgrounds: true))
        .searchable(text: $searchText, prompt: "Search files")
        .safeAreaInset(edge: .top, spacing: 0) { deviceListToolbar }
        .navigationTitle(state.device.model.map { "HiDock \($0.model.rawValue)" } ?? "On Device")
        .onChange(of: state.device.selectedDeviceFiles) { _, newValue in
            if newValue.count == 1 {
                state.device.selectedDeviceFile = newValue.first
            }
        }
        .onKeyPress(.return) {
            guard !state.device.selectedDeviceFiles.isEmpty else { return .ignored }
            Task {
                for file in selectedDeviceFiles {
                    await state.downloadFile(file)
                }
            }
            return .handled
        }
        .onKeyPress(.delete) {
            guard !state.device.selectedDeviceFiles.isEmpty else { return .ignored }
            Task {
                for file in selectedDeviceFiles {
                    await state.deleteFromDevice(file)
                }
                state.device.selectedDeviceFiles.removeAll()
            }
            return .handled
        }
    }

    // MARK: - Context Menus

    @ViewBuilder
    private func recordingContextMenu(for rec: RecordingMetadata) -> some View {
        let isPlaying = state.playback.playingFile == rec.filename && state.playback.isPlaying
        Button {
            state.playRecording(rec)
        } label: {
            Label(isPlaying ? "Pause" : "Play", systemImage: isPlaying ? "pause.fill" : "play.fill")
        }

        Divider()

        let status = state.transcription.statuses[rec.filename] ?? .none
        if state.transcription.transcribingFile == rec.filename {
            Button {
                state.transcription.cancel()
            } label: {
                Label("Cancel Transcription", systemImage: "xmark.circle")
            }
        } else {
            Button {
                Task { await state.transcribeRecordings([rec]) }
            } label: {
                Label(status == .done ? "Re-transcribe" : "Transcribe", systemImage: "text.badge.plus")
            }
        }

        Divider()

        let hasTranscript = (state.transcription.statuses[rec.filename] ?? .none) == .done
        let hasSummary = state.summarization.hasSummary.contains(rec.filename)
        Button {
            state.contextMenuSummarize(rec)
        } label: {
            Label(hasSummary ? "Re-summarize" : "Summarize", systemImage: "sparkles")
        }
        .disabled(!hasTranscript)

        Divider()

        if rec.folder != nil {
            Button {
                Task {
                    try? await state.library.moveRecording(filename: rec.filename, toFolder: nil)
                }
            } label: {
                Label("Move to Library Root", systemImage: "tray.and.arrow.up")
            }
        }

        // Move to folder submenu
        if !state.library.folders.isEmpty {
            let availableFolders = state.library.folders.filter { $0 != rec.folder }
            if !availableFolders.isEmpty {
                Menu("Move to Folder") {
                    ForEach(availableFolders, id: \.self) { folder in
                        Button(folder) {
                            Task {
                                try? await state.library.moveRecording(filename: rec.filename, toFolder: folder)
                            }
                        }
                    }
                }
            }
        }

        Divider()

        Button {
            state.library.revealInFinder(rec)
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

    @ViewBuilder
    private func deviceFileContextMenu(for file: FileEntry) -> some View {
        Button {
            Task { await state.downloadFile(file) }
        } label: {
            Label("Download", systemImage: "arrow.down.circle")
        }
        Divider()
        Button(role: .destructive) {
            Task { await state.deleteFromDevice(file) }
        } label: {
            Label("Delete from Device", systemImage: "trash")
        }
    }

    // MARK: - Inline Toolbars (per-pane, not window toolbar)

    /// Recordings list toolbar — sort/filter on left, refresh on right.
    private var recordingListToolbar: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                sortFilterMenu
                Spacer()
                toolbarButton("arrow.clockwise", "Refresh") {
                    Task { await state.library.refresh() }
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .frame(minHeight: 28)
            .background(.bar)
            Divider()
        }
    }

    /// Device list toolbar — sort/filter on left, device actions on right.
    private var deviceListToolbar: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                sortFilterMenu
                Spacer()
                toolbarButton("arrow.down.circle", "Download") {
                    Task {
                        for file in selectedDeviceFiles { await state.downloadFile(file) }
                    }
                }
                .disabled(state.device.selectedDeviceFiles.isEmpty || state.device.isSyncing)

                toolbarButton("trash", "Delete") {
                    Task {
                        for file in selectedDeviceFiles { await state.deleteFromDevice(file) }
                        state.device.selectedDeviceFiles.removeAll()
                    }
                }
                .disabled(state.device.selectedDeviceFiles.isEmpty)

                toolbarButton("arrow.clockwise", "Refresh") {
                    Task { await state.device.refreshDevice() }
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .frame(minHeight: 28)
            .background(.bar)
            Divider()
        }
    }

    /// Toolbar button with icon + text label, matching Sort/Filter style.
    private func toolbarButton(_ systemImage: String, _ label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(label, systemImage: systemImage)
                .font(.caption)
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .fixedSize()
        .help(label)
    }

    private var sortFilterMenu: some View {
        HStack(spacing: 12) {
            Menu {
                ForEach(LibrarySort.allCases, id: \.self) { sort in
                    Button {
                        sortBy = sort
                    } label: {
                        HStack {
                            Text(sort.rawValue)
                            if sortBy == sort { Image(systemName: "checkmark") }
                        }
                    }
                }
            } label: {
                Label("Sort", systemImage: "arrow.up.arrow.down")
                    .font(.caption)
            }
            .menuStyle(.borderedButton)
            .fixedSize()
            .controlSize(.small)
            .help("Sort")

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
                                if filterPeriod == period { Image(systemName: "checkmark") }
                            }
                        }
                    }
                }
            } label: {
                let isActive = !filterMode.isEmpty || filterPeriod != .anyTime
                Label("Filter",
                      systemImage: isActive ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle")
                    .font(.caption)
            }
            .menuStyle(.borderedButton)
            .fixedSize()
            .controlSize(.small)
            .help("Filter")
        }
    }

    // MARK: - Helpers

    private var selectedRecordings: [RecordingMetadata] {
        state.library.recordings.filter { state.library.selectedRecordings.contains($0.filename) }
    }

    private var selectedDeviceFiles: [FileEntry] {
        state.device.files.filter { state.device.selectedDeviceFiles.contains($0.filename) }
    }

    private var filteredRecordings: [RecordingMetadata] {
        var recs: [RecordingMetadata]
        switch state.selectedView {
        case .folder(let folder):
            recs = state.library.recordings.filter { $0.folder == folder }
        default:
            recs = state.library.recordings
        }

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
                $0.displayTitle.lowercased().contains(query)
            }
        }

        switch sortBy {
        case .dateNewest:  recs.sort { ($0.recordedAt ?? .distantPast) > ($1.recordedAt ?? .distantPast) }
        case .dateOldest:  recs.sort { ($0.recordedAt ?? .distantPast) < ($1.recordedAt ?? .distantPast) }
        case .longest:     recs.sort { $0.estimatedDuration > $1.estimatedDuration }
        case .shortest:    recs.sort { $0.estimatedDuration < $1.estimatedDuration }
        case .largest:     recs.sort { $0.fileSizeBytes > $1.fileSizeBytes }
        case .smallest:    recs.sort { $0.fileSizeBytes < $1.fileSizeBytes }
        }

        return recs
    }

    private var filteredDeviceFiles: [FileEntry] {
        let files = state.device.files
        let parsed = Dictionary(uniqueKeysWithValues: files.map {
            ($0.filename, FilenameParsing.parse($0.filename))
        })

        var result = files

        if !filterMode.isEmpty {
            let mode = FilenameParsing.RecordingMode(rawValue: filterMode) ?? .unknown
            result = result.filter { parsed[$0.filename]?.mode == mode }
        }
        if let startDate = filterPeriod.startDate {
            result = result.filter { (parsed[$0.filename]?.date ?? .distantPast) >= startDate }
        }
        if !searchText.isEmpty {
            let query = searchText.lowercased()
            result = result.filter { $0.filename.lowercased().contains(query) }
        }

        switch sortBy {
        case .dateNewest:  result.sort { (parsed[$0.filename]?.date ?? .distantPast) > (parsed[$1.filename]?.date ?? .distantPast) }
        case .dateOldest:  result.sort { (parsed[$0.filename]?.date ?? .distantPast) < (parsed[$1.filename]?.date ?? .distantPast) }
        case .longest:     result.sort { DurationCalculator.estimateDuration(fileSize: UInt64($0.size)) > DurationCalculator.estimateDuration(fileSize: UInt64($1.size)) }
        case .shortest:    result.sort { DurationCalculator.estimateDuration(fileSize: UInt64($0.size)) < DurationCalculator.estimateDuration(fileSize: UInt64($1.size)) }
        case .largest:     result.sort { $0.size > $1.size }
        case .smallest:    result.sort { $0.size < $1.size }
        }

        return result
    }
}

// MARK: - Sort & Filter Enums

enum LibrarySort: String, CaseIterable {
    case dateNewest = "Newest First"
    case dateOldest = "Oldest First"
    case longest = "Longest First"
    case shortest = "Shortest First"
    case largest = "Largest First"
    case smallest = "Smallest First"
}

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

// MARK: - Recording Row

struct RecordingRow: View {
    let recording: RecordingMetadata
    let transcriptStatus: TranscriptStatus
    let isTranscribing: Bool
    let isCurrentlyPlaying: Bool
    let hasSummary: Bool

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                Circle()
                    .fill(modeColor.opacity(0.15))
                    .frame(width: 36, height: 36)
                Image(systemName: modeIcon)
                    .foregroundStyle(modeColor)
                    .font(.system(size: 14))
            }

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

            HStack(spacing: 8) {
                if isCurrentlyPlaying {
                    Image(systemName: "speaker.wave.2.fill")
                        .font(.caption)
                        .foregroundStyle(Color.accentColor)
                        .symbolEffect(.variableColor.iterative, isActive: true)
                }
                if isTranscribing {
                    ProgressView().controlSize(.small)
                }
                transcriptBadge
                if hasSummary {
                    Image(systemName: "sparkles")
                        .font(.caption).foregroundStyle(.purple)
                        .help("Summarized")
                }
            }
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private var transcriptBadge: some View {
        switch transcriptStatus {
        case .done:
            Image(systemName: "text.badge.checkmark")
                .font(.caption).foregroundStyle(.green)
                .help("Transcribed")
        case .inProgress:
            Image(systemName: "text.badge.plus")
                .font(.caption).foregroundStyle(.orange)
        case .failed:
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.caption).foregroundStyle(.red)
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

// MARK: - Device File Row

struct DeviceFileRow: View {
    let file: FileEntry
    let isDownloaded: Bool
    let isDownloading: Bool
    let isDeleting: Bool

    private let parsed: FilenameParsing.ParsedFilename

    init(file: FileEntry, isDownloaded: Bool, isDownloading: Bool, isDeleting: Bool) {
        self.file = file
        self.isDownloaded = isDownloaded
        self.isDownloading = isDownloading
        self.isDeleting = isDeleting
        self.parsed = FilenameParsing.parse(file.filename)
    }

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                Circle()
                    .fill(modeColor.opacity(0.15))
                    .frame(width: 36, height: 36)
                Image(systemName: modeIcon)
                    .foregroundStyle(modeColor)
                    .font(.system(size: 14))
            }
            .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 3) {
                Text(displayName)
                    .font(.body.weight(.medium))
                HStack(spacing: 8) {
                    Text(parsed.mode.displayName)
                        .font(.caption)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1)
                        .background(modeColor.opacity(0.1))
                        .foregroundStyle(modeColor)
                        .clipShape(Capsule())

                    Label(formattedDuration, systemImage: "clock")
                        .font(.caption).foregroundStyle(.secondary)

                    Label(formattedSize, systemImage: "doc")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }

            Spacer()

            HStack(spacing: 6) {
                if isDownloading { ProgressView().controlSize(.small).accessibilityLabel("Downloading") }
                if isDeleting { ProgressView().controlSize(.small).accessibilityLabel("Deleting") }
                if isDownloaded {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.caption).foregroundStyle(.green)
                        .accessibilityLabel("Already downloaded")
                }
            }
        }
        .padding(.vertical, 4)
    }

    private static let dateFormatter: DateFormatter = {
        let fmt = DateFormatter()
        fmt.dateStyle = .medium
        fmt.timeStyle = .short
        return fmt
    }()

    private var displayName: String {
        if let date = parsed.date { return Self.dateFormatter.string(from: date) }
        return file.filename
    }

    private var modeIcon: String {
        switch parsed.mode {
        case .standard: return "mic.fill"
        case .phone: return "phone.fill"
        case .meeting: return "person.3.fill"
        case .wip: return "pencil.line"
        case .unknown: return "waveform"
        }
    }

    private var modeColor: Color {
        switch parsed.mode {
        case .standard: return .blue
        case .phone: return .green
        case .meeting: return .purple
        case .wip: return .orange
        case .unknown: return .secondary
        }
    }

    private var formattedSize: String {
        ByteCountFormatter.string(fromByteCount: Int64(file.size), countStyle: .file)
    }

    private var formattedDuration: String {
        DurationCalculator.formatDuration(DurationCalculator.estimateDuration(fileSize: UInt64(file.size)))
    }
}
