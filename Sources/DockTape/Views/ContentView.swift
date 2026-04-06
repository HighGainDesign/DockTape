import SwiftUI
import HiDockKit

struct ContentView: View {
    @Bindable var state: AppState

    var body: some View {
        NavigationSplitView {
            sidebar
        } detail: {
            VStack(spacing: 0) {
                detailView
                    .frame(maxHeight: .infinity)

                if state.playingFile != nil {
                    NowPlayingBar(state: state)
                }

                if state.transcribingFile != nil {
                    TranscriptionBar(state: state)
                }
            }
        }
        .navigationTitle("")
        .frame(minWidth: 800, minHeight: 500)
        .focusedSceneValue(\.appState, state)
        .sheet(isPresented: $state.showDownloadProgress) {
            DownloadProgressView(
                filename: state.downloadFilename,
                progress: state.downloadProgress
            )
        }
        .sheet(isPresented: $state.showDeviceInfo) {
            NavigationStack {
                DeviceInfoView(state: state)
            }
        }
        .sheet(isPresented: Binding(
            get: { state.errorMessage != nil },
            set: { if !$0 { state.errorMessage = nil } }
        )) {
            VStack(spacing: 16) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.largeTitle)
                    .foregroundStyle(.red)
                Text("Error")
                    .font(.headline)
                Text(state.errorMessage ?? "")
                    .font(.body)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Button("Dismiss") { state.errorMessage = nil }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(24)
            .frame(minWidth: 400, maxWidth: 500)
        }
    }

    @ViewBuilder
    private var detailView: some View {
        switch state.selectedView {
        case .library:
            LibraryView(state: state)
        case .onDevice:
            if state.isConnected {
                DeviceFilesView(state: state)
            } else {
                EmptyStateView()
            }
        }
    }

    // MARK: - Sidebar

    private var sidebar: some View {
        VStack(spacing: 0) {
            List(selection: $state.selectedView) {
                Label {
                    HStack {
                        Text("Library")
                        Spacer()
                        if state.recordings.count > 0 {
                            Text("\(state.recordings.count)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(.quaternary)
                                .clipShape(Capsule())
                        }
                    }
                } icon: {
                    Image(systemName: "folder")
                }
                .tag(SidebarSelection.library)

                if state.isConnected, let device = state.device {
                    Label {
                        HStack {
                            Text("HiDock \(device.model.rawValue)")
                            Spacer()
                            Text("\(device.files.count)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(.quaternary)
                                .clipShape(Capsule())
                        }
                    } icon: {
                        Image(systemName: "waveform")
                    }
                    .tag(SidebarSelection.onDevice)
                }
            }
            .listStyle(.sidebar)

            Divider()
            deviceStatusBar
        }
        .frame(minWidth: 200)
    }

    @ViewBuilder
    private var deviceStatusBar: some View {
        if state.isConnected, let device = state.device {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    Circle()
                        .fill(.green)
                        .frame(width: 8, height: 8)
                    Text("HiDock \(device.model.rawValue)")
                        .font(.caption.weight(.medium))
                    Spacer()
                    Button {
                        state.showDeviceInfo = true
                    } label: {
                        Image(systemName: "info.circle")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.borderless)
                    .help("Device Info")
                }

                if let battery = device.battery {
                    VStack(alignment: .leading, spacing: 3) {
                        HStack {
                            Image(systemName: battery.isCharging ? "bolt.fill" : "battery.100")
                                .font(.caption2)
                                .foregroundStyle(batteryColor(battery.level))
                            Text("Battery")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                            Spacer()
                            Text("\(battery.level)%")
                                .font(.caption2.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                        ProgressView(value: Double(battery.level), total: 100)
                            .tint(batteryColor(battery.level))
                            .controlSize(.small)
                    }
                }

                if let card = device.cardInfo, card.isInserted {
                    VStack(alignment: .leading, spacing: 3) {
                        HStack {
                            Image(systemName: "internaldrive")
                                .font(.caption2)
                                .foregroundStyle(storageColor(card.usagePercent))
                            Text("Storage")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                            Spacer()
                            let freeGB = Double(card.freeBytes) / 1_073_741_824
                            let totalGB = Double(card.totalBytes) / 1_073_741_824
                            Text(String(format: "%.1f / %.1f GB", freeGB, totalGB))
                                .font(.caption2.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                        ProgressView(value: card.usagePercent, total: 100)
                            .tint(storageColor(card.usagePercent))
                            .controlSize(.small)
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
        } else {
            HStack(spacing: 6) {
                Circle()
                    .fill(.secondary.opacity(0.5))
                    .frame(width: 8, height: 8)
                Text("No device connected")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
        }
    }

    private func batteryColor(_ level: Int) -> Color {
        switch level {
        case 51...100: return .green
        case 21...50: return .yellow
        default: return .red
        }
    }

    private func storageColor(_ percent: Double) -> Color {
        switch percent {
        case 90...: return .red
        case 75..<90: return .orange
        default: return .green
        }
    }
}

// MARK: - Now Playing Bar

struct NowPlayingBar: View {
    @Bindable var state: AppState
    @State private var isSeeking = false
    @State private var seekValue: Double = 0

    private static let speeds: [Float] = [0.5, 0.75, 1.0, 1.25, 1.5, 2.0, 3.0]

    var body: some View {
        VStack(spacing: 0) {
            Divider()
            HStack(spacing: 12) {
                Button {
                    state.togglePlayPause()
                } label: {
                    Image(systemName: state.isPlaying ? "pause.fill" : "play.fill")
                        .frame(width: 20)
                }
                .buttonStyle(.borderless)

                if let file = state.playingFile {
                    let rec = state.recordings.first { $0.filename == file }
                    Text(rec?.displayTitle ?? file)
                        .font(.caption)
                        .lineLimit(1)
                }

                Text(formatTime(isSeeking ? seekValue : state.playbackProgress))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)

                Slider(
                    value: Binding(
                        get: { isSeeking ? seekValue : state.playbackProgress },
                        set: { seekValue = $0 }
                    ),
                    in: 0...max(state.playbackDuration, 1)
                ) { editing in
                    if editing {
                        isSeeking = true
                    } else {
                        state.seekPlayback(to: seekValue)
                        isSeeking = false
                    }
                }
                .controlSize(.small)

                Text(formatTime(state.playbackDuration))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)

                // Playback speed picker
                Menu {
                    ForEach(Self.speeds, id: \.self) { speed in
                        Button {
                            state.setPlaybackRate(speed)
                        } label: {
                            HStack {
                                Text(speedLabel(speed))
                                if state.playbackRate == speed {
                                    Image(systemName: "checkmark")
                                }
                            }
                        }
                    }
                } label: {
                    Text(speedLabel(state.playbackRate))
                        .font(.caption.monospacedDigit().weight(.medium))
                        .frame(minWidth: 30)
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .help("Playback speed")

                Button {
                    state.stopPlayback()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(.bar)
        }
    }

    private func formatTime(_ seconds: Double) -> String {
        let total = Int(seconds)
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        if h > 0 {
            return String(format: "%d:%02d:%02d", h, m, s)
        }
        return String(format: "%d:%02d", m, s)
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
    @State private var elapsed: TimeInterval = 0
    private let elapsedTimer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    private var queueTotal: Int { state.transcriptionQueue.count }
    private var queueIndex: Int { state.transcriptionQueueIndex }

    var body: some View {
        VStack(spacing: 0) {
            Divider()
            HStack(spacing: 12) {
                ProgressView()
                    .controlSize(.small)

                if let file = state.transcribingFile {
                    let rec = state.recordings.first { $0.filename == file }
                    VStack(alignment: .leading, spacing: 1) {
                        HStack(spacing: 6) {
                            Text(state.transcriptionPhase)
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

                // Elapsed time
                Text(formatElapsed(elapsed))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)

                Button {
                    state.cancelTranscription()
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
        .onReceive(elapsedTimer) { _ in
            if let start = state.transcriptionStartTime {
                elapsed = Date().timeIntervalSince(start)
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

// MARK: - Search Focus Modifier (macOS 15+ conditional)

struct SearchFocusModifier: ViewModifier {
    @Binding var trigger: Bool
    @FocusState private var isSearchFocused: Bool

    func body(content: Content) -> some View {
        if #available(macOS 15.0, *) {
            content
                .searchFocused($isSearchFocused)
                .onChange(of: trigger) { _, focused in
                    if focused {
                        isSearchFocused = true
                        trigger = false
                    }
                }
        } else {
            content
        }
    }
}
