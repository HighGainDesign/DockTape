// © 2026 High Gain Design. All rights reserved.

import Foundation

/// Waits for iCloud bytes without blocking a store actor or the UI executor.
public struct RecordingFileAccess: Sendable {
    enum Availability: Sendable {
        case missing
        case local
        case downloading(URL)
    }

    private let availability: @Sendable (URL) async throws -> Availability
    private let requestDownload: @Sendable (URL) async throws -> Void
    private let readFile: @Sendable (URL) async throws -> Data
    private let timeout: Duration

    public init() {
        self.init(availability: { try await Self.fileAvailability($0) },
                  requestDownload: { try await Self.startDownload($0) })
    }

    init(availability: @escaping @Sendable (URL) async throws -> Availability,
         requestDownload: @escaping @Sendable (URL) async throws -> Void,
         timeout: Duration = .seconds(300),
         readFile: @escaping @Sendable (URL) async throws -> Data = { try await Self.readFileData($0) }) {
        self.availability = availability
        self.requestDownload = requestDownload
        self.timeout = timeout
        self.readFile = readFile
    }

    /// False means absent, rather than a cloud file still waiting to download.
    public func waitUntilAvailable(at url: URL, knownToExist: Bool = false,
                                  onWaiting: @Sendable () async -> Void = {}) async throws -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        var requested = false
        while true {
            try Task.checkCancellation()
            switch try await availability(url) {
            case .missing:
                // Providers can briefly remove a placeholder before publishing
                // the downloaded file. A requested download is not missing.
                if !requested {
                    if !knownToExist { return false }
                    await onWaiting()
                    try Task.checkCancellation()
                    try await requestDownload(url)
                    requested = true
                }
            case .local: return true
            case .downloading(let sourceURL):
                if !requested {
                    await onWaiting()
                    try Task.checkCancellation()
                    try await requestDownload(sourceURL)
                    requested = true
                }
            }
            guard clock.now < deadline else { throw DownloadError.timedOut }
            try await Task.sleep(for: .milliseconds(250))
        }
    }

    public func readDataIfPresent(at url: URL, knownToExist: Bool = false,
                                  onWaiting: @Sendable () async -> Void = {}) async throws -> Data? {
        guard try await waitUntilAvailable(at: url, knownToExist: knownToExist, onWaiting: onWaiting) else { return nil }
        try Task.checkCancellation()
        let data = try await readFile(url)
        try Task.checkCancellation()
        return data
    }

    private static func readFileData(_ url: URL) async throws -> Data {
        // A file can be evicted between the metadata check and the read.
        // Keep even that synchronous hydration off the store actor executor.
        let read = Task.detached(priority: .userInitiated) {
            try Task.checkCancellation()
            return try Data(contentsOf: url)
        }
        return try await withTaskCancellationHandler {
            try await read.value
        } onCancel: {
            read.cancel()
        }
    }

    private static func fileAvailability(_ target: URL) async throws -> Availability {
        try await Task.detached(priority: .userInitiated) {
            let fm = FileManager.default
            var source = target
            if !fm.fileExists(atPath: target.path) {
                source = target.deletingLastPathComponent()
                    .appendingPathComponent(".\(target.lastPathComponent).icloud")
                guard fm.fileExists(atPath: source.path) else { return Availability.missing }
            }
            source.removeAllCachedResourceValues()
            let values = try source.resourceValues(forKeys: [
                .isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey,
                .ubiquitousItemDownloadingErrorKey
            ])
            if let error = values.ubiquitousItemDownloadingError { throw error }
            if source != target || values.ubiquitousItemDownloadingStatus == .notDownloaded {
                return Availability.downloading(source)
            }
            return Availability.local
        }.value
    }

    private static func startDownload(_ url: URL) async throws {
        try await Task.detached(priority: .userInitiated) {
            try FileManager.default.startDownloadingUbiquitousItem(at: url)
        }.value
    }

    public enum DownloadError: LocalizedError {
        case timedOut

        public var errorDescription: String? {
            "iCloud Drive has not finished downloading this file. Check your connection and iCloud Drive in Finder, then try again."
        }
    }
}
