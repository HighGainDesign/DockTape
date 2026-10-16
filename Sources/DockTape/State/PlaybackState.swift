// © 2026 High Gain Design. All rights reserved.

import SwiftUI
import AVFoundation
import HiDockKit

@Observable
@MainActor
final class PlaybackState {
    struct Lease: Sendable {
        let validate: @Sendable () async throws -> Void
        let release: @Sendable () async -> Void
    }
    var acquireLease: (@Sendable (String, URL, SharedRecordingReference?) async throws -> Lease)?
    private var playbackLease: Lease?

    var playingFile: String?
    var isPlaying: Bool = false
    var rate: Float = 1.0
    var progress: Double = 0
    var duration: Double = 0
    var activeSegmentIndex: Int?
    private(set) var isPreparing = false
    private(set) var preparationMessage = "Preparing recording…"
    private(set) var loadError: String?

    private var preparationTask: Task<Void, Never>?
    private var preparingAsset: AVURLAsset?
    private var requestID = UUID()
    private var requestedURL: URL?
    private(set) var requestedReference: SharedRecordingReference?
    private var pendingSeek: Double?
    private let prepareFile: @Sendable (URL, @escaping @Sendable () async -> Void) async throws -> Bool

    init(prepareFile: @escaping @Sendable (URL, @escaping @Sendable () async -> Void) async throws -> Bool = {
        url, waiting in try await RecordingFileAccess().waitUntilAvailable(at: url, knownToExist: true, onWaiting: waiting)
    }) {
        self.prepareFile = prepareFile
    }

    private(set) var avPlayer: AVPlayer?
    private var endOfPlaybackObserver: NSObjectProtocol?
    private var timeObserver: Any?
    private var boundaryObserver: Any?
    private var appNapActivity: NSObjectProtocol?

    private(set) var segmentTimestamps: [(start: Double, end: Double)] = [] {
        didSet { setupBoundaryObserver() }
    }

    /// Read current playback position directly from AVPlayer (for TimelineView-driven UI).
    var currentTime: Double {
        avPlayer?.currentTime().seconds ?? 0
    }

    static let speeds: [Float] = [0.5, 0.75, 1.0, 1.25, 1.5, 2.0, 3.0]

    func play(file: String, url: URL, reference: SharedRecordingReference? = nil) {
        if playingFile == file, requestedReference == reference {
            if isPreparing { stop(); return }
            if avPlayer != nil { togglePlayPause(); return }
        }
        stop()
        playingFile = file
        requestedURL = url
        requestedReference = reference
        isPreparing = true
        preparationMessage = "Preparing recording…"
        let request = requestID
        preparationTask = Task { [weak self] in
            guard let self else { return }
            do {
                if let acquireLease {
                    let lease = try await acquireLease(file, url, reference)
                    guard requestID == request, !Task.isCancelled else { await lease.release(); return }
                    playbackLease = lease
                }
                guard try await prepareFile(url, { [weak self] in
                    await self?.markCloudDownload(for: request)
                }) else { throw CocoaError(.fileReadNoSuchFile) }
                try Task.checkCancellation()
                let asset = AVURLAsset(url: url)
                preparingAsset = asset
                let measuredDuration = try await asset.load(.duration)
                try await playbackLease?.validate()
                try Task.checkCancellation()
                guard requestID == request else { return }
                isPreparing = false
                preparationTask = nil
                preparingAsset = nil
                duration = measuredDuration.seconds.isFinite ? measuredDuration.seconds : 0
                startPlayer(url: url)
                if let seekTime = pendingSeek {
                    pendingSeek = nil
                    seek(to: seekTime)
                }
            } catch {
                guard requestID == request, !Task.isCancelled else { return }
                isPreparing = false
                preparationTask = nil
                preparingAsset = nil
                releasePlaybackLease()
                loadError = error.localizedDescription
            }
        }
    }

    private func markCloudDownload(for request: UUID) {
        guard requestID == request else { return }
        preparationMessage = "Downloading recording from iCloud Drive…"
    }

    func retry() {
        guard let file = playingFile, let url = requestedURL else { return }
        play(file: file, url: url, reference: requestedReference)
    }

    private func startPlayer(url: URL) {
        let playerItem = AVPlayerItem(url: url)
        playerItem.preferredForwardBufferDuration = 2
        let player = AVPlayer(playerItem: playerItem)
        player.automaticallyWaitsToMinimizeStalling = false

        avPlayer = player
        isPlaying = true

        // Prevent App Nap during playback
        appNapActivity = ProcessInfo.processInfo.beginActivity(
            options: .userInitiated,
            reason: "Audio playback"
        )

        // Periodic time observer — caches progress for seek-on-pause, etc.
        let interval = CMTime(seconds: 0.25, preferredTimescale: 600)
        timeObserver = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
            MainActor.assumeIsolated {
                guard let self, self.avPlayer === player else { return }
                self.progress = time.seconds
            }
        }

        // End-of-playback
        endOfPlaybackObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: playerItem,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.avPlayer?.currentItem === playerItem else { return }
                self.stop()
            }
        }

        player.rate = rate
        setupBoundaryObserver()
    }

    func togglePlayPause() {
        if isPreparing { stop(); return }
        guard let player = avPlayer else { return }
        if isPlaying {
            player.pause()
            isPlaying = false
        } else {
            player.rate = rate
            isPlaying = true
        }
    }

    private func releasePlaybackLease() {
        let previous = playbackLease
        playbackLease = nil
        if let previous { Task { await previous.release() } }
    }

    func stop() {
        releasePlaybackLease()
        requestID = UUID()
        preparingAsset?.cancelLoading()
        preparingAsset = nil
        preparationTask?.cancel()
        preparationTask = nil
        isPreparing = false
        loadError = nil
        requestedURL = nil
        requestedReference = nil
        pendingSeek = nil
        if let obs = endOfPlaybackObserver {
            NotificationCenter.default.removeObserver(obs)
            endOfPlaybackObserver = nil
        }
        if let obs = timeObserver {
            avPlayer?.removeTimeObserver(obs)
            timeObserver = nil
        }
        if let obs = boundaryObserver {
            avPlayer?.removeTimeObserver(obs)
            boundaryObserver = nil
        }
        if let activity = appNapActivity {
            ProcessInfo.processInfo.endActivity(activity)
            appNapActivity = nil
        }
        avPlayer?.pause()
        avPlayer = nil
        playingFile = nil
        isPlaying = false
        progress = 0
        duration = 0
        activeSegmentIndex = nil
        segmentTimestamps = []
    }

    /// Ignore a transcript load that completed after playback switched files.
    func setSegmentTimestamps(_ timestamps: [(start: Double, end: Double)], for filename: String) {
        guard playingFile == filename else { return }
        segmentTimestamps = timestamps
        updateActiveSegment()
    }

    func seek(to time: Double) {
        if isPreparing {
            pendingSeek = time
            progress = time
            return
        }
        let cmTime = CMTime(seconds: time, preferredTimescale: 600)
        avPlayer?.seek(to: cmTime)
        progress = time
        updateActiveSegment()
    }

    func setRate(_ newRate: Float) {
        rate = newRate
        if let player = avPlayer, isPlaying {
            player.rate = newRate
        }
    }

    private func setupBoundaryObserver() {
        // Remove old observer
        if let obs = boundaryObserver {
            avPlayer?.removeTimeObserver(obs)
            boundaryObserver = nil
        }

        guard let player = avPlayer, !segmentTimestamps.isEmpty else { return }

        let times = segmentTimestamps.map {
            NSValue(time: CMTime(seconds: $0.start, preferredTimescale: 600))
        }

        boundaryObserver = player.addBoundaryTimeObserver(
            forTimes: times, queue: .main
        ) { [weak self] in
            MainActor.assumeIsolated {
                self?.updateActiveSegment()
            }
        }

        // Set initial active segment for current position (boundary observer
        // only fires on future crossings, not retroactively)
        updateActiveSegment()
    }

    func updateActiveSegment() {
        guard avPlayer != nil, !segmentTimestamps.isEmpty else {
            activeSegmentIndex = nil
            return
        }
        let t = currentTime
        activeSegmentIndex = segmentTimestamps.lastIndex { t >= $0.start && t < $0.end }
            ?? segmentTimestamps.lastIndex { t >= $0.start }
            ?? 0 // Before first segment — highlight it as "up next"
    }
}
