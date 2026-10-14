// © 2026 High Gain Design. All rights reserved.
import Foundation

struct SharedMemberSnapshot: Sendable {
    let membership: SharedLibraryMembership
    let votes: [UUID: SharedMembershipVote]
    let sequences: [UUID: UInt64]
}

/// Each Mac writes only its own membership envelope. Certificates copy durable
/// votes, while the current vote remains owned by its writer. An aggregate cannot
/// overwrite a peer's newer vote or infer consent from a clock/timeout.
actor SharedMemberRepository {
    private let root: URL
    private let writer: UUID
    private let initial: SharedLibraryMembership
    private let access = CoordinatedFileAccess()
    init(root: URL, writer: UUID, manifest: SharedBootstrapManifest) {
        self.root = root.standardizedFileURL.resolvingSymlinksInPath()
        self.writer = writer
        initial = .init(
            libraryID: manifest.libraryID, founder: manifest.founder, bootstrapFingerprint: manifest.fingerprint)
    }
    private var directory: URL { root.appendingPathComponent(".docktape/members") }
    private var destination: URL { directory.appendingPathComponent(writer.uuidString.lowercased() + ".json") }
    private struct Payload: Codable, Sendable {
        let schemaVersion: Int
        let writer: UUID
        let sequence: UInt64
        let membership: SharedLibraryMembership
        let vote: SharedMembershipVote?
        let observed: [CausalDot]
        var sequences: [UUID: UInt64] { Dictionary(uniqueKeysWithValues: observed.map { ($0.writer, $0.counter) }) }
    }
    private struct Envelope: Codable, Sendable {
        let payload: Payload
        let checksum: String
    }

    func load() async throws -> SharedMemberSnapshot {
        let root = self.root
        let directory = self.directory
        let access = self.access
        let files = try await Task.detached {
            try Self.validateRoot(root)
            try Self.validate(directory, root: root)
            guard FileManager.default.fileExists(atPath: directory.path) else { return [URL]() }
            return try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
                .compactMap { file -> URL? in
                    let name = file.lastPathComponent
                    if name.hasPrefix("."), name.hasSuffix(".icloud") {
                        return directory.appendingPathComponent(String(name.dropFirst().dropLast(7)))
                    }
                    return name.hasSuffix(".json") ? file : nil
                }
        }.value
        let heads = try await withThrowingTaskGroup(of: Payload.self, returning: [Payload].self) { group in
            for file in files {
                try Self.validate(file, root: root)
                group.addTask {
                    try Self.decode(
                        await access.read(at: file),
                        expected: UUID(uuidString: file.deletingPathExtension().lastPathComponent))
                }
            }
            var result: [Payload] = []
            for try await head in group { result.append(head) }
            return result
        }
        var sequences: [UUID: UInt64] = [:]
        for head in heads {
            for (owner, sequence) in head.sequences { sequences[owner] = max(sequences[owner] ?? 0, sequence) }
        }
        var membership = initial
        var votes: [UUID: SharedMembershipVote] = [:]
        var seen: [UUID: Payload] = [:]
        for head in heads where head.sequence == sequences[head.writer] {
            if let previous = seen[head.writer],
                try SharedStateFingerprint.of(previous) != SharedStateFingerprint.of(head)
            {
                throw SharedLibraryRepositoryError.invalidEnvelope
            }
            seen[head.writer] = head
            membership = try membership.merged(with: head.membership)
            if let vote = head.vote { votes[head.writer] = vote }
        }
        return .init(membership: membership, votes: votes, sequences: sequences)
    }

    func commit(
        base: SharedMemberSnapshot, membership: SharedLibraryMembership, vote: SharedMembershipVote? = nil,
        observing: Bool = false
    )
        async throws -> SharedMemberSnapshot
    {
        _ = try initial.merged(with: membership)
        let root = self.root
        let directory = self.directory
        let writer = self.writer
        let destination = self.destination
        try await Task.detached {
            try Self.validateRoot(root)
            try Self.validate(directory, root: root)
            if !FileManager.default.fileExists(atPath: directory.path) {
                do { try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false) } catch
                {
                    guard
                        (try? FileManager.default.attributesOfItem(atPath: directory.path)[.type]) as? FileAttributeType
                            == .typeDirectory
                    else { throw error }
                }
            }
        }.value
        return try await access.withWrite(at: destination) { scope in
            try Self.validateRoot(root)
            try Self.validate(scope.url, root: root)
            let existing =
                FileManager.default.fileExists(atPath: scope.url.path)
                ? try Self.decode(Data(contentsOf: scope.url), expected: writer) : nil
            let latest = existing?.membership ?? base.membership
            let current =
                try observing
                ? latest.merged(with: base.membership).merged(with: membership)
                : membership.rebased(from: base.membership, onto: latest)
            var sequences = base.sequences
            var votes = base.votes
            if let existing {
                for (owner, sequence) in existing.sequences { sequences[owner] = max(sequences[owner] ?? 0, sequence) }
                if let vote, existing.vote != base.votes[writer], existing.vote != vote {
                    throw SharedLibraryRepositoryError.staleRevision
                }
            }
            let acceptedVote = vote ?? existing?.vote
            if let acceptedVote {
                guard acceptedVote.writer == writer else { throw SharedLibraryRepositoryError.invalidEnvelope }
                votes[writer] = acceptedVote
            }
            if let existing, existing.membership == current, existing.vote == acceptedVote {
                return .init(membership: current, votes: votes, sequences: sequences)
            }
            let (sequence, overflow) = (sequences[writer] ?? 0).addingReportingOverflow(1)
            guard !overflow else { throw SharedLibraryRepositoryError.sequenceExhausted }
            sequences[writer] = sequence
            let payload = Payload(
                schemaVersion: 1, writer: writer, sequence: sequence, membership: current, vote: acceptedVote,
                observed: sequences.map { .init(writer: $0.key, counter: $0.value) }.sorted {
                    $0.writer.uuidString < $1.writer.uuidString
                })
            let envelope = Envelope(payload: payload, checksum: try SharedStateFingerprint.of(payload))
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
            let bytes = try encoder.encode(envelope)
            try scope.checkCancellation()
            try bytes.write(to: scope.url, options: .atomic)
            return .init(membership: current, votes: votes, sequences: sequences)
        }
    }
    private static func decode(_ bytes: Data, expected: UUID?) throws -> Payload {
        struct Probe: Decodable {
            struct Header: Decodable { let schemaVersion: Int }
            let payload: Header
        }
        let version = try JSONDecoder().decode(Probe.self, from: bytes).payload.schemaVersion
        guard version == 1 else { throw SharedLibraryRepositoryError.unsupportedSchema(version) }
        let envelope = try JSONDecoder().decode(Envelope.self, from: bytes)
        let head = envelope.payload
        guard head.sequence > 0, expected == nil || expected == head.writer,
            Set(head.observed.map(\.writer)).count == head.observed.count,
            head.observed.allSatisfy({ $0.counter > 0 }), head.sequences[head.writer] == head.sequence,
            head.vote == nil || head.vote?.writer == head.writer,
            try SharedStateFingerprint.of(head) == envelope.checksum
        else { throw SharedLibraryRepositoryError.invalidEnvelope }
        return head
    }
    private static func validateRoot(_ root: URL) throws {
        guard
            (try? FileManager.default.attributesOfItem(atPath: root.path)[.type]) as? FileAttributeType
                == .typeDirectory
        else {
            throw SharedLibraryRepositoryError.unavailableRoot
        }
    }
    private static func validate(_ url: URL, root: URL) throws {
        guard url.resolvingSymlinksInPath().path.hasPrefix(root.path + "/") else {
            throw SharedLibraryRepositoryError.invalidPath
        }
    }
}
