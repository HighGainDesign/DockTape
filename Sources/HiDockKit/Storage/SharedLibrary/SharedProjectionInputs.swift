// © 2026 High Gain Design. All rights reserved.
import Foundation

/// Immutable first-projection authorization. Hashes only: no original media or
/// JSON backups. Subsequent untracked changes require explicit reconciliation.
struct SharedProjectionInputs: Codable, Sendable {
    let schema: Int
    let libraryID: UUID
    let writerID: UUID
    let files: [String: String]
    let checksum: String
    private struct Body: Codable { let schema: Int; let libraryID: UUID; let writerID: UUID; let files: [String: String] }
    init(manifest: SharedBootstrapManifest, files: [String: String]) throws {
        schema = 1; libraryID = manifest.libraryID; writerID = manifest.founder; self.files = files
        checksum = try SharedStateFingerprint.of(Body(schema: schema, libraryID: libraryID, writerID: writerID, files: files))
    }
    func validate(manifest: SharedBootstrapManifest) throws {
        guard schema == 1, libraryID == manifest.libraryID, writerID == manifest.founder,
              checksum == (try SharedStateFingerprint.of(Body(schema: schema, libraryID: libraryID, writerID: writerID, files: files))),
              files.values.allSatisfy(SharedLibraryOperation.validHash) else { throw LegacyBootstrapError.invalidManifest }
        for path in files.keys {
            if path != ".templates.json" { _ = try SharedLibraryIdentity.normalized(path) }
        }
    }
    static func capture(root: URL) async throws -> [String: String] {
        let paths = Set(["library.json", ".templates.json"] +
            LibraryFileDiscovery.files(in: root, suffix: ".transcript.json").map(\.relativePath) +
            LibraryFileDiscovery.files(in: root, suffix: ".summary.json").map(\.relativePath))
        var result: [String: String] = [:]
        for path in paths.sorted() {
            if let bytes = try await RecordingFileAccess().readDataIfPresent(at: root.appendingPathComponent(path)) {
                result[path] = SharedLibraryOperation.fingerprint(bytes)
            }
        }
        return result
    }
    static func file(in root: URL) -> URL { root.appendingPathComponent(".docktape/projection-inputs.json") }
    func encoded() throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(self)
    }
}
