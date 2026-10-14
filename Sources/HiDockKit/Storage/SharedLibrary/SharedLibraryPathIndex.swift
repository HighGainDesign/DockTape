// © 2026 High Gain Design. All rights reserved.
import Foundation

public enum SharedLibraryPathError: Error, Equatable, Sendable {
    case invalidGraph, ambiguousPath, unknownPath, tooManyVariants
}

/// Current semantic claims, plus explicitly retained physical locations from
/// validated projections/receipts. Names never create or replace an identity.
/// Competing names reserve every candidate; pending deletes retain ownership.
public struct SharedLibraryPathIndex: Sendable {
    public let resolvedPaths: [UUID: String]
    private let claims: [String: Set<UUID>]
    private let caseSensitive: Bool
    private let kinds: [UUID: SharedEntityKind]
    public init(states: [SharedEntityState], caseSensitive: Bool,
                retainedLocations: [UUID: Set<String>] = [:]) throws {
        var entities: [UUID: SharedEntityState] = [:]
        for state in states {
            guard entities[state.id] == nil else { throw SharedLibraryPathError.invalidGraph }
            entities[state.id] = state
        }
        var claims: [String: Set<UUID>] = [:]
        var resolved: [UUID: String] = [:]
        func claim(_ path: String, owner: UUID) throws {
            let normalized = try SharedLibraryIdentity.normalized(path)
            let key = Self.key(normalized, caseSensitive: caseSensitive)
            claims[key, default: []].insert(owner)
        }
        func recordingClaims(_ path: String, owner: UUID) throws {
            guard (path as NSString).pathExtension.lowercased() == "mp3" else {
                throw SharedLibraryPathError.invalidGraph
            }
            try claim(path, owner: owner)
            let stem = (path as NSString).deletingPathExtension
            for suffix in [".transcript.json", ".summary.json", ".txt", ".transcript.md", ".summary.md"] {
                try claim(stem + suffix, owner: owner)
            }
        }
        func names(_ state: SharedEntityState, field: String) throws -> [String] {
            let values = state.fields[field]?.values ?? []
            guard !values.isEmpty else { throw SharedLibraryPathError.invalidGraph }
            return try values.map { value in
                guard case .text(let name) = value, !name.contains("/"),
                      (try? SharedLibraryIdentity.normalized(name)) != nil else {
                    throw SharedLibraryPathError.invalidGraph
                }
                return name
            }
        }
        func parents(_ state: SharedEntityState, field: String) throws -> [UUID?] {
            let values = state.fields[field]?.values ?? []
            guard !values.isEmpty else { throw SharedLibraryPathError.invalidGraph }
            return try values.map { value in
                if value == .unset { return nil }
                guard case .text(let text) = value, let id = UUID(uuidString: text) else {
                    throw SharedLibraryPathError.invalidGraph
                }
                return id
            }
        }
        func combine(_ prefixes: Set<String>, _ names: [String]) throws -> Set<String> {
            var result: Set<String> = []
            for prefix in prefixes {
                for name in names {
                    result.insert(prefix.isEmpty ? name : prefix + "/" + name)
                    // Never truncate unresolved path claims. A malformed or
                    // exceptionally divergent graph is read-only for operations.
                    guard result.count <= 256 else { throw SharedLibraryPathError.tooManyVariants }
                }
            }
            return result
        }
        func folderPaths(_ id: UUID?, visiting: Set<UUID>) throws -> Set<String> {
            guard let id else { return [""] }
            guard !visiting.contains(id), let folder = entities[id], folder.kind == .folder,
                  folder.lifecycle != .uninitialized else { throw SharedLibraryPathError.invalidGraph }
            var prefixes: Set<String> = []
            for parent in try parents(folder, field: "parent") {
                prefixes.formUnion(try folderPaths(parent, visiting: visiting.union([id])))
                guard prefixes.count <= 256 else { throw SharedLibraryPathError.tooManyVariants }
            }
            return try combine(prefixes, names(folder, field: "name"))
        }
        for state in states where state.kind != .template {
            guard state.lifecycle != .uninitialized else { throw SharedLibraryPathError.invalidGraph }
            let paths: Set<String>
            if state.kind == .folder {
                paths = try folderPaths(state.id, visiting: [])
                for path in paths { try claim(path, owner: state.id) }
                if case .text(let physical)? = state.value(for: "physicalPath") { try claim(physical, owner: state.id) }
            } else {
                var prefixes: Set<String> = []
                for folder in try parents(state, field: "folder") {
                    prefixes.formUnion(try folderPaths(folder, visiting: [state.id]))
                }
                paths = try combine(prefixes, names(state, field: "title").map { $0 + ".mp3" })
                for path in paths { try recordingClaims(path, owner: state.id) }
            }
            if paths.count == 1 { resolved[state.id] = paths.first }
        }
        for (id, paths) in retainedLocations {
            guard entities[id]?.kind == .recording else { throw SharedLibraryPathError.invalidGraph }
            for path in paths { try recordingClaims(path, owner: id) }
        }
        self.resolvedPaths = resolved
        self.claims = claims
        self.caseSensitive = caseSensitive
        self.kinds = entities.mapValues(\.kind)
    }
    public func owners(of relativePath: String) -> Set<UUID> {
        guard let path = try? SharedLibraryIdentity.normalized(relativePath) else { return [] }
        return claims[Self.key(path, caseSensitive: caseSensitive)] ?? []
    }
    public func recording(at relativePath: String) throws -> UUID {
        let path = try SharedLibraryIdentity.normalized(relativePath)
        let owners = owners(of: path)
        guard owners.count == 1, let id = owners.first, kinds[id] == .recording,
              let selected = resolvedPaths[id],
              Self.key(selected, caseSensitive: caseSensitive) == Self.key(path, caseSensitive: caseSensitive) else {
            throw owners.isEmpty ? SharedLibraryPathError.unknownPath : SharedLibraryPathError.ambiguousPath
        }
        return id
    }
    /// Include filesystem spellings requested by a physical plan. Case-folded
    /// ownership remains available even when a plan uses a different spelling.
    public func operationOwners(for paths: [String]) -> [String: Set<UUID>] {
        Dictionary(paths.map { ($0, owners(of: $0)) }, uniquingKeysWith: { $0.union($1) })
    }
    private static func key(_ path: String, caseSensitive: Bool) -> String {
        caseSensitive ? path : path.folding(options: .caseInsensitive, locale: Locale(identifier: "en_US_POSIX"))
    }
}
