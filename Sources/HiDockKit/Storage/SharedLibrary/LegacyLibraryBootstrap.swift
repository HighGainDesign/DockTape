// © 2026 High Gain Design. All rights reserved.
import Foundation

public enum LegacyBootstrapError: Error, Equatable, Sendable {
    case alreadyEnabled, ambiguousBootstrap
    case unsupportedSchema(Int)
    case invalidManifest, ambiguousMetadata, changedLegacyInput
}
public struct SharedBootstrapReference: Codable, Equatable, Sendable {
    public let entity: SharedEntityIdentity
    public let initialPath: String
    public let sequence: UInt64
    public let fingerprint: String
}
public struct SharedBootstrapManifest: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let libraryID: UUID
    public let founder: UUID
    public let references: [SharedBootstrapReference]
    public var complete: Bool
    public var fingerprint: String {
        var initial = self
        initial.complete = false
        return try! SharedStateFingerprint.of(initial)
    }
}
public enum SharedBootstrapReadiness: Equatable, Sendable {
    case notEnabled
    case pending(SharedBootstrapManifest)
    case ready(SharedBootstrapManifest)
}

/// Explicit one-Mac upgrade. It writes only hidden metadata; original MP3,
/// JSON/TXT and library metadata bytes remain untouched. An intent published
/// before seeding prevents partially arrived paths from becoming new identities.
public actor LegacyLibraryBootstrap {
    private let root: URL
    private let writer: UUID
    private let access = CoordinatedFileAccess()
    public init(root: URL, writerID: UUID) {
        self.root = root.standardizedFileURL.resolvingSymlinksInPath()
        writer = writerID
    }
    private var formatURL: URL { root.appendingPathComponent(".docktape/format.json") }
    private var claimsURL: URL { root.appendingPathComponent(".docktape/bootstraps") }
    private var claimURL: URL { claimsURL.appendingPathComponent(writer.uuidString.lowercased() + ".json") }

    /// Read the published header independently of entity hydration. This is
    /// enough to bind read-only content; enrollment separately verifies every
    /// referenced seed with readiness(). It is not a provider sync-complete flag.
    public func publishedManifest() async throws -> SharedBootstrapReadiness {
        try validateRoot()
        try validate(formatURL)
        try validate(claimsURL)
        let claimFiles = try await Task.detached { [claimsURL] in
            if !FileManager.default.fileExists(atPath: claimsURL.path) { return [URL]() }
            return try FileManager.default.contentsOfDirectory(at: claimsURL, includingPropertiesForKeys: nil)
                .compactMap { url in
                    let name = url.lastPathComponent
                    if name.hasPrefix("."), name.hasSuffix(".icloud") {
                        return url.deletingLastPathComponent().appendingPathComponent(
                            String(name.dropFirst().dropLast(7)))
                    }
                    return name.hasSuffix(".json") ? url : nil
                }
        }.value
        var manifests: [SharedBootstrapManifest] = []
        if exists(formatURL) { manifests.append(try decode(await access.read(at: formatURL))) }
        var claims: [SharedBootstrapManifest] = []
        for file in claimFiles {
            try validate(file)
            let manifest = try decode(await access.read(at: file))
            if let namedWriter = UUID(uuidString: file.deletingPathExtension().lastPathComponent),
                namedWriter != manifest.founder
            {
                throw LegacyBootstrapError.invalidManifest
            }
            claims.append(manifest)
            manifests.append(manifest)
        }
        guard var selected = manifests.first else { return .notEnabled }
        guard manifests.allSatisfy({ $0.fingerprint == selected.fingerprint }) else {
            throw LegacyBootstrapError.ambiguousBootstrap
        }
        selected.complete = manifests.contains(where: \.complete)
        guard exists(formatURL), selected.complete,
            claims.contains(where: { $0.complete && $0.fingerprint == selected.fingerprint })
        else { return .pending(selected) }
        return .ready(selected)
    }

    public func readiness() async throws -> SharedBootstrapReadiness {
        let header = try await publishedManifest()
        guard case .ready(let selected) = header else { return header }
        let repository = SharedLibraryRepository(root: root, writerID: selected.founder, manifest: selected)
        for reference in selected.references {
            guard
                try await repository.containsBootstrapReference(
                    entity: reference.entity, writer: selected.founder,
                    sequence: reference.sequence, fingerprint: reference.fingerprint, initialPath: reference.initialPath
                )
            else { return .pending(selected) }
        }
        return .ready(selected)
    }

    public func enable() async throws -> SharedBootstrapManifest {
        guard try await readiness() == .notEnabled else { throw LegacyBootstrapError.alreadyEnabled }
        let seeds = try await legacySeeds()
        let references = try seeds.map { seed -> SharedBootstrapReference in
            var state = SharedEntityState(id: seed.entity.id, kind: seed.entity.kind)
            try seed.apply(to: &state, writer: writer)
            return .init(
                entity: seed.entity, initialPath: seed.path, sequence: 1,
                fingerprint: try SharedStateFingerprint.of(state))
        }
        let manifest = SharedBootstrapManifest(
            schemaVersion: 1, libraryID: UUID(), founder: writer, references: references, complete: false)
        try prepareNamespace()
        let format = formatURL
        let claim = claimURL
        let root = self.root
        let bytes = try encoded(manifest)
        try await access.withWrite(at: format) { scope in
            guard !FileManager.default.fileExists(atPath: scope.url.path) else {
                throw LegacyBootstrapError.alreadyEnabled
            }
            guard
                (try? FileManager.default.attributesOfItem(atPath: root.path)[.type]) as? FileAttributeType
                    == .typeDirectory
            else {
                throw SharedLibraryRepositoryError.unavailableRoot
            }
            try scope.checkCancellation()
            try bytes.write(to: claim, options: .atomic)
            try bytes.write(to: scope.url, options: .atomic)
        }
        return try await finish(manifest, seeds: seeds)
    }

    public func resume() async throws -> SharedBootstrapManifest {
        guard case .pending(let manifest) = try await readiness(), manifest.founder == writer, !manifest.complete else {
            throw LegacyBootstrapError.alreadyEnabled
        }
        let seeds = try await legacySeeds()
        let references = try seeds.map { seed -> SharedBootstrapReference in
            var state = SharedEntityState(id: seed.entity.id, kind: seed.entity.kind)
            try seed.apply(to: &state, writer: writer)
            return .init(
                entity: seed.entity, initialPath: seed.path, sequence: 1,
                fingerprint: try SharedStateFingerprint.of(state))
        }
        guard references == manifest.references else { throw LegacyBootstrapError.changedLegacyInput }
        return try await finish(manifest, seeds: seeds)
    }

    private func finish(_ manifest: SharedBootstrapManifest, seeds: [Seed]) async throws -> SharedBootstrapManifest {
        let repository = SharedLibraryRepository(root: root, writerID: writer, manifest: manifest)
        for seed in seeds {
            let existing = try await repository.load(entity: seed.entity)
            if existing.state.lifecycle == .uninitialized {
                _ = try await repository.commit(.init(base: existing, changes: seed.changes))
            } else {
                guard
                    try SharedStateFingerprint.of(existing.state)
                        == manifest.references.first(where: { $0.entity == seed.entity })?.fingerprint
                else {
                    throw LegacyBootstrapError.changedLegacyInput
                }
            }
        }
        var ready = manifest
        ready.complete = true
        let bytes = try encoded(ready)
        // Claim and canonical pointer both carry the same immutable identity.
        // A ready claim arriving first still waits for every referenced state.
        try await publish(bytes, to: claimURL, expecting: manifest)
        try await publish(bytes, to: formatURL, expecting: manifest)
        return ready
    }
    private func publish(_ bytes: Data, to url: URL, expecting manifest: SharedBootstrapManifest) async throws {
        try validateRoot()
        try validate(url)
        try await access.withWrite(at: url) { scope in
            if FileManager.default.fileExists(atPath: scope.url.path) {
                let current = try Self.decodeManifest(Data(contentsOf: scope.url))
                guard current.fingerprint == manifest.fingerprint else { throw LegacyBootstrapError.ambiguousBootstrap }
            }
            try scope.checkCancellation()
            try bytes.write(to: scope.url, options: .atomic)
        }
    }

    private struct Seed: Sendable {
        let entity: SharedEntityIdentity
        let path: String
        let changes: [SharedLibraryMutation]
        func apply(to state: inout SharedEntityState, writer: UUID) throws {
            for change in changes {
                switch change {
                case .assign(let field, let value): try state.assign(field: field, value: value, writer: writer)
                case .generation(let doc, let component):
                    try state.assignGeneration(doc, component: component, writer: writer)
                default: throw LegacyBootstrapError.invalidManifest
                }
            }
        }
    }
    private func legacySeeds() async throws -> [Seed] {
        try validateRoot()
        let files = await Task.detached { [root] in LibraryFileDiscovery.files(in: root, suffix: ".mp3") }.value
        var metadata: [String: Any] = [:]
        for name in ["modes.json", "library.json"] {
            let url = root.appendingPathComponent(name)
            if exists(url) {
                let data = try await access.read(at: url)
                guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                    throw LegacyBootstrapError.invalidManifest
                }
                for (path, value) in object {
                    if name == "modes.json" {
                        metadata[path] = ["mode": value]
                    } else if let fields = value as? [String: Any] {
                        metadata[path] = fields
                    } else {
                        throw LegacyBootstrapError.invalidManifest
                    }
                }
            }
        }
        var seeds: [Seed] = []
        var folders: Set<String> = []
        for file in files.sorted(by: { $0.relativePath < $1.relativePath }) {
            let path = try SharedLibraryIdentity.normalized(file.relativePath)
            try validate(root.appendingPathComponent(path))
            let folder = (path as NSString).deletingLastPathComponent
            var current = folder
            while !current.isEmpty, current != "." {
                folders.insert(current)
                current = (current as NSString).deletingLastPathComponent
            }
            var changes: [SharedLibraryMutation] = [
                .assign(field: "initialPath", value: .text(path)),
                .assign(field: "title", value: .text((file.logicalName as NSString).deletingPathExtension)),
                .assign(
                    field: "folder",
                    value: folder.isEmpty
                        ? .unset : .text(try SharedLibraryIdentity.legacy(relativePath: folder).uuidString.lowercased())
                ),
            ]
            let entry = metadata[path] ?? metadata[file.logicalName]
            if metadata[path] == nil, entry != nil, files.filter({ $0.logicalName == file.logicalName }).count > 1 {
                throw LegacyBootstrapError.ambiguousMetadata
            }
            if let entry {
                let bytes = try JSONSerialization.data(withJSONObject: entry, options: [.sortedKeys])
                changes.append(
                    .assign(
                        field: "legacyMetadata",
                        value: .document(
                            try SharedDocument(
                                id: SharedLibraryIdentity.legacy(relativePath: path + ".metadata.json"), json: bytes))))
            }
            let stem = root.appendingPathComponent(path).deletingPathExtension()
            for component in [SharedComponent.transcript, .summary] {
                let url = stem.appendingPathExtension(component.rawValue + ".json")
                if exists(url) {
                    let bytes = try await access.read(at: url)
                    if component == .transcript {
                        _ = try JSONDecoder().decode(Transcript.self, from: bytes)
                    } else {
                        _ = try JSONDecoder().decode(Summary.self, from: bytes)
                    }
                    changes.append(
                        .generation(
                            try SharedDocument(
                                id: SharedLibraryIdentity.legacy(
                                    relativePath: path + "." + component.rawValue + ".json"), json: bytes),
                            component: component))
                }
            }
            seeds.append(
                .init(
                    entity: .init(id: try SharedLibraryIdentity.legacy(relativePath: path), kind: .recording),
                    path: path, changes: changes))
        }
        for path in folders.sorted() {
            let parent = (path as NSString).deletingLastPathComponent
            seeds.append(
                .init(
                    entity: .init(id: try SharedLibraryIdentity.legacy(relativePath: path), kind: .folder), path: path,
                    changes: [
                        .assign(field: "initialPath", value: .text(path)),
                        .assign(field: "name", value: .text((path as NSString).lastPathComponent)),
                        .assign(
                            field: "parent",
                            value: parent.isEmpty
                                ? .unset
                                : .text(try SharedLibraryIdentity.legacy(relativePath: parent).uuidString.lowercased())),
                    ]))
        }
        let templates = root.appendingPathComponent(".templates.json")
        if exists(templates) {
            struct StoredTemplates: Decodable {
                let builtInOverrides: [Template]
                let userTemplates: [Template]
            }
            let stored = try JSONDecoder().decode(StoredTemplates.self, from: await access.read(at: templates))
            let values = stored.builtInOverrides + stored.userTemplates
            guard Set(values.map(\.id)).count == values.count else { throw LegacyBootstrapError.ambiguousMetadata }
            for template in values {
                let path = try SharedLibraryIdentity.normalized("template-" + template.id)
                seeds.append(
                    .init(
                        entity: .init(id: try SharedLibraryIdentity.legacy(relativePath: path), kind: .template),
                        path: path,
                        changes: [
                            .assign(field: "initialPath", value: .text(path)),
                            .assign(field: "templateID", value: .text(template.id)),
                            .assign(field: "name", value: .text(template.name)),
                            .assign(field: "description", value: .text(template.description)),
                            .assign(field: "prompt", value: .text(template.promptText)),
                            .assign(field: "isBuiltIn", value: .flag(template.isBuiltIn)),
                        ]))
            }
        }
        return seeds.sorted { ($0.entity.kind.rawValue, $0.path) < ($1.entity.kind.rawValue, $1.path) }
    }

    private func exists(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path)
            || FileManager.default.fileExists(
                atPath:
                    url.deletingLastPathComponent().appendingPathComponent(".\(url.lastPathComponent).icloud").path)
    }
    private func validateRoot() throws {
        guard
            (try? FileManager.default.attributesOfItem(atPath: root.path)[.type]) as? FileAttributeType
                == .typeDirectory
        else {
            throw SharedLibraryRepositoryError.unavailableRoot
        }
    }
    private func validate(_ url: URL) throws {
        guard url.resolvingSymlinksInPath().path.hasPrefix(root.path + "/") else {
            throw SharedLibraryRepositoryError.invalidPath
        }
    }
    private func prepareNamespace() throws {
        try validateRoot()
        for url in [root.appendingPathComponent(".docktape"), claimsURL] {
            try validate(url)
            if !FileManager.default.fileExists(atPath: url.path) {
                do { try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false) } catch {
                    guard
                        (try? FileManager.default.attributesOfItem(atPath: url.path)[.type]) as? FileAttributeType
                            == .typeDirectory
                    else { throw error }
                }
            }
        }
    }
    private func encoded(_ manifest: SharedBootstrapManifest) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(manifest)
    }
    private func decode(_ data: Data) throws -> SharedBootstrapManifest { try Self.decodeManifest(data) }
    private static func decodeManifest(_ data: Data) throws -> SharedBootstrapManifest {
        struct Probe: Decodable { let schemaVersion: Int }
        let version = try JSONDecoder().decode(Probe.self, from: data).schemaVersion
        guard version == 1 else { throw LegacyBootstrapError.unsupportedSchema(version) }
        let manifest = try JSONDecoder().decode(SharedBootstrapManifest.self, from: data)
        guard Set(manifest.references.map(\.entity)).count == manifest.references.count,
            manifest.references.allSatisfy({
                (try? SharedLibraryIdentity.normalized($0.initialPath)) == $0.initialPath && $0.sequence == 1
                    && $0.fingerprint.count == 64
            })
        else {
            throw LegacyBootstrapError.invalidManifest
        }
        return manifest
    }
}
