// © 2026 High Gain Design. All rights reserved.
import Foundation

/// Immutable metadata from Foundation. Version-store URLs are private access
/// capabilities; callers display the canonical source and date, never that path.
public struct RecordingFileVersion: Sendable {
    public let id: String
    public let sourceURL: URL
    public let modifiedAt: Date?
    public let isConflict: Bool
    public let isResolved: Bool
    let accessURL: URL
}

/// Enumerates currently reported versions; later arrivals require another scan.
/// Local and nonlocal metadata are combined, and each selected version gets its
/// own coordinated read. There is no blanket history removal or auto-resolution.
public struct RecordingFileVersionAccess: Sendable {
    typealias Query = @Sendable (URL, @escaping @Sendable (Result<[RecordingFileVersion], Error>) -> Void) -> Void
    private let nonlocalQuery: Query
    private let isUbiquitous: @Sendable (URL) async throws -> Bool
    private let access = CoordinatedFileAccess()
    private let lookupOverride: (@Sendable (URL) async throws -> [RecordingFileVersion])?
    private let readOverride: (@Sendable (RecordingFileVersion) async throws -> Data)?
    public init() { self.init(nonlocalQuery: Self.queryNonlocal, isUbiquitous: Self.ubiquity) }
    init(nonlocalQuery: @escaping Query, isUbiquitous: @escaping @Sendable (URL) async throws -> Bool) {
        self.nonlocalQuery = nonlocalQuery
        self.isUbiquitous = isUbiquitous
        lookupOverride = nil
        readOverride = nil
    }
    init(
        lookup: @escaping @Sendable (URL) async throws -> [RecordingFileVersion],
        read: @escaping @Sendable (RecordingFileVersion) async throws -> Data
    ) {
        nonlocalQuery = Self.queryNonlocal
        isUbiquitous = Self.ubiquity
        lookupOverride = lookup
        readOverride = read
    }
    public func versions(at url: URL) async throws -> [RecordingFileVersion] {
        try Task.checkCancellation()
        if let lookupOverride { return try await lookupOverride(url) }
        var remote: [RecordingFileVersion] = []
        if try await isUbiquitous(url) {
            let request = MetadataRequest()
            let query = nonlocalQuery
            remote = try await withTaskCancellationHandler {
                try await request.wait { completion in query(url, completion) }
            } onCancel: {
                Task { await request.finish(.failure(CancellationError())) }
            }
        }
        try Task.checkCancellation()
        let local = try await access.withRead(at: url) { scope in
            try scope.checkCancellation()
            let versions =
                (NSFileVersion.otherVersionsOfItem(at: scope.url) ?? [])
                + (NSFileVersion.unresolvedConflictVersionsOfItem(at: scope.url) ?? [])
            return try versions.map { try Self.reference($0, source: url) }
        }
        var byID: [String: RecordingFileVersion] = [:]
        for version in remote + local { byID[version.id] = version }
        return byID.values.sorted { $0.id < $1.id }
    }
    public func read(_ version: RecordingFileVersion) async throws -> Data {
        if let readOverride { return try await readOverride(version) }
        return try await access.withRead(at: version.accessURL) { scope in
            try scope.checkCancellation()
            let bytes = try Data(contentsOf: scope.url)
            try scope.checkCancellation()
            return bytes
        }
    }
    private static func reference(_ version: NSFileVersion, source: URL) throws -> RecordingFileVersion {
        // We archive a Foundation-created opaque NSCoding object only to hash
        // its identity; no caller-supplied archive is decoded or executed.
        let identity = try NSKeyedArchiver.archivedData(
            withRootObject: version.persistentIdentifier, requiringSecureCoding: false)
        return .init(
            id: try SharedStateFingerprint.of(identity), sourceURL: source, modifiedAt: version.modificationDate,
            isConflict: version.isConflict, isResolved: version.isResolved, accessURL: version.url)
    }
    private static func queryNonlocal(
        _ url: URL, completion: @escaping @Sendable (Result<[RecordingFileVersion], Error>) -> Void
    ) {
        NSFileVersion.getNonlocalVersionsOfItem(at: url) { versions, error in
            if let error {
                completion(.failure(error))
                return
            }
            do { completion(.success(try (versions ?? []).map { try reference($0, source: url) })) } catch {
                completion(.failure(error))
            }
        }
    }
    private static func ubiquity(_ target: URL) async throws -> Bool {
        try await Task.detached {
            var url = target
            url.removeAllCachedResourceValues()
            return try url.resourceValues(forKeys: [.isUbiquitousItemKey]).isUbiquitousItem ?? false
        }.value
    }
    private actor MetadataRequest {
        var continuation: CheckedContinuation<[RecordingFileVersion], Error>?
        var result: Result<[RecordingFileVersion], Error>?
        func wait(start: @Sendable (@escaping @Sendable (Result<[RecordingFileVersion], Error>) -> Void) -> Void)
            async throws -> [RecordingFileVersion]
        {
            if let result { return try result.get() }
            return try await withCheckedThrowingContinuation { continuation in
                self.continuation = continuation
                start { result in Task { await self.finish(result) } }
            }
        }
        func finish(_ result: Result<[RecordingFileVersion], Error>) {
            guard self.result == nil else { return }
            self.result = result
            continuation?.resume(with: result)
            continuation = nil
        }
    }
}
