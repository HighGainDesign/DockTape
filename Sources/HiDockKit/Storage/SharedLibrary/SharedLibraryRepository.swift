// © 2026 High Gain Design. All rights reserved.
import Foundation
import CryptoKit

public struct SharedEntityIdentity: Codable, Hashable, Sendable {
    public let id: UUID
    public let kind: SharedEntityKind
    public init(id: UUID, kind: SharedEntityKind) { self.id = id; self.kind = kind }
}

public enum SharedLibraryRepositoryError: Error, Equatable, Sendable {
    case unsupportedSchema(Int)
    case invalidEnvelope
    case unavailableRoot
    case invalidPath
    case differentBinding
    case staleRevision
    case sequenceExhausted
}

public enum SharedLibraryMutation: Sendable {
    case assign(field: String, value: SharedFieldValue)
    case generation(SharedDocument, component: SharedComponent)
    case generationEdit(component: SharedComponent, generation: UUID, key: String, value: SharedFieldValue)
    case delete
    case restore
}

public struct SharedLibrarySnapshot: Sendable {
    public let state: SharedEntityState
    public let ownerSequence: UInt64
    public let fingerprint: String
    fileprivate let binding: String
    fileprivate let writer: UUID
    fileprivate let observed: [UUID: UInt64]
}

public struct SharedLibraryEdit: Sendable {
    public let base: SharedLibrarySnapshot
    public let changes: [SharedLibraryMutation]
    public init(base: SharedLibrarySnapshot, changes: [SharedLibraryMutation]) { self.base = base; self.changes = changes }
}

/// Current writer-owned files hold merged state. Empty-change commits persist
/// observations without creating an alive write, allowing safe stale replay and
/// later cohort acknowledgments. This is not membership or projection logic.
public actor SharedLibraryRepository {
    public nonisolated let root: URL
    public nonisolated let writerID: UUID
    private let access = CoordinatedFileAccess()
    private let binding: String

    public init(root: URL, writerID: UUID) {
        self.root = root.standardizedFileURL.resolvingSymlinksInPath()
        self.writerID = writerID
        binding = Self.hash(Data(self.root.path.utf8))
    }

    public func load(entity: SharedEntityIdentity) async throws -> SharedLibrarySnapshot {
        let root = self.root, writer = writerID, access = self.access, binding = self.binding
        let directory = Self.directory(entity, root: root)
        try Self.validate(directory, root: root)
        let files = try await Task.detached { try Self.validateRoot(root); return try Self.headFiles(directory) }.value
        let heads = try await withThrowingTaskGroup(of: Envelope.self, returning: [Envelope].self) { group in
            for file in files {
                try Self.validate(file.url, root: root)
                group.addTask {
                    let bytes = try await access.read(at: file.url)
                    return try Self.decode(bytes, entity: entity, expectedWriter: file.writer)
                }
            }
            var result: [Envelope] = []
            for try await head in group { result.append(head) }
            return result
        }
        var observed: [UUID: UInt64] = [:]
        for head in heads {
            for (source, sequence) in head.watermarks { observed[source] = max(observed[source] ?? 0, sequence) }
        }
        var state = SharedEntityState(id: entity.id, kind: entity.kind)
        for head in heads where head.sequence == observed[head.writerID] {
            state = try state.merged(with: head.state)
        }
        return try Self.snapshot(state, ownerSequence: observed[writer] ?? 0,
                                 observed: observed, binding: binding, writer: writer)
    }

    public func commit(_ edit: SharedLibraryEdit) async throws -> SharedLibrarySnapshot {
        guard edit.base.binding == binding, edit.base.writer == writerID else { throw SharedLibraryRepositoryError.differentBinding }
        let entity = SharedEntityIdentity(id: edit.base.state.id, kind: edit.base.state.kind)
        let root = self.root, writer = writerID, binding = self.binding
        let destination = Self.directory(entity, root: root).appendingPathComponent(writer.uuidString.lowercased() + ".json")
        try Self.validate(destination, root: root)
        try await Task.detached {
            try Self.prepareDirectory(entity, root: root)
        }.value
        return try await access.withWrite(at: destination) { scope in
            try Self.validateRoot(root)
            try Self.validate(scope.url, root: root)
            try scope.checkCancellation()
            let existing: Envelope?
            if FileManager.default.fileExists(atPath: scope.url.path) {
                existing = try Self.decode(Data(contentsOf: scope.url), entity: entity, expectedWriter: writer)
            } else { existing = nil }
            try scope.checkCancellation()
            var observed = edit.base.observed
            if let existing {
                for (source, sequence) in existing.watermarks { observed[source] = max(observed[source] ?? 0, sequence) }
            }
            var current = edit.base.state
            if let existing, existing.sequence == observed[writer] {
                current = try current.merged(with: existing.state)
            }
            try Self.validateBase(edit, against: current)
            for mutation in edit.changes { try Self.apply(mutation, to: &current, writer: writer) }
            if let existing, current == existing.state, observed == existing.watermarks {
                return try Self.snapshot(current, ownerSequence: existing.sequence, observed: observed, binding: binding, writer: writer)
            }
            if existing == nil && current.lifecycle == .uninitialized {
                return try Self.snapshot(current, ownerSequence: 0, observed: observed, binding: binding, writer: writer)
            }
            let (sequence, overflow) = (observed[writer] ?? 0).addingReportingOverflow(1)
            guard !overflow else { throw SharedLibraryRepositoryError.sequenceExhausted }
            observed[writer] = sequence
            let envelope = try Envelope(writerID: writer, sequence: sequence, state: current, watermarks: observed)
            let bytes = try Self.encode(envelope)
            try scope.checkCancellation()
            try bytes.write(to: scope.url, options: .atomic)
            return try Self.snapshot(current, ownerSequence: sequence, observed: observed, binding: binding, writer: writer)
        }
    }

    public func scan() async throws -> [SharedEntityIdentity] {
        let root = self.root
        return try await Task.detached {
            try Self.validateRoot(root)
            var result: [SharedEntityIdentity] = []
            for kind in [SharedEntityKind.recording, .folder, .template] {
                let parent = Self.parent(kind, root: root)
                try Self.validate(parent, root: root)
                for url in try Self.contents(parent) {
                    guard let id = UUID(uuidString: url.lastPathComponent) else { continue }
                    try Self.validate(url, root: root)
                    if !(try Self.headFiles(url)).isEmpty { result.append(.init(id: id, kind: kind)) }
                }
            }
            return result.sorted { ($0.kind.rawValue, $0.id.uuidString) < ($1.kind.rawValue, $1.id.uuidString) }
        }.value
    }

    /// Verify a bootstrap's referenced owner head before enrolling a writer.
    /// Later heads may supersede its seed, but retain the immutable initial claim.
    public func containsBootstrapReference(entity: SharedEntityIdentity, writer: UUID,
        sequence: UInt64, fingerprint: String, initialPath: String) async throws -> Bool {
        let destination = Self.directory(entity, root: root).appendingPathComponent(writer.uuidString.lowercased() + ".json")
        try Self.validateRoot(root)
        try Self.validate(destination, root: root)
        let files = try await Task.detached { try Self.headFiles(destination.deletingLastPathComponent()) }.value
        guard files.contains(where: { $0.url == destination }) else { return false }
        let envelope = try Self.decode(await access.read(at: destination), entity: entity, expectedWriter: writer)
        guard envelope.sequence >= sequence, envelope.state.value(for: "initialPath") == .text(initialPath) else { return false }
        if envelope.sequence > sequence { return true }
        return try Self.hash(Self.encode(envelope.state)) == fingerprint
    }

    private static func validateBase(_ edit: SharedLibraryEdit, against current: SharedEntityState) throws {
        for mutation in edit.changes {
            let fields: Set<String>
            switch mutation {
            case .assign(let field, _): fields = [field]
            case .generation(_, let component):
                fields = Set(edit.base.state.fields.keys.filter { $0.hasPrefix(component.rawValue + ".") })
                    .union(current.fields.keys.filter { $0.hasPrefix(component.rawValue + ".") })
                    .union([component.rawValue + ".content"])
            case .generationEdit(let component, let generation, let key, _):
                fields = [component.rawValue + ".content", "\(component.rawValue).edits.\(generation.uuidString.lowercased()).\(key)"]
            case .delete, .restore:
                guard edit.base.state == current else { throw SharedLibraryRepositoryError.staleRevision }
                continue
            }
            for field in fields where (edit.base.state.fields[field]?.values ?? []) != (current.fields[field]?.values ?? []) {
                throw SharedLibraryRepositoryError.staleRevision
            }
        }
    }

    private static func apply(_ mutation: SharedLibraryMutation, to state: inout SharedEntityState, writer: UUID) throws {
        switch mutation {
        case .assign(let field, let value): try state.assign(field: field, value: value, writer: writer)
        case .generation(let document, let component): try state.assignGeneration(document, component: component, writer: writer)
        case .generationEdit(let component, let generation, let key, let value):
            try state.assignGenerationEdit(component: component, generation: generation, key: key, value: value, writer: writer)
        case .delete: try state.delete(writer: writer)
        case .restore: try state.restore(writer: writer)
        }
    }

    private struct Probe: Decodable { let schemaVersion: Int }
    private struct Payload: Codable {
        let schemaVersion: Int
        let writerID: UUID
        let sequence: UInt64
        let state: SharedEntityState
        let observed: [CausalDot]
    }
    private struct Envelope: Codable, Sendable {
        let schemaVersion: Int
        let writerID: UUID
        let sequence: UInt64
        let state: SharedEntityState
        let observed: [CausalDot]
        let checksum: String
        var watermarks: [UUID: UInt64] { Dictionary(uniqueKeysWithValues: observed.map { ($0.writer, $0.counter) }) }
        var payload: Payload { .init(schemaVersion: schemaVersion, writerID: writerID, sequence: sequence, state: state, observed: observed) }

        init(writerID: UUID, sequence: UInt64, state: SharedEntityState, watermarks: [UUID: UInt64]) throws {
            schemaVersion = 1; self.writerID = writerID; self.sequence = sequence; self.state = state
            observed = watermarks.map { CausalDot(writer: $0.key, counter: $0.value) }.sorted { $0.writer.uuidString < $1.writer.uuidString }
            checksum = try SharedLibraryRepository.hash(SharedLibraryRepository.encode(Payload(schemaVersion: 1,
                writerID: writerID, sequence: sequence, state: state, observed: observed)))
        }
    }

    private static func decode(_ bytes: Data, entity: SharedEntityIdentity, expectedWriter: UUID?) throws -> Envelope {
        let decoder = JSONDecoder()
        let version = try decoder.decode(Probe.self, from: bytes).schemaVersion
        guard version == 1 else { throw SharedLibraryRepositoryError.unsupportedSchema(version) }
        let head = try decoder.decode(Envelope.self, from: bytes)
        guard head.sequence > 0, head.state.lifecycle != .uninitialized,
              head.state.id == entity.id, head.state.kind == entity.kind,
              expectedWriter == nil || head.writerID == expectedWriter,
              Set(head.observed.map(\.writer)).count == head.observed.count,
              head.observed.allSatisfy({ $0.counter > 0 }),
              head.observed.first(where: { $0.writer == head.writerID })?.counter == head.sequence,
              try hash(encode(head.payload)) == head.checksum else { throw SharedLibraryRepositoryError.invalidEnvelope }
        return head
    }

    private static func snapshot(_ state: SharedEntityState, ownerSequence: UInt64, observed: [UUID: UInt64],
                                  binding: String, writer: UUID) throws -> SharedLibrarySnapshot {
        .init(state: state, ownerSequence: ownerSequence, fingerprint: try hash(encode(state)),
              binding: binding, writer: writer, observed: observed)
    }

    private static func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(value)
    }
    private static func hash(_ bytes: Data) -> String { SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined() }

    private static func parent(_ kind: SharedEntityKind, root: URL) -> URL {
        let name: String
        switch kind { case .recording: name = "records"; case .folder: name = "folders"; case .template: name = "templates" }
        return root.appendingPathComponent(".docktape").appendingPathComponent(name)
    }
    private static func directory(_ entity: SharedEntityIdentity, root: URL) -> URL {
        parent(entity.kind, root: root).appendingPathComponent(entity.id.uuidString.lowercased())
    }
    private static func validateRoot(_ root: URL) throws {
        guard root.isFileURL else { throw SharedLibraryRepositoryError.invalidPath }
        // URL resource values cache prior existence. Query the filesystem afresh
        // so a disconnected/deleted provider root cannot look resident.
        guard (try? FileManager.default.attributesOfItem(atPath: root.path)[.type]) as? FileAttributeType == .typeDirectory else {
            throw SharedLibraryRepositoryError.unavailableRoot
        }
    }

    private static func prepareDirectory(_ entity: SharedEntityIdentity, root: URL) throws {
        try validateRoot(root)
        var current = root
        for name in [".docktape", parent(entity.kind, root: root).lastPathComponent, entity.id.uuidString.lowercased()] {
            current.appendPathComponent(name)
            try validate(current, root: root)
            if (try? current.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true { continue }
            do { try FileManager.default.createDirectory(at: current, withIntermediateDirectories: false) }
            catch {
                // A simultaneous creator may have made this same directory;
                // never repair a missing library root by recreating its parents.
                guard (try? current.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else { throw error }
            }
            try validate(current, root: root)
        }
    }

    private static func validate(_ url: URL, root: URL) throws {
        let prefix = root.path.hasSuffix("/") ? root.path : root.path + "/"
        guard url.standardizedFileURL.resolvingSymlinksInPath().path.hasPrefix(prefix) else {
            throw SharedLibraryRepositoryError.invalidPath
        }
    }
    private static func contents(_ directory: URL) throws -> [URL] {
        do { return try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) }
        catch {
            let ns = error as NSError
            if (ns.domain == NSCocoaErrorDomain && ns.code == NSFileReadNoSuchFileError) ||
                (ns.domain == NSPOSIXErrorDomain && ns.code == Int(ENOENT)) { return [] }
            throw error
        }
    }
    private static func headFiles(_ directory: URL) throws -> [(url: URL, writer: UUID?)] {
        try contents(directory).compactMap { source in
            let name = source.lastPathComponent
            let logical = name.hasPrefix(".") && name.hasSuffix(".icloud") ? String(name.dropFirst().dropLast(7)) : name
            guard logical.hasSuffix(".json"), !logical.hasPrefix(".") else { return nil }
            return (directory.appendingPathComponent(logical), UUID(uuidString: String(logical.dropLast(5))))
        }
    }
}
