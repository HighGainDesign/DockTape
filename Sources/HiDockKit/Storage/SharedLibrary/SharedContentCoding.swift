// © 2026 High Gain Design. All rights reserved.
import Foundation

/// Existing app sidecars use ISO dates. Earlier tools/fixtures also used the
/// default reference-date number. Validation accepts both without rewriting the
/// original JSON or changing a content generation just to normalize its dates.
enum SharedContentCoding {
    static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { source in
            let value = try source.singleValueContainer()
            if let seconds = try? value.decode(Double.self) { return Date(timeIntervalSinceReferenceDate: seconds) }
            let text = try value.decode(String.self)
            let parser = ISO8601DateFormatter()
            parser.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = parser.date(from: text) { return date }
            parser.formatOptions = [.withInternetDateTime]
            if let date = parser.date(from: text) { return date }
            throw DecodingError.dataCorruptedError(in: value, debugDescription: "Unrecognized recording-content date")
        }
        return decoder
    }
}
