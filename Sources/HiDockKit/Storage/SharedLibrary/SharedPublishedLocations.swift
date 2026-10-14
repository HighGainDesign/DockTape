// © 2026 High Gain Design. All rights reserved.
import Foundation

struct SharedPublishedLocations: Sendable {
    var recordings: [UUID: Set<String>] = [:]
    var proofs: [URL: String] = [:]
    private var initial: [String: String] = [:]
    private var markers: [SharedProjectionMarker] = []
    func validateCompanion(path: String, bytes: Data, entity: UUID, library: UUID, kind: String) throws {
        if initial[path] == SharedLibraryOperation.fingerprint(bytes) { return }
        guard let marker = try? SharedProjectionDocument.marker(in: bytes),
              marker.libraryID == library, marker.entities == [entity], marker.kind == kind,
              markers.contains(marker) else { throw SharedProjectionWriteError.untracked(path) }
    }
    static func load(root: URL, manifest: SharedBootstrapManifest, membership: SharedLibraryMembership) async throws -> Self {
        var result = Self()
        let inputURL = SharedProjectionInputs.file(in: root)
        let inputBytes = try await CoordinatedFileAccess().read(at: inputURL)
        let inputs = try JSONDecoder().decode(SharedProjectionInputs.self, from: inputBytes)
        try inputs.validate(manifest: manifest)
        result.initial = inputs.files
        result.proofs[inputURL] = SharedLibraryOperation.fingerprint(inputBytes)
        let libraryURL = root.appendingPathComponent("library.json")
        let bytes = try await RecordingFileAccess().readDataIfPresent(at: libraryURL)
        if let bytes {
            result.proofs[libraryURL] = SharedLibraryOperation.fingerprint(bytes)
            if let marker = try? SharedProjectionDocument.marker(in: bytes) {
                guard marker.libraryID == manifest.libraryID, marker.kind == "library" else { throw SharedProjectionWriteError.untracked("library.json") }
                var recognized = false
                let directory = root.appendingPathComponent(".docktape/projections")
                for file in LibraryFileDiscovery.files(in: directory, suffix: ".json") {
                    let url = directory.appendingPathComponent(file.relativePath)
                    guard SharedLibraryMaterializer.contained(url, in: directory) else { throw SharedLibraryOperationError.unsafePath }
                    let data = try await CoordinatedFileAccess().read(at: url)
                    let registry = try JSONDecoder().decode(SharedProjectionRegistry.self, from: data)
                    try registry.validate(library: manifest.libraryID, writers: membership.cohort)
                    result.proofs[url] = SharedLibraryOperation.fingerprint(data)
                    result.markers += Array(registry.files.values) + Array(registry.pending?.values ?? [:].values)
                    recognized = recognized || registry.files["library.json"] == marker || registry.pending?["library.json"] == marker
                }
                guard recognized, let object = try JSONSerialization.jsonObject(with: bytes) as? [String: Any] else {
                    throw SharedProjectionWriteError.untracked("library.json")
                }
                for (path, value) in object where path != SharedProjectionDocument.key {
                    guard let entry = value as? [String: Any], let text = entry["_docktape_entity"] as? String,
                          let id = UUID(uuidString: text), marker.entities.contains(id) else { throw SharedProjectionWriteError.untracked("library.json") }
                    _ = try SharedLibraryIdentity.normalized(path)
                    // The last published physical location remains reserved
                    // through a partial move, including phases after its MP3
                    // already moved but some owned companions remain behind.
                    result.recordings[id, default: []].insert(path)
                }
                return result
            }
            guard inputs.files["library.json"] == SharedLibraryOperation.fingerprint(bytes) else { throw SharedProjectionWriteError.untracked("library.json") }
        } else if inputs.files["library.json"] != nil { throw SharedProjectionWriteError.untracked("library.json") }
        // Bootstrap claims remain reserved until first physical publication,
        // including an interrupted move after the audio phase has completed.
        for reference in manifest.references where reference.entity.kind == .recording {
            result.recordings[reference.entity.id, default: []].insert(reference.initialPath)
        }
        return result
    }
}

public struct SharedRecordingFileOutcome: Sendable {
    public let filename: String
    public let result: SharedMaterializationResult
    public let projectionError: String?
    let view: SharedLibraryViewSnapshot
}
