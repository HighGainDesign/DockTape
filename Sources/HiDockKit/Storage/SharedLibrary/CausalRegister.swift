// © 2026 High Gain Design. All rights reserved.
import Foundation

/// A write identifier scoped to one entity field. Counters are positive and
/// monotonic for a writer; timestamps have no role in causal ordering.
public struct CausalDot: Codable, Hashable, Sendable {
    public let writer: UUID
    public let counter: UInt64

    public init(writer: UUID, counter: UInt64) {
        self.writer = writer
        self.counter = counter
    }
}

public enum CausalRegisterError: Error, Equatable, Sendable {
    /// Restored/cloned writer state reused a dot for a different value.
    case conflictingDot(CausalDot)
    /// Never reuse a counter by wrapping it back to zero.
    case counterExhausted(UUID)
    case invalidContext
}

/// A state-based multi-value register. Concurrent differing values remain
/// available until a write observes and resolves them. Each instance represents
/// one semantic field, not an entire library or a distributed transaction.
public struct CausalRegister<Value: Codable & Hashable & Sendable>: Codable, Equatable, Sendable {
    private struct Entry: Codable, Hashable, Sendable {
        let dot: CausalDot
        let value: Value
    }

    private var entries: Set<Entry> = []
    private var clock: [UUID: UInt64] = [:]

    public init() {}

    /// Identical concurrent values display once while retaining both dots.
    public var values: Set<Value> { Set(entries.map(\.value)) }

    /// Current contributors only. Observed/consumed clocks are not authors of
    /// the current value; identical concurrent values can have several authors.
    public func writers(for value: Value) -> Set<UUID> {
        Set(entries.filter { $0.value == value }.map { $0.dot.writer })
    }

    public var resolvedValue: Value? {
        let current = values
        return current.count == 1 ? current.first : nil
    }

    public var isConflicted: Bool { values.count > 1 }

    public var causalContext: [CausalDot] {
        clock.map { CausalDot(writer: $0.key, counter: $0.value) }.sorted {
            $0.writer.uuidString < $1.writer.uuidString
        }
    }
    public func highestCounter(for writer: UUID) -> UInt64 { clock[writer] ?? 0 }

    /// Used only for namespaces retired by a certified entity checkpoint. The
    /// floor represents already consumed writes, not elapsed time or absence.
    public func applyingCausalFloor(_ context: [CausalDot]) throws -> Self {
        guard Set(context.map(\.writer)).count == context.count, context.allSatisfy({ $0.counter > 0 }) else {
            throw CausalRegisterError.invalidContext
        }
        var result = self
        let floor = Dictionary(uniqueKeysWithValues: context.map { ($0.writer, $0.counter) })
        result.entries = result.entries.filter { $0.dot.counter > (floor[$0.dot.writer] ?? 0) }
        for (writer, counter) in floor { result.clock[writer] = max(result.clock[writer] ?? 0, counter) }
        return result
    }

    /// Supersede the values this state has observed. A caller handling a draft
    /// must separately validate its base revision before assigning; it must not
    /// consume values the user has never reviewed.
    public mutating func assign(_ value: Value, by writer: UUID, counterAtLeast minimum: UInt64 = 1) throws {
        let (next, overflow) = (clock[writer] ?? 0).addingReportingOverflow(1)
        guard !overflow else { throw CausalRegisterError.counterExhausted(writer) }
        let accepted = max(next, minimum)
        clock[writer] = accepted
        entries = [Entry(dot: CausalDot(writer: writer, counter: accepted), value: value)]
    }

    /// Join is commutative, associative and idempotent for valid states.
    /// A dot present in the other context but absent from its values has been
    /// superseded there. Unknown dots are concurrent and must survive.
    public mutating func merge(_ other: Self) throws {
        let localByDot = Dictionary(uniqueKeysWithValues: entries.map { ($0.dot, $0.value) })
        for entry in other.entries {
            if let local = localByDot[entry.dot], local != entry.value {
                throw CausalRegisterError.conflictingDot(entry.dot)
            }
        }

        let retainedLocal = entries.filter { other.entries.contains($0) || !other.observes($0.dot) }
        let retainedRemote = other.entries.filter { entries.contains($0) || !observes($0.dot) }
        let joinedEntries = Set(retainedLocal).union(retainedRemote)
        var joinedClock = clock
        for (writer, counter) in other.clock {
            joinedClock[writer] = max(joinedClock[writer] ?? 0, counter)
        }
        entries = joinedEntries
        clock = joinedClock
    }

    private func observes(_ dot: CausalDot) -> Bool {
        (clock[dot.writer] ?? 0) >= dot.counter
    }

    private enum CodingKeys: String, CodingKey { case entries, context }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let decodedEntries = try container.decode([Entry].self, forKey: .entries)
        let decodedClock = try container.decode([CausalDot].self, forKey: .context)
        var validatedClock: [UUID: UInt64] = [:]
        for row in decodedClock {
            guard validatedClock[row.writer] == nil else {
                throw Self.invalid("Duplicate causal-context writer.", decoder: decoder)
            }
            validatedClock[row.writer] = row.counter
        }
        var dots: Set<CausalDot> = []
        for entry in decodedEntries {
            guard entry.dot.counter > 0,
                (validatedClock[entry.dot.writer] ?? 0) == entry.dot.counter
            else {
                throw Self.invalid("Value dot does not match its writer's current causal counter.", decoder: decoder)
            }
            guard dots.insert(entry.dot).inserted else {
                throw Self.invalid("Duplicate causal value dot.", decoder: decoder)
            }
        }
        entries = Set(decodedEntries)
        clock = validatedClock.filter { $0.value > 0 }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        // Stable collection order avoids different byte fingerprints merely
        // because two valid states were joined in a different delivery order.
        let sortedEntries = entries.sorted { lhs, rhs in
            if lhs.dot.writer != rhs.dot.writer {
                return lhs.dot.writer.uuidString < rhs.dot.writer.uuidString
            }
            return lhs.dot.counter < rhs.dot.counter
        }
        let sortedClock = clock.map { CausalDot(writer: $0.key, counter: $0.value) }
            .sorted { $0.writer.uuidString < $1.writer.uuidString }
        try container.encode(sortedEntries, forKey: .entries)
        try container.encode(sortedClock, forKey: .context)
    }

    private static func invalid(_ message: String, decoder: Decoder) -> DecodingError {
        .dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: message))
    }
}
