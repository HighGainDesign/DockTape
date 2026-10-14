// © 2026 High Gain Design. All rights reserved.
import Foundation

/// Existing library.json entries become field-level semantic edits. The legacy
/// entry is a bootstrap seed only; explicit unset edits cannot fall back to it.
public actor SharedRecordingMetadataAdapter {
    public nonisolated let coordinator: SharedLibraryCoordinator
    private var displayed: [UUID: SharedLibraryViewSnapshot] = [:]
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
    public func load() async throws -> [String: RecordingStore.RecordingMeta] {
        let request = UUID(); loadRequest = request
        let views = try await coordinator.snapshots(kinds: [.recording, .folder])
        let index = try SharedLibraryPathIndex(states: views.map(\.state), caseSensitive: true)
        var result: [String: RecordingStore.RecordingMeta] = [:]
        for view in views where view.state.kind == .recording && view.state.lifecycle == .alive {
            guard let path = index.resolvedPaths[view.state.id] else { continue }
            guard result[path] == nil else { throw SharedLibraryPathError.ambiguousPath }
            result[path] = try Self.render(view)
        }
        await beforeLoadReturn()
        try Task.checkCancellation()
        if loadRequest == request { displayed = Dictionary(uniqueKeysWithValues: views.map { ($0.state.id, $0) }) }
        return result
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
        displayed[fresh.state.id] = accepted
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
    private static func render(_ view: SharedLibraryViewSnapshot) throws -> RecordingStore.RecordingMeta {
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
        return try JSONDecoder().decode(RecordingStore.RecordingMeta.self,
                                       from: JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]))
    }
}
