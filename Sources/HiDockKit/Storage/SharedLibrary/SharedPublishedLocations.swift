// © 2026 High Gain Design. All rights reserved.
import Foundation

struct SharedPublishedLocations: Sendable {
    var recordings: [UUID: Set<String>] = [:]
    var proofs: [URL: String] = [:]
    var completedFileIntents: [UUID: [String: String]] = [:]
    static let completedIntentsKey = "_docktape_completed_file_intents"
    private var initial: [String: String] = [:]
    private var markers: [SharedProjectionMarker] = []
    private var attemptedOrPublished: [SharedProjectionMarker] = []
    private enum ReadError: Error { case changed }
    private func validateReads(absent: Set<URL>, registries: Set<String>?, directory: URL) async throws {
        if let registries, Set(LibraryFileDiscovery.files(in: directory, suffix: ".json").map(\.relativePath)) != registries {
            throw ReadError.changed
        }
        for (url, expected) in proofs.sorted(by: { $0.key.path < $1.key.path }) {
            let bytes = try await RecordingFileAccess().readDataIfPresent(at: url)
            guard bytes.map(SharedLibraryOperation.fingerprint) == expected else { throw ReadError.changed }
        }
        for url in absent {
            guard try await RecordingFileAccess().readDataIfPresent(at: url) == nil else { throw ReadError.changed }
        }
    }
    func validateCompanion(path: String, bytes: Data, entity: UUID, library: UUID, kind: String) throws {
        if initial[path] == SharedLibraryOperation.fingerprint(bytes),
           !attemptedOrPublished.contains(where: { $0.libraryID == library && $0.entities == [entity] && $0.kind == kind }) { return }
        guard let marker = try? SharedProjectionDocument.marker(in: bytes),
              marker.libraryID == library, marker.entities == [entity], marker.kind == kind,
              markers.contains(marker) else { throw SharedProjectionWriteError.untracked(path) }
    }
    /// Reservations come from accepted entity recipes, never filename/byte
    /// similarity. A registered publication releases a completed recipe.
    func reservations(states: [SharedEntityState], library: UUID) throws -> [UUID: Set<String>] {
        let recordings = states.filter { $0.kind == .recording }
        let known = Set(recordings.map(\.id))
        var result = self.recordings.filter { known.contains($0.key) }
        for state in recordings {
            for (writer, document, intent) in try Self.fileIntents(state: state, library: library) {
                guard completedFileIntents[state.id]?[writer] != SharedLibraryOperation.fingerprint(document.json) else { continue }
                for (path, hash) in intent.retainedFiles ?? [:] {
                    _ = try SharedLibraryIdentity.normalized(path)
                    guard SharedLibraryOperation.validHash(hash) else { throw SharedLibraryOperationError.invalidReceipt }
                    let suffixes = [".transcript.json", ".summary.json", ".transcript.md", ".summary.md", ".mp3", ".txt"]
                    guard let suffix = suffixes.first(where: { path.hasSuffix($0) }) else { throw SharedLibraryOperationError.invalidOperation }
                    result[state.id, default: []].insert(String(path.dropLast(suffix.count)) + ".mp3")
                }
                for step in intent.steps {
                    let paths: [String]
                    switch step {
                    case .move(let source, let destination, _): paths = [source, destination]
                    case .trash(let path, _): paths = [path]
                    default: throw SharedLibraryOperationError.invalidOperation
                    }
                    for path in paths {
                        let suffixes = [".transcript.json", ".summary.json", ".transcript.md", ".summary.md", ".mp3", ".txt"]
                        guard let suffix = suffixes.first(where: { path.hasSuffix($0) }) else { throw SharedLibraryOperationError.invalidOperation }
                        let audio = String(path.dropLast(suffix.count)) + ".mp3"
                        _ = try SharedLibraryIdentity.normalized(audio)
                        result[state.id, default: []].insert(audio)
                    }
                }
            }
        }
        return result
    }
    static func fileIntents(state: SharedEntityState, library: UUID) throws -> [(String, SharedDocument, SharedAcceptedFileIntent)] {
        var result: [(String, SharedDocument, SharedAcceptedFileIntent)] = []
        let prefix = "materialization.files."
        for (field, register) in state.fields where field.hasPrefix(prefix) {
            let writer = String(field.dropFirst(prefix.count))
            guard UUID(uuidString: writer) != nil else { throw SharedLibraryOperationError.invalidReceipt }
            for value in register.values {
                if value == .unset { continue }
                guard case .document(let document) = value else { throw SharedLibraryOperationError.invalidReceipt }
                let intent = try JSONDecoder().decode(SharedAcceptedFileIntent.self, from: document.json)
                guard intent.schema == 1, intent.libraryID == library,
                      intent.entity == SharedEntityIdentity(id: state.id, kind: state.kind) else { throw SharedLibraryOperationError.differentBinding }
                _ = try SharedLibraryOperation(libraryID: library, entity: intent.entity, inputRevision: intent.inputRevision,
                    outputRevision: intent.guardRevision, steps: intent.steps)
                result.append((writer, document, intent))
            }
        }
        return result
    }
    static func load(root: URL, manifest: SharedBootstrapManifest, membership: SharedLibraryMembership,
                     afterLibraryRead: @escaping @Sendable () async throws -> Void = {}) async throws -> Self {
        // Canonical files and registries are read separately so hydration does
        // not hold a global file lease. Retry a changed read set before judging
        // an otherwise app-owned publication to be an external edit.
        for attempt in 0..<3 {
            try Task.checkCancellation()
            do { return try await loadOnce(root: root, manifest: manifest, membership: membership, afterLibraryRead: afterLibraryRead) }
            catch ReadError.changed where attempt < 2 { continue }
            catch ReadError.changed { throw SharedProjectionWriteError.stale }
        }
        throw SharedProjectionWriteError.stale
    }
    private static func loadOnce(root: URL, manifest: SharedBootstrapManifest, membership: SharedLibraryMembership,
                                 afterLibraryRead: @escaping @Sendable () async throws -> Void) async throws -> Self {
        var result = Self()
        let inputURL = SharedProjectionInputs.file(in: root)
        let inputBytes = try await CoordinatedFileAccess().read(at: inputURL)
        let inputs = try JSONDecoder().decode(SharedProjectionInputs.self, from: inputBytes)
        try inputs.validate(manifest: manifest)
        result.initial = inputs.files
        result.proofs[inputURL] = SharedLibraryOperation.fingerprint(inputBytes)
        let libraryURL = root.appendingPathComponent("library.json")
        let bytes = try await RecordingFileAccess().readDataIfPresent(at: libraryURL)
        let absent: Set<URL> = bytes == nil ? [libraryURL] : []
        let directory = root.appendingPathComponent(".docktape/projections")
        if let bytes { result.proofs[libraryURL] = SharedLibraryOperation.fingerprint(bytes) }
        try await afterLibraryRead()
        // Publication attempts matter even while library.json still contains
        // its bootstrap bytes. A spent initial sidecar approval must be exposed
        // for a new review rather than silently treated as unchanged input.
        let files = LibraryFileDiscovery.files(in: directory, suffix: ".json")
        let registries = Set(files.map(\.relativePath))
        var publications: [SharedProjectionRegistry] = []
        for file in files {
            let url = directory.appendingPathComponent(file.relativePath)
            guard SharedLibraryMaterializer.contained(url, in: directory) else { throw SharedLibraryOperationError.unsafePath }
            let data = try await CoordinatedFileAccess().read(at: url)
            let registry = try JSONDecoder().decode(SharedProjectionRegistry.self, from: data)
            try registry.validate(library: manifest.libraryID, writers: membership.cohort)
            result.proofs[url] = SharedLibraryOperation.fingerprint(data)
            result.markers += Array(registry.files.values) + Array(registry.pending?.values ?? [:].values)
            result.attemptedOrPublished += Array(registry.files.values) + Array(registry.attempted?.values ?? [:].values)
            publications.append(registry)
        }
        try await result.validateReads(absent: absent, registries: registries, directory: directory)
        if let bytes {
            if let marker = try? SharedProjectionDocument.marker(in: bytes) {
                guard marker.libraryID == manifest.libraryID, marker.kind == "library" else { throw SharedProjectionWriteError.untracked("library.json") }
                let recognized = publications.contains { $0.files["library.json"] == marker || $0.pending?["library.json"] == marker }
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
                    if let raw = entry[Self.completedIntentsKey] {
                        guard let completed = raw as? [String: String], completed.allSatisfy({ key, hash in
                            UUID(uuidString: key) != nil && SharedLibraryOperation.validHash(hash)
                        }) else { throw SharedProjectionWriteError.untracked("library.json") }
                        result.completedFileIntents[id] = completed
                    }
                }
                return result
            }
            guard inputs.files["library.json"] == SharedLibraryOperation.fingerprint(bytes) else { throw SharedProjectionWriteError.untracked("library.json") }
        } else if inputs.files["library.json"] != nil { throw SharedProjectionWriteError.untracked("library.json") }
        try await result.validateReads(absent: absent, registries: registries, directory: directory)
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
