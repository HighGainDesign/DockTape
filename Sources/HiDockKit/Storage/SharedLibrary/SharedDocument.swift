// © 2026 High Gain Design. All rights reserved.
import Foundation

/// A generation ID and its entire JSON content travel as one causal value.
public struct SharedDocument: Codable, Hashable, Sendable {
    public let id: UUID
    public let json: Data

    public init(id: UUID, json: Data) throws {
        let object = try JSONSerialization.jsonObject(with: json, options: [.fragmentsAllowed])
        self.json = try JSONSerialization.data(withJSONObject: object,
            options: [.sortedKeys, .fragmentsAllowed, .withoutEscapingSlashes])
        self.id = id
    }

    private enum CodingKeys: String, CodingKey { case id, json }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(id: container.decode(UUID.self, forKey: .id),
                      json: container.decode(Data.self, forKey: .json))
    }
}

public enum SharedFieldValue: Codable, Hashable, Sendable {
    case text(String)
    case flag(Bool)
    case document(SharedDocument)
    /// An explicit causal removal. Dropping a dictionary key would lose context.
    case unset
}
