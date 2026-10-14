// © 2026 High Gain Design. All rights reserved.
import Foundation

public enum SharedProjectionWriteError: Error, Equatable, Sendable {
    case untracked(String), stale, missingInputs, invalidRegistry
}
public struct SharedProjectionWriteResult: Equatable, Sendable { public let written: Int; public let unchanged: Int }
struct SharedLibraryProjectionContext: Sendable {
    let root: URL
    let manifest: SharedBootstrapManifest
    let views: [SharedLibraryViewSnapshot]
    let sources: [URL: String]
    let gate: SharedLibraryLocalGate
    let lease: SharedMaterializationLease
    let validate: @Sendable () throws -> Bool
    let membership: SharedLibraryMembership
}

struct SharedProjectionRegistry: Codable, Sendable {
    let schema: Int
    let libraryID: UUID
    let writerID: UUID
    let files: [String: SharedProjectionMarker]
    let pending: [String: SharedProjectionMarker]?
    let checksum: String
    private struct Body: Codable {
        let schema: Int; let libraryID: UUID; let writerID: UUID
        let files: [String: SharedProjectionMarker]; let pending: [String: SharedProjectionMarker]?
    }
    init(library: UUID, writer: UUID, files: [String: SharedProjectionMarker], pending: [String: SharedProjectionMarker]? = nil) throws {
        schema = 1; libraryID = library; writerID = writer; self.files = files; self.pending = pending
        checksum = try SharedStateFingerprint.of(Body(schema: schema, libraryID: libraryID, writerID: writerID, files: files, pending: pending))
    }
    func validate(library: UUID, writers: Set<UUID>) throws {
        guard schema == 1, libraryID == library, writers.contains(writerID),
              checksum == (try SharedStateFingerprint.of(Body(schema: schema, libraryID: libraryID, writerID: writerID, files: files, pending: pending))) else {
            throw SharedProjectionWriteError.invalidRegistry
        }
        for (path, marker) in files.merging(pending ?? [:], uniquingKeysWith: { _, new in new }) {
            if path != ".templates.json" { _ = try SharedLibraryIdentity.normalized(path) }
            guard marker.libraryID == libraryID else { throw SharedProjectionWriteError.invalidRegistry }
        }
    }
    func encoded() throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(self)
    }
}

/// Full-library derived projection. Accepted state is already durable; outputs
/// can be replayed after interruption from state plus one current publication
/// registry. Original audio is never read, copied or removed by this writer.
struct SharedLibraryProjectionWriter {
    static func authoritySources(root: URL) async throws -> [URL: String] {
        let namespace = root.appendingPathComponent(".docktape")
        let files = LibraryFileDiscovery.files(in: namespace, suffix: ".json").filter { !$0.relativePath.hasPrefix("projections/") }
        return try await withThrowingTaskGroup(of: (URL, String).self) { group in
            for file in files {
                let url = namespace.appendingPathComponent(file.relativePath)
                guard SharedLibraryMaterializer.contained(url, in: namespace) else { throw SharedLibraryOperationError.unsafePath }
                group.addTask { (url, SharedLibraryOperation.fingerprint(try await CoordinatedFileAccess().read(at: url))) }
            }
            var result: [URL: String] = [:]
            for try await (url, hash) in group { result[url] = hash }
            return result
        }
    }
    static func project(_ context: SharedLibraryProjectionContext, writer: UUID,
                        beforeWrite: @escaping @Sendable () async -> Void = {},
                        afterOutput: @escaping @Sendable (Int) throws -> Void = { _ in }) async throws -> SharedProjectionWriteResult {
        let root = context.root
        guard let seedBytes = try await RecordingFileAccess().readDataIfPresent(at: SharedProjectionInputs.file(in: root)) else {
            throw SharedProjectionWriteError.missingInputs
        }
        let inputs = try JSONDecoder().decode(SharedProjectionInputs.self, from: seedBytes)
        try inputs.validate(manifest: context.manifest)
        let outputs = try render(context)
        let registryDir = root.appendingPathComponent(".docktape/projections")
        guard SharedLibraryMaterializer.contained(registryDir, in: root) else { throw SharedLibraryOperationError.unsafePath }
        try FileManager.default.createDirectory(at: registryDir, withIntermediateDirectories: true)
        let registryFile = registryDir.appendingPathComponent(writer.uuidString.lowercased() + ".json")
        let registries = LibraryFileDiscovery.files(in: registryDir, suffix: ".json").map { registryDir.appendingPathComponent($0.relativePath) }
        let paths = outputs.keys.sorted()
        for path in paths {
            let url = root.appendingPathComponent(path)
            guard SharedLibraryMaterializer.contained(url, in: root) else { throw SharedLibraryOperationError.unsafePath }
            _ = try await RecordingFileAccess().waitUntilAvailable(at: url)
        }
        // Prepare all related metadata outside the local physical gate.
        for url in Array(context.sources.keys) + registries { _ = try await RecordingFileAccess().waitUntilAvailable(at: url, knownToExist: true) }
        await beforeWrite()
        let gateItems = try context.gate.items(outside: root)
        let reads = context.sources.keys.sorted { $0.path < $1.path } + registries.filter { $0 != registryFile }
        let writes = [.init(registryFile) as CoordinatedFileAccess.WriteItem] + paths.map { CoordinatedFileAccess.WriteItem(root.appendingPathComponent($0), mode: .replacing) } + gateItems
        return try await CoordinatedFileAccess().withWrites(writes, reading: reads) { scopes in
            guard !context.lease.isRevoked, try context.validate() else { throw SharedProjectionWriteError.stale }
            try context.gate.validate(scopes[paths.count + 1], outside: root)
            try SharedLibraryMaterializer.checkRoot(root)
            let readScopes = Array(scopes.dropFirst(writes.count))
            for (requested, scope) in zip(reads, readScopes) {
                guard SharedLibraryMaterializer.contained(scope.url, in: root),
                      scope.url.standardizedFileURL.resolvingSymlinksInPath() == requested.standardizedFileURL.resolvingSymlinksInPath() else {
                    throw SharedLibraryOperationError.unsafePath
                }
                if let expected = context.sources[requested], SharedLibraryOperation.fingerprint(try Data(contentsOf: scope.url)) != expected {
                    throw SharedProjectionWriteError.stale
                }
            }
            // New or removed authority files also invalidate the all-entity plan.
            let actualSources = Set(LibraryFileDiscovery.files(in: root.appendingPathComponent(".docktape"), suffix: ".json")
                .filter { !$0.relativePath.hasPrefix("projections/") }.map { root.appendingPathComponent(".docktape/" + $0.relativePath) })
            guard actualSources == Set(context.sources.keys) else { throw SharedProjectionWriteError.stale }
            var publications: [SharedProjectionRegistry] = []
            for scope in [scopes[0]] + Array(readScopes.suffix(registries.filter { $0 != registryFile }.count)) {
                if FileManager.default.fileExists(atPath: scope.url.path) {
                    let registry = try JSONDecoder().decode(SharedProjectionRegistry.self, from: Data(contentsOf: scope.url))
                    try registry.validate(library: context.manifest.libraryID, writers: context.membership.cohort)
                    publications.append(registry)
                }
            }
            var known = publications.first(where: { $0.writerID == writer })?.files ?? [:]
            var changes: [(Int, String, Data)] = []
            var unchanged = 0
            for (index, path) in paths.enumerated() {
                let scope = scopes[index + 1]
                guard scope.url.standardizedFileURL.resolvingSymlinksInPath() == root.appendingPathComponent(path).standardizedFileURL.resolvingSymlinksInPath() else {
                    throw SharedLibraryOperationError.unsafePath
                }
                let desired = outputs[path]!
                let existing = FileManager.default.fileExists(atPath: scope.url.path) ? try Data(contentsOf: scope.url) : nil
                if existing == desired { unchanged += 1; continue }
                if let existing, path.hasSuffix(".json") {
                    let marker = try? SharedProjectionDocument.marker(in: existing)
                    let published = marker.map { marker in publications.contains { $0.files[path] == marker || $0.pending?[path] == marker } } ?? false
                    let initial = inputs.files[path] == SharedLibraryOperation.fingerprint(existing)
                    guard published || initial else { throw SharedProjectionWriteError.untracked(path) }
                }
                changes.append((index + 1, path, desired))
            }
            var proposed: [String: SharedProjectionMarker] = [:]
            for (path, bytes) in outputs where path.hasSuffix(".json") { proposed[path] = try SharedProjectionDocument.marker(in: bytes) }
            let intent = try SharedProjectionRegistry(library: context.manifest.libraryID, writer: writer, files: known, pending: proposed).encoded()
            known.merge(proposed, uniquingKeysWith: { _, new in new })
            let registry = try SharedProjectionRegistry(library: context.manifest.libraryID, writer: writer, files: known).encoded()
            for scope in scopes { try scope.checkCancellation() }
            guard !context.lease.isRevoked, try context.validate() else { throw SharedProjectionWriteError.stale }
            // The intent registry precedes output publication. An interruption
            // leaves old recognized bytes or new authorized bytes, never backups.
            let previousRegistry = try? Data(contentsOf: scopes[0].url)
            if !changes.isEmpty { try intent.write(to: scopes[0].url, options: .atomic) }
            for (index, _, bytes) in changes {
                try bytes.write(to: scopes[index].url, options: .atomic)
                try afterOutput(index)
            }
            if !changes.isEmpty || previousRegistry != registry { try registry.write(to: scopes[0].url, options: .atomic) }
            return .init(written: changes.count, unchanged: unchanged)
        }
    }
    private static func render(_ context: SharedLibraryProjectionContext) throws -> [String: Data] {
        let views = context.views
        let pathStates = views.map { view -> SharedEntityState in
            let fields = view.state.kind == .folder ? ["name", "parent"] : ["title", "folder"]
            return fields.contains(where: { view.state.fields[$0]?.isConflicted == true }) ? (view.confirmedState ?? view.state) : view.state
        }
        let sensitivity = (try? context.root.resourceValues(forKeys: [.volumeSupportsCaseSensitiveNamesKey]))?.volumeSupportsCaseSensitiveNames ?? false
        let index = try SharedLibraryPathIndex(states: pathStates, caseSensitive: sensitivity)
        var files: [String: Data] = [:]
        var library: [String: Any] = [:]
        var overrides: [[String: Any]] = [], users: [[String: Any]] = []
        for view in views {
            if view.state.kind == .recording, let path = index.resolvedPaths[view.state.id] {
                guard index.owners(of: path) == [view.state.id] else { throw SharedLibraryOperationError.pathConflict(path) }
                var metadata = try SharedRecordingMetadataAdapter.renderObject(view)
                metadata["_docktape_entity"] = view.state.id.uuidString
                metadata["_docktape_lifecycle"] = String(describing: view.state.lifecycle)
                library[path] = metadata
                if view.state.lifecycle == .alive {
                    for (name, bytes) in try SharedLibraryReadableExport.files(view: view, recordingPath: path) {
                        guard index.owners(of: name) == [view.state.id], files[name] == nil else { throw SharedLibraryOperationError.pathConflict(name) }
                        files[name] = bytes
                    }
                }
            } else if view.state.kind == .template, view.state.lifecycle == .alive {
                let template = try SharedTemplateAdapter.render(view)
                let raw = try JSONSerialization.jsonObject(with: JSONEncoder().encode(template)) as! [String: Any]
                if template.isBuiltIn { overrides.append(raw) } else { users.append(raw) }
            }
        }
        let revision = try SharedStateFingerprint.of(views.map(\.fingerprint).sorted())
        let conflict = views.contains { !$0.state.conflicts.isEmpty }
        files["library.json"] = try SharedProjectionDocument.make(body: library, libraryID: context.manifest.libraryID,
            entities: views.filter { $0.state.kind == .recording }.map { $0.state.id }, kind: "library", revision: revision, hasConflicts: conflict)
        files[".templates.json"] = try SharedProjectionDocument.make(body: ["builtInOverrides": overrides, "userTemplates": users],
            libraryID: context.manifest.libraryID, entities: views.filter { $0.state.kind == .template }.map { $0.state.id },
            kind: "templates", revision: revision, hasConflicts: conflict)
        return files
    }
}
