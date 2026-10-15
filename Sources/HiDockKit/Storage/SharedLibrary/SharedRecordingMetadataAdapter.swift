// © 2026 High Gain Design. All rights reserved.
import Foundation

/// Existing library.json entries become field-level semantic edits. The legacy
/// entry is a bootstrap seed only; explicit unset edits cannot fall back to it.
public actor SharedRecordingMetadataAdapter {
    public nonisolated let coordinator: SharedLibraryCoordinator
    private var displayed: [UUID: SharedLibraryViewSnapshot] = [:]
    private var catalogViews: [UUID: SharedLibraryViewSnapshot] = [:]
    private var progressiveViews: [UUID: SharedLibraryViewSnapshot] = [:]
    private var loadRequest: UUID?
    private let beforeLoadReturn: @Sendable () async -> Void
    public init(coordinator: SharedLibraryCoordinator, beforeLoadReturn: @escaping @Sendable () async -> Void = {}) {
        self.coordinator = coordinator
        self.beforeLoadReturn = beforeLoadReturn
    }
    public nonisolated func requireRoot(_ root: URL) throws {
        guard root.standardizedFileURL.resolvingSymlinksInPath() == coordinator.root else {
            throw SharedLibraryCoordinatorError.differentBinding
        }
    }
    struct Visibility: Sendable {
        let paths: SharedLibraryPathIndex
        let deleted: Set<UUID>
        let allowed: Set<String>?
        init(paths: SharedLibraryPathIndex, deleted: Set<UUID>, allowed: Set<String>? = nil) {
            self.paths = paths; self.deleted = deleted; self.allowed = allowed
        }
        func hides(_ filename: String) -> Bool {
            if let allowed, !allowed.contains(filename) { return true }
            let owners = paths.owners(of: filename)
            return !owners.isEmpty && owners.isSubset(of: deleted)
        }
    }
    public func load() async throws -> [String: RecordingStore.RecordingMeta] { try await loadCatalog().metadata }
    typealias Catalog = (metadata: [String: RecordingStore.RecordingMeta], references: [String: SharedRecordingReference], revisions: [String: String], visibility: Visibility)
    func loadCatalog(onProgress: (@Sendable (Catalog) async -> Void)? = nil) async throws -> Catalog {
        let request = UUID(); loadRequest = request
        progressiveViews = catalogViews
        let views: [SharedLibraryViewSnapshot]
        if let onProgress {
            views = try await coordinator.snapshots(kinds: [.recording, .folder]) { view in
                await self.deliver(view, request: request, onProgress: onProgress)
            }
        } else { views = try await coordinator.snapshots(kinds: [.recording, .folder]) }
        let states = views.map(\.state)
        let deleted = Set(states.filter { $0.kind == .recording && $0.lifecycle == .deleted }.map(\.id))
        let index: SharedLibraryPathIndex
        if deleted.isEmpty {
            index = try SharedLibraryPathIndex(states: states, caseSensitive: true)
        } else {
            // Pending recipes retain originals, but trusted publication proofs
            // release completed aliases so unrelated files stay visible.
            index = try await coordinator.pathIndex(for: views, caseSensitive: true)
        }
        let visibility = Visibility(paths: index, deleted: deleted)
        var result: [String: RecordingStore.RecordingMeta] = [:]
        var references: [String: SharedRecordingReference] = [:]
        var revisions: [String: String] = [:]
        for view in views where view.state.kind == .recording && view.state.lifecycle == .alive {
            guard let path = index.resolvedPaths[view.state.id] else { continue }
            guard result[path] == nil else { throw SharedLibraryPathError.ambiguousPath }
            result[path] = try Self.render(view)
            references[path] = .init(libraryID: view.libraryID, entityID: view.state.id)
            revisions[path] = try SharedStateFingerprint.of(view.state)
        }
        await beforeLoadReturn()
        try Task.checkCancellation()
        if loadRequest == request {
            let accepted = Dictionary(uniqueKeysWithValues: views.map { ($0.state.id, $0) })
            displayed = accepted; catalogViews = accepted
        }
        return (result, references, revisions, visibility)
    }
    private func deliver(_ view: SharedLibraryViewSnapshot, request: UUID, onProgress: @Sendable (Catalog) async -> Void) async {
        guard loadRequest == request, !Task.isCancelled else { return }
        progressiveViews[view.state.id] = view
        catalogViews[view.state.id] = view
        guard let catalog = try? Self.partialCatalog(progressiveViews) else { return }
        for reference in catalog.references.values { displayed[reference.entityID] = progressiveViews[reference.entityID] }
        // Folder baselines also carry the ancestor graph across a refresh.
        for value in progressiveViews.values where value.state.kind == .folder { displayed[value.state.id] = value }
        await onProgress(catalog)
    }
    private static func partialCatalog(_ views: [UUID: SharedLibraryViewSnapshot]) throws -> Catalog {
        func ancestors(_ state: SharedEntityState, field: String, visiting: Set<UUID>) -> [UUID: SharedEntityState]? {
            guard let values = state.fields[field]?.values, !values.isEmpty else { return nil }
            var result: [UUID: SharedEntityState] = [:]
            for value in values {
                if value == .unset { continue }
                guard case .text(let text) = value, let id = UUID(uuidString: text), !visiting.contains(id),
                      let folder = views[id]?.state, folder.kind == .folder, folder.lifecycle == .alive,
                      let parents = ancestors(folder, field: "parent", visiting: visiting.union([id])) else { return nil }
                result.merge(parents) { old, _ in old }; result[id] = folder
            }
            return result
        }
        var ready: [UUID: SharedEntityState] = [:]
        for view in views.values where view.state.kind == .recording && view.state.lifecycle != .uninitialized {
            guard let folders = ancestors(view.state, field: "folder", visiting: [view.state.id]),
                  (try? SharedLibraryPathIndex(states: Array(folders.values) + [view.state], caseSensitive: true)) != nil else { continue }
            ready.merge(folders) { old, _ in old }; ready[view.state.id] = view.state
        }
        let index = try SharedLibraryPathIndex(states: Array(ready.values), caseSensitive: true)
        var metadata: [String: RecordingStore.RecordingMeta] = [:]
        var references: [String: SharedRecordingReference] = [:]
        var revisions: [String: String] = [:]
        for state in ready.values where state.kind == .recording && state.lifecycle == .alive {
            guard let view = views[state.id], let path = index.resolvedPaths[state.id], index.owners(of: path) == [state.id],
                  let item = try? render(view) else { continue }
            metadata[path] = item; references[path] = .init(libraryID: view.libraryID, entityID: state.id)
            revisions[path] = try SharedStateFingerprint.of(view.state)
        }
        return (metadata, references, revisions, .init(paths: index, deleted: Set(ready.values.filter { $0.kind == .recording && $0.lifecycle == .deleted }.map(\.id)), allowed: Set(references.keys)))
    }
    public func save(filename: String, before: RecordingStore.RecordingMeta?, after: RecordingStore.RecordingMeta) async throws -> RecordingStore.RecordingMeta {
        loadRequest = nil
        let fresh = try await coordinator.recording(at: filename)
        guard let base = displayed[fresh.state.id] else { throw SharedSidecarError.reloadRequired }
        let old = try Self.object(before ?? RecordingStore.RecordingMeta())
        let desired = try Self.object(after)
        var changes: [SharedLibraryMutation] = []
        for key in Set(old.keys).union(desired.keys).sorted() {
            let previous = try old[key].map(Self.bytes)
            let next = try desired[key].map(Self.bytes)
            guard previous != next else { continue }
            let field = "metadata." + key
            guard base.state.fields[field]?.isConflicted != true else { throw SharedSidecarError.conflictedContent }
            let value = next.map { SharedFieldValue.text(String(decoding: $0, as: UTF8.self)) } ?? .unset
            changes.append(.assign(field: field, value: value))
        }
        guard !changes.isEmpty else { return try Self.render(fresh) }
        let accepted = try await coordinator.edit(.init(base: base, changes: changes))
        // Loads started during the suspended commit also precede this baseline.
        loadRequest = nil
        displayed[fresh.state.id] = accepted
        catalogViews[fresh.state.id] = accepted
        return try Self.render(accepted)
    }
    private static func object(_ meta: RecordingStore.RecordingMeta) throws -> [String: Any] {
        guard let value = try JSONSerialization.jsonObject(with: JSONEncoder().encode(meta)) as? [String: Any] else {
            throw SharedSidecarError.invalidContent
        }
        return value
    }
    private static func bytes(_ value: Any) throws -> Data {
        try JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed, .sortedKeys, .withoutEscapingSlashes])
    }
    static func render(_ view: SharedLibraryViewSnapshot) throws -> RecordingStore.RecordingMeta {
        try JSONDecoder().decode(RecordingStore.RecordingMeta.self, from: JSONSerialization.data(withJSONObject: renderObject(view), options: [.sortedKeys]))
    }
    static func renderObject(_ view: SharedLibraryViewSnapshot) throws -> [String: Any] {
        var object: [String: Any] = [:]
        if case .document(let seed)? = view.state.value(for: "legacyMetadata") {
            guard let original = try JSONSerialization.jsonObject(with: seed.json) as? [String: Any] else {
                throw SharedSidecarError.invalidContent
            }
            object = original
        }
        for (field, register) in view.state.fields where field.hasPrefix("metadata.") {
            let value = register.isConflicted ? view.confirmedState?.fields[field]?.resolvedValue : register.resolvedValue
            guard let value else { continue }
            let key = String(field.dropFirst("metadata.".count))
            switch value {
            case .unset: object.removeValue(forKey: key)
            case .text(let encoded): object[key] = try JSONSerialization.jsonObject(with: Data(encoded.utf8), options: [.fragmentsAllowed])
            default: throw SharedSidecarError.invalidContent
            }
        }
        return object
    }
}
