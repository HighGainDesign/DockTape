// © 2026 High Gain Design. All rights reserved.
import Foundation

public struct SharedLibraryWriterIdentity: Codable, Equatable, Sendable {
    public let writer: UUID
    public let requestID: UUID
}

/// File must be in local Application Support, outside the library/SyncedDefaults.
/// Caller supplies a stable installation anchor backed by a device-only key;
/// copying/restoring a writer file without its matching anchor rotates identity.
/// Keychain/host anchor acquisition belongs to the app's platform adapter.
public actor SharedLibraryWriterIdentityStore {
    private let file: URL
    private let anchor: String
    private let access = CoordinatedFileAccess()
    public init(file: URL, installationAnchor: String) {
        self.file = file; anchor = installationAnchor
    }
    private struct Record: Codable { let schemaVersion: Int; let anchor: String; let identity: SharedLibraryWriterIdentity }
    public func load() async throws -> SharedLibraryWriterIdentity {
        let file = self.file, anchor = try SharedStateFingerprint.of(self.anchor)
        return try await access.withWrite(at: file) { scope in
            if FileManager.default.fileExists(atPath: scope.url.path) {
                let existing = try JSONDecoder().decode(Record.self, from: Data(contentsOf: scope.url))
                guard existing.schemaVersion == 1 else { throw SharedLibraryRepositoryError.unsupportedSchema(existing.schemaVersion) }
                if existing.anchor == anchor { return existing.identity }
            }
            let identity = SharedLibraryWriterIdentity(writer: UUID(), requestID: UUID())
            let record = Record(schemaVersion: 1, anchor: anchor, identity: identity)
            let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
            let bytes = try encoder.encode(record)
            try scope.checkCancellation(); try bytes.write(to: scope.url, options: .atomic)
            return identity
        }
    }
}
