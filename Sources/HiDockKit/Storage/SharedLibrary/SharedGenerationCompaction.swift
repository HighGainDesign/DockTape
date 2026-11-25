// © 2026 High Gain Design. All rights reserved.
import Foundation

public enum SharedCompactionError: Error, Equatable, Sendable {
    case unresolvedState, invalidContext, incomparableContexts
}

/// One current causal floor per entity, bounded by writers rather than old
/// generation UUIDs. Active generation namespaces keep their existing values;
/// other namespaces treat covered dots as consumed. A quorum certificate must
/// authorize installing this context; pure construction is not that certificate.
public struct SharedGenerationCompaction: Codable, Equatable, Sendable {
    public let transcript: UUID?
    public let summary: UUID?
    public let context: [CausalDot]

    static func proposed(for state: SharedEntityState) throws -> Self {
        guard state.lifecycle != .uninitialized, state.lifecycle != .conflicted, state.conflicts.isEmpty else {
            throw SharedCompactionError.unresolvedState
        }
        var counters: [UUID: UInt64] = [:]
        for row in state.fields.values.flatMap(\.causalContext) + (state.compaction?.context ?? []) {
            counters[row.writer] = max(counters[row.writer] ?? 0, row.counter)
        }
        return .init(
            transcript: state.currentDocument(for: .transcript)?.id, summary: state.currentDocument(for: .summary)?.id,
            context: counters.map { .init(writer: $0.key, counter: $0.value) }.sorted {
                $0.writer.uuidString < $1.writer.uuidString
            })
    }
    func retires(component: SharedComponent, generation: UUID) -> Bool {
        generation != (component == .transcript ? transcript : summary)
    }
    func counter(for writer: UUID) -> UInt64 { context.first(where: { $0.writer == writer })?.counter ?? 0 }
    func joined(with other: Self) throws -> Self {
        let writers = Set(context.map(\.writer)).union(other.context.map(\.writer))
        let covers = writers.allSatisfy { counter(for: $0) >= other.counter(for: $0) }
        let covered = writers.allSatisfy { other.counter(for: $0) >= counter(for: $0) }
        if covers && covered {
            guard transcript == other.transcript, summary == other.summary else {
                throw SharedCompactionError.invalidContext
            }
            return self
        }
        if covers { return self }
        if covered { return other }
        throw SharedCompactionError.incomparableContexts
    }
    private enum CodingKeys: String, CodingKey { case transcript, summary, context }
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        transcript = try container.decodeIfPresent(UUID.self, forKey: .transcript)
        summary = try container.decodeIfPresent(UUID.self, forKey: .summary)
        context = try container.decode([CausalDot].self, forKey: .context)
        guard !context.isEmpty, context.allSatisfy({ $0.counter > 0 }),
            Set(context.map(\.writer)).count == context.count,
            context == context.sorted(by: { $0.writer.uuidString < $1.writer.uuidString })
        else { throw SharedCompactionError.invalidContext }
    }
    private init(transcript: UUID?, summary: UUID?, context: [CausalDot]) {
        self.transcript = transcript
        self.summary = summary
        self.context = context
    }
}
