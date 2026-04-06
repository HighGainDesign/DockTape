import SwiftUI
import HiDockKit

struct DeviceFilesView: View {
    @Bindable var state: AppState
    @State private var searchText = ""
    @State private var sortBy: DeviceSort = .dateNewest
    @State private var filterMode: FilenameParsing.RecordingMode? = nil
    @State private var filterPeriod: TimePeriod = .anyTime

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
    @State private var selection: Set<String> = []

    enum DeviceSort: String, CaseIterable {
        case dateNewest = "Newest First"
        case dateOldest = "Oldest First"
        case longest = "Longest First"
        case shortest = "Shortest First"
        case largest = "Largest First"
        case smallest = "Smallest First"
    }

    var body: some View {
        VStack(spacing: 0) {
            if let device = state.device {
                if device.files.isEmpty {
                    ContentUnavailableView {
                        Label("No Files on Device", systemImage: "tray")
                    } description: {
                        Text("Your \(device.model.rawValue) has no recordings.")
                    }
                } else if filteredFiles(device.files).isEmpty {
                    ContentUnavailableView.search(text: searchText)
                } else {
                    deviceFileList(device.files)
                }
            }
        }
        .searchable(text: $searchText, prompt: "Search files")
        .modifier(SearchFocusModifier(trigger: $state.isSearchFocused))
        .toolbar {
            toolbarContent
        }
        .navigationTitle(state.device.map { "HiDock \($0.model.rawValue)" } ?? "On Device")
        .onAppear {
            if selection.isEmpty, let device = state.device,
               let first = filteredFiles(device.files).first {
                selection = [first.filename]
            }
        }
        .onChange(of: state.device?.files.count ?? 0) {
            if selection.isEmpty, let device = state.device,
               let first = filteredFiles(device.files).first {
                selection = [first.filename]
            }
        }
        .onKeyPress(.return) {
            guard !selection.isEmpty else { return .ignored }
            Task {
                for file in selectedFiles {
                    await state.downloadFile(file)
                }
            }
            return .handled
        }
        .onKeyPress(.delete) {
            guard !selection.isEmpty else { return .ignored }
            Task {
                for file in selectedFiles {
                    await state.deleteFromDevice(file)
                }
                selection.removeAll()
            }
            return .handled
        }
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        // Actions — always visible, disabled when not applicable
        ToolbarItemGroup(placement: .automatic) {
            let hasSelection = !selection.isEmpty

            Button {
                Task {
                    for file in selectedFiles {
                        await state.downloadFile(file)
                    }
                }
            } label: {
                Label("Download", systemImage: "arrow.down.circle")
            }
            .disabled(!hasSelection || state.isSyncing)
            .help("Download selected (Return)")

            Button(role: .destructive) {
                Task {
                    for file in selectedFiles {
                        await state.deleteFromDevice(file)
                    }
                    selection.removeAll()
                }
            } label: {
                Label("Delete", systemImage: "trash")
            }
            .disabled(!hasSelection)
            .help("Delete from device (⌫)")

            Button {
                Task { await state.refreshDevice() }
            } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
            }
            .keyboardShortcut("r", modifiers: .command)
            .help("Refresh device files (⌘R)")
        }

        // Sort & Filter (trailing, before search)
        ToolbarItemGroup(placement: .primaryAction) {
            Menu {
                ForEach(DeviceSort.allCases, id: \.self) { sort in
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
            .help("Sort files")

            Menu {
                Section("Type") {
                    Button("All") { filterMode = nil }
                    Button("Recording") { filterMode = .standard }
                    Button("Phone") { filterMode = .phone }
                    Button("Meeting") { filterMode = .meeting }
                    Button("WIP") { filterMode = .wip }
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
                let isActive = filterMode != nil || filterPeriod != .anyTime
                Label(filterLabel,
                      systemImage: isActive ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle")
            }
            .help("Filter by type or date")
        }
    }

    // MARK: - Device File List

    private func deviceFileList(_ files: [FileEntry]) -> some View {
        List(selection: $selection) {
            ForEach(filteredFiles(files)) { file in
                DeviceFileRow(
                    file: file,
                    isDownloaded: state.isDownloaded(file.filename),
                    isDownloading: state.downloadingFiles.contains(file.filename),
                    isDeleting: state.deletingFiles.contains(file.filename)
                )
                .tag(file.filename)
                .contextMenu {
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
            }
        }
        .listStyle(.inset(alternatesRowBackgrounds: true))
    }

    // MARK: - Selection Helpers

    private var selectedFiles: [FileEntry] {
        guard let device = state.device else { return [] }
        return device.files.filter { selection.contains($0.filename) }
    }


    // MARK: - Filtering

    private var filterLabel: String {
        if let mode = filterMode, filterPeriod != .anyTime {
            return "\(mode.displayName), \(filterPeriod.rawValue)"
        } else if let mode = filterMode {
            return mode.displayName
        } else if filterPeriod != .anyTime {
            return filterPeriod.rawValue
        }
        return "Filter"
    }

    private func filteredFiles(_ files: [FileEntry]) -> [FileEntry] {
        var result = files

        if let mode = filterMode {
            result = result.filter { FilenameParsing.parse($0.filename).mode == mode }
        }

        if let startDate = filterPeriod.startDate {
            result = result.filter { (FilenameParsing.parse($0.filename).date ?? .distantPast) >= startDate }
        }

        if !searchText.isEmpty {
            let query = searchText.lowercased()
            result = result.filter { $0.filename.lowercased().contains(query) }
        }

        switch sortBy {
        case .dateNewest:
            result.sort { FilenameParsing.parse($0.filename).date ?? .distantPast > FilenameParsing.parse($1.filename).date ?? .distantPast }
        case .dateOldest:
            result.sort { FilenameParsing.parse($0.filename).date ?? .distantPast < FilenameParsing.parse($1.filename).date ?? .distantPast }
        case .longest:
            result.sort { $0.size > $1.size }
        case .shortest:
            result.sort { $0.size < $1.size }
        case .largest:
            result.sort { $0.size > $1.size }
        case .smallest:
            result.sort { $0.size < $1.size }
        }

        return result
    }
}

// MARK: - Device File Row (clean — content only, actions via context menu)

private struct DeviceFileRow: View {
    let file: FileEntry
    let isDownloaded: Bool
    let isDownloading: Bool
    let isDeleting: Bool

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
                Text(displayName)
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
            HStack(spacing: 6) {
                if isDownloading {
                    ProgressView()
                        .controlSize(.small)
                }

                if isDeleting {
                    ProgressView()
                        .controlSize(.small)
                }

                if isDownloaded {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(.green)
                        .help("Already downloaded")
                }
            }
        }
        .padding(.vertical, 4)
    }

    private var parsed: FilenameParsing.ParsedFilename {
        FilenameParsing.parse(file.filename)
    }

    private var displayName: String {
        if let date = parsed.date {
            let fmt = DateFormatter()
            fmt.dateStyle = .medium
            fmt.timeStyle = .short
            return fmt.string(from: date)
        }
        return file.filename
    }

    private var modeLabel: String {
        parsed.mode.displayName
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
