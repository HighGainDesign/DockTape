// © 2026 High Gain Design. All rights reserved.
import Foundation

public struct SharedProjectionMarker: Codable, Equatable, Sendable {
    public let schema: Int
    public let libraryID: UUID
    public let entities: [UUID]
    public let kind: String
    public let generation: UUID?
    public let revision: String
    public let bodyFingerprint: String
    public let hasConflicts: Bool
}

/// A content checksum, not a substitute for shared authority. A writer checks
/// its publication registry and library/entity binding before replacing JSON.
public enum SharedProjectionDocument {
    static let key = "_docktape"
    static func canonical(_ object: Any) throws -> Data {
        try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])
    }
    public static func make(body: [String: Any], libraryID: UUID, entities: [UUID], kind: String,
                            generation: UUID? = nil, revision: String, hasConflicts: Bool) throws -> Data {
        var body = body; body.removeValue(forKey: key)
        let marker = SharedProjectionMarker(schema: 1, libraryID: libraryID,
            entities: entities.sorted { $0.uuidString < $1.uuidString }, kind: kind, generation: generation,
            revision: revision, bodyFingerprint: SharedLibraryOperation.fingerprint(try canonical(body)), hasConflicts: hasConflicts)
        body[key] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(marker))
        return try JSONSerialization.data(withJSONObject: body, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
    }
    public static func marker(in bytes: Data) throws -> SharedProjectionMarker? {
        guard var body = try JSONSerialization.jsonObject(with: bytes) as? [String: Any] else { throw SharedSidecarError.invalidContent }
        guard let raw = body.removeValue(forKey: key) else { return nil }
        let marker = try JSONDecoder().decode(SharedProjectionMarker.self, from: canonical(raw))
        guard marker.schema == 1, Set(marker.entities).count == marker.entities.count,
              marker.entities == marker.entities.sorted(by: { $0.uuidString < $1.uuidString }),
              marker.bodyFingerprint == SharedLibraryOperation.fingerprint(try canonical(body)) else {
            throw SharedSidecarError.invalidContent
        }
        return marker
    }
}
