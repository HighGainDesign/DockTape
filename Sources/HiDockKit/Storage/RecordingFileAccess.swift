// © 2026 High Gain Design. All rights reserved.

import Foundation
import Darwin

/// Prepares cloud/provider bytes without blocking a store actor or UI executor.
public struct RecordingFileAccess: Sendable {
    enum Availability: Sendable {
        case missing
        case local
        case downloading(URL)
        case providerManaged(URL)
    }

    private let availability: @Sendable (URL) async throws -> Availability
    private let requestDownload: @Sendable (URL) async throws -> Void
    private let prepareProvider: @Sendable (URL) async throws -> Void
    private let readFile: @Sendable (URL) async throws -> Data
    private let timeout: Duration

    public init() {
        self.init(
            availability: { try await Self.fileAvailability($0) },
            requestDownload: { try await Self.startDownload($0) })
    }

    init(
        availability: @escaping @Sendable (URL) async throws -> Availability,
        requestDownload: @escaping @Sendable (URL) async throws -> Void,
        timeout: Duration = .seconds(300),
        prepareProvider: @escaping @Sendable (URL) async throws -> Void = { try await Self.prepareCoordinated($0) },
        readFile: @escaping @Sendable (URL) async throws -> Data = { try await Self.readFileData($0) }
    ) {
        self.availability = availability
        self.requestDownload = requestDownload
        self.prepareProvider = prepareProvider
        self.timeout = timeout
        self.readFile = readFile
    }

    /// False means absent, rather than a cloud file still waiting to download.
    public func waitUntilAvailable(
        at url: URL, knownToExist: Bool = false,
        onWaiting: @Sendable () async -> Void = {}
    ) async throws -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        var requested = false
        var waitingForICloud = false
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
                    try await boundedPreparation(remaining: clock.now.duration(to: deadline)) {
                        try await requestDownload(url)
                    }
                    requested = true
                }
            case .local: return true
            case .providerManaged(let sourceURL):
                await onWaiting()
                try Task.checkCancellation()
                try await prepareProviderFile(at: sourceURL, remaining: clock.now.duration(to: deadline))
                try Task.checkCancellation()
                return true
            case .downloading(let sourceURL):
                waitingForICloud = true
                if !requested {
                    await onWaiting()
                    try Task.checkCancellation()
                    try await boundedPreparation(remaining: clock.now.duration(to: deadline), iCloud: true) {
                        try await requestDownload(sourceURL)
                    }
                    requested = true
                }
            }
            guard clock.now < deadline else {
                throw waitingForICloud ? DownloadError.timedOut : DownloadError.providerTimedOut
            }
            try await Task.sleep(for: .milliseconds(250))
        }
    }

    public func readDataIfPresent(
        at url: URL, knownToExist: Bool = false,
        onWaiting: @Sendable () async -> Void = {}
    ) async throws -> Data? {
        guard try await waitUntilAvailable(at: url, knownToExist: knownToExist, onWaiting: onWaiting) else {
            return nil
        }
        try Task.checkCancellation()
        let data = try await readFile(url)
        try Task.checkCancellation()
        return data
    }

    private func prepareProviderFile(at url: URL, remaining: Duration) async throws {
        let prepare = prepareProvider
        try await boundedPreparation(remaining: remaining) { try await prepare(url) }
    }

    private func boundedPreparation(
        remaining: Duration, iCloud: Bool = false,
        operation: @escaping @Sendable () async throws -> Void
    ) async throws {
        guard remaining > .zero else {
            throw iCloud ? DownloadError.timedOut : DownloadError.providerTimedOut
        }
        try await withThrowingTaskGroup(of: Bool.self) { group in
            group.addTask {
                try await operation()
                return true
            }
            group.addTask {
                try await Task.sleep(for: remaining)
                throw iCloud ? DownloadError.timedOut : DownloadError.providerTimedOut
            }
            defer { group.cancelAll() }
            _ = try await group.next()
        }
    }

    private static func readFileData(_ url: URL) async throws -> Data {
        try await CoordinatedFileAccess().withRead(at: url) { scope in
            try scope.checkCancellation()
            let bytes = try Data(contentsOf: scope.url)
            try scope.checkCancellation()
            return bytes
        }
    }
    private static func prepareCoordinated(_ url: URL) async throws {
        try await CoordinatedFileAccess().withRead(at: url) { scope in
            try scope.checkCancellation()
            guard FileManager.default.fileExists(atPath: scope.url.path) else { throw CocoaError(.fileReadNoSuchFile) }
            guard !isDataless(scope.url) else { throw DownloadError.notAvailable }
        }
    }

    /// SF_DATALESS is a kernel metadata flag, not a zero-allocation heuristic;
    /// resident empty/sparse files must never be mistaken for cloud placeholders.
    static func isDataless(_ url: URL) -> Bool {
        var information = stat()
        return url.resolvingSymlinksInPath().path.withCString { path in
            Darwin.lstat(path, &information) == 0 && (information.st_flags & UInt32(SF_DATALESS)) != 0
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
                .ubiquitousItemDownloadingErrorKey,
            ])
            if let error = values.ubiquitousItemDownloadingError { throw error }
            if source != target || values.ubiquitousItemDownloadingStatus == .notDownloaded {
                return Availability.downloading(source)
            }
            if isDataless(source) { return Availability.providerManaged(source) }
            return Availability.local
        }.value
    }

    private static func startDownload(_ target: URL) async throws {
        let isICloud = await Task.detached {
            var url = target
            url.removeAllCachedResourceValues()
            var parent = target.deletingLastPathComponent()
            parent.removeAllCachedResourceValues()
            return ((try? url.resourceValues(forKeys: [.isUbiquitousItemKey]).isUbiquitousItem) == true)
                || ((try? parent.resourceValues(forKeys: [.isUbiquitousItemKey]).isUbiquitousItem) == true)
                || (url.lastPathComponent.hasPrefix(".") && url.lastPathComponent.hasSuffix(".icloud"))
        }.value
        if isICloud {
            try await Task.detached { try FileManager.default.startDownloadingUbiquitousItem(at: target) }.value
        } else {
            do { try await prepareCoordinated(target) } catch let error as CocoaError
                where error.code == .fileReadNoSuchFile
            {
                // Expected provider metadata can temporarily disappear during
                // publication/move. Keep the known-file wait, never call iCloud.
            }
        }
    }

    public enum DownloadError: LocalizedError {
        case timedOut
        case providerTimedOut
        case notAvailable

        public var errorDescription: String? {
            switch self {
            case .timedOut:
                return
                    "iCloud Drive has not finished downloading this file. Check your connection and iCloud Drive in Finder, then try again."
            case .providerTimedOut:
                return
                    "The storage provider has not made this file available. Check your connection and the storage folder in Finder, then try again."
            case .notAvailable:
                return
                    "This file is not available from its storage provider yet. Make it available in Finder, then try again."
            }
        }
    }
}
