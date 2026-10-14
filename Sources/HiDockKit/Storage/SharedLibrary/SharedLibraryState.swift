// © 2026 High Gain Design. All rights reserved.
import Foundation

public enum SharedEntityKind: String, Codable, Sendable { case recording, folder, template }
public enum SharedComponent: String, Codable, Sendable { case transcript, summary }
public enum SharedLifecycle: Sendable, Equatable { case uninitialized, alive, deleted, conflicted }

public enum SharedEntityError: Error, Equatable, Sendable {
    case differentEntity
    case differentKind
    case invalidField
    case deletedOrConflictedLifecycle
    case staleGeneration
    case invalidState
}

public struct SharedEntityConflict: Sendable, Equatable {
    public let field: String
    public let values: Set<SharedFieldValue>
    public let inactiveGeneration: UUID?
}

/// The pure semantic state. Repository revisions, membership acknowledgments,
/// projection confirmation and physical filesystem operations live above it.
public struct SharedEntityState: Codable, Equatable, Sendable {
    public let id: UUID
    public let kind: SharedEntityKind
    public private(set) var fields: [String: CausalRegister<SharedFieldValue>] = [:]
    private static var lifecycleField: String { "$lifecycle" }

    public init(id: UUID, kind: SharedEntityKind) {
        self.id = id
        self.kind = kind
    }

    public var lifecycle: SharedLifecycle {
        let values = fields[Self.lifecycleField]?.values ?? []
        if values.isEmpty { return .uninitialized }
        if values == [.flag(true)] { return .alive }
        if values == [.flag(false)] { return .deleted }
        return .conflicted
    }

    public func value(for field: String) -> SharedFieldValue? {
        guard let value = fields[field]?.resolvedValue, value != .unset else { return nil }
        return value
    }

    public var conflicts: [SharedEntityConflict] {
        fields.keys.sorted().compactMap { field in
            guard let register = fields[field] else { return nil }
            let edit = Self.editIdentity(field)
            let inactive = edit.flatMap { component, generation, _ in
                generationValues(for: component).contains(where: { $0.id == generation }) ? nil : generation
            }
            let hasRetainedEdit = register.values.contains { $0 != .unset }
            guard register.isConflicted || (inactive != nil && hasRetainedEdit) else { return nil }
            return SharedEntityConflict(field: field, values: register.values, inactiveGeneration: inactive)
        }
    }

    public mutating func assign(field: String, value: SharedFieldValue, writer: UUID) throws {
        guard !field.isEmpty, !field.contains("\0"), !field.hasPrefix("$"),
              !field.hasPrefix("transcript."), !field.hasPrefix("summary.") else {
            throw SharedEntityError.invalidField
        }
        try edit(writer: writer) { try $0.write(field: field, value: value, writer: writer) }
    }

    public mutating func delete(writer: UUID) throws {
        var updated = self
        try updated.write(field: Self.lifecycleField, value: .flag(false), writer: writer)
        self = updated
    }

    /// A deliberate resolution, never called by scan, cache refresh or projection.
    public mutating func restore(writer: UUID) throws {
        var updated = self
        try updated.write(field: Self.lifecycleField, value: .flag(true), writer: writer)
        self = updated
    }

    public func merged(with other: Self) throws -> Self {
        guard id == other.id else { throw SharedEntityError.differentEntity }
        guard kind == other.kind else { throw SharedEntityError.differentKind }
        var result = self
        for (field, incoming) in other.fields {
            var current = result.fields[field] ?? CausalRegister<SharedFieldValue>()
            try current.merge(incoming)
            if [SharedComponent.transcript, .summary].contains(where: { field == Self.generationField($0) }) {
                try Self.validateGenerationValues(current.values)
            }
            result.fields[field] = current
        }
        return result
    }

    public func generationValues(for component: SharedComponent) -> Set<SharedDocument> {
        Set((fields[Self.generationField(component)]?.values ?? []).compactMap {
            if case .document(let document) = $0 { return document }
            return nil
        })
    }

    public func currentDocument(for component: SharedComponent) -> SharedDocument? {
        guard case .document(let document)? = value(for: Self.generationField(component)) else { return nil }
        return document
    }

    public mutating func assignGeneration(_ document: SharedDocument, component: SharedComponent, writer: UUID) throws {
        guard !generationValues(for: component).contains(where: { $0.id == document.id && $0.json != document.json }) else {
            throw SharedEntityError.invalidState
        }
        try edit(writer: writer) { updated in
            // Replacement explicitly consumes only the old edits this snapshot
            // observed. A concurrent late edit remains alongside the unset marker.
            for field in updated.fields.keys.sorted() {
                if let (owner, generation, _) = Self.editIdentity(field),
                   owner == component, generation != document.id,
                   updated.fields[field]?.values.contains(where: { $0 != .unset }) == true {
                    try updated.write(field: field, value: .unset, writer: writer)
                }
            }
            try updated.write(field: Self.generationField(component), value: .document(document), writer: writer)
        }
    }

    public mutating func assignGenerationEdit(component: SharedComponent, generation: UUID,
                                               key: String, value: SharedFieldValue, writer: UUID) throws {
        guard currentDocument(for: component)?.id == generation else { throw SharedEntityError.staleGeneration }
        guard !key.isEmpty, !key.contains("\0"), Self.validEditValue(value, component: component) else {
            throw SharedEntityError.invalidField
        }
        let field = "\(component.rawValue).edits.\(generation.uuidString.lowercased()).\(key)"
        try edit(writer: writer) { try $0.write(field: field, value: value, writer: writer) }
    }

    public func generationEdits(for component: SharedComponent) -> [String: SharedFieldValue] {
        guard let current = currentDocument(for: component) else { return [:] }
        var result: [String: SharedFieldValue] = [:]
        for field in fields.keys {
            if let (owner, generation, key) = Self.editIdentity(field),
               owner == component, generation == current.id, let value = value(for: field) {
                result[key] = value
            }
        }
        return result
    }

    private mutating func edit(writer: UUID, action: (inout Self) throws -> Void) throws {
        guard lifecycle == .alive || lifecycle == .uninitialized else {
            throw SharedEntityError.deletedOrConflictedLifecycle
        }
        var updated = self
        try action(&updated)
        try updated.write(field: Self.lifecycleField, value: .flag(true), writer: writer)
        self = updated
    }

    private mutating func write(field: String, value: SharedFieldValue, writer: UUID) throws {
        var register = fields[field] ?? CausalRegister<SharedFieldValue>()
        try register.assign(value, by: writer)
        fields[field] = register
    }

    private static func validEditValue(_ value: SharedFieldValue, component: SharedComponent) -> Bool {
        if value == .unset { return true }
        switch (component, value) {
        case (.transcript, .text), (.summary, .flag): return true
        default: return false
        }
    }

    private static func validateGenerationValues(_ values: Set<SharedFieldValue>) throws {
        var contentByID: [UUID: Data] = [:]
        for value in values {
            guard case .document(let document) = value else { continue }
            if let previous = contentByID[document.id], previous != document.json { throw SharedEntityError.invalidState }
            contentByID[document.id] = document.json
        }
    }

    private static func generationField(_ component: SharedComponent) -> String { "\(component.rawValue).content" }

    private static func editIdentity(_ field: String) -> (SharedComponent, UUID, String)? {
        let parts = field.split(separator: ".", maxSplits: 3, omittingEmptySubsequences: false)
        guard parts.count == 4, let component = SharedComponent(rawValue: String(parts[0])),
              parts[1] == "edits", let generation = UUID(uuidString: String(parts[2])), !parts[3].isEmpty else { return nil }
        return (component, generation, String(parts[3]))
    }

    private enum CodingKeys: String, CodingKey { case id, kind, fields }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        kind = try container.decode(SharedEntityKind.self, forKey: .kind)
        fields = try container.decode([String: CausalRegister<SharedFieldValue>].self, forKey: .fields)
        guard fields.isEmpty || fields[Self.lifecycleField] != nil else { throw SharedEntityError.invalidState }
        for (field, register) in fields {
            guard !field.isEmpty, !field.contains("\0") else { throw SharedEntityError.invalidState }
            if field == Self.lifecycleField {
                guard register.values.allSatisfy({ $0 == .flag(true) || $0 == .flag(false) }) else {
                    throw SharedEntityError.invalidState
                }
            } else if field.hasPrefix("$") {
                throw SharedEntityError.invalidState
            }
            for component in [SharedComponent.transcript, .summary] {
                if field == Self.generationField(component) {
                    try Self.validateGenerationValues(register.values)
                    guard register.values.allSatisfy({ if case .document = $0 { return true }; return $0 == .unset }) else {
                        throw SharedEntityError.invalidState
                    }
                } else if field.hasPrefix(component.rawValue + ".") {
                    guard Self.editIdentity(field) != nil,
                          register.values.allSatisfy({ Self.validEditValue($0, component: component) }) else {
                        throw SharedEntityError.invalidState
                    }
                }
            }
        }
    }
}
