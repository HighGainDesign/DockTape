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
  private let witness: SharedOwnerWitness?
  private let gate: SharedLibraryLocalGate?
  init(
    root: URL, writer: UUID, manifest: SharedBootstrapManifest, witness: SharedOwnerWitness? = nil,
    gate: SharedLibraryLocalGate? = nil
  ) {
    self.root = root.standardizedFileURL.resolvingSymlinksInPath()
    self.writer = writer
    self.witness = witness
    self.gate = gate
    initial = .init(
      libraryID: manifest.libraryID, founder: manifest.founder,
      bootstrapFingerprint: manifest.fingerprint)
  }
  private var directory: URL { root.appendingPathComponent(".docktape/members") }
  private var destination: URL {
    directory.appendingPathComponent(writer.uuidString.lowercased() + ".json")
  }
  private struct Payload: Codable, Sendable {
    let schemaVersion: Int
    let writer: UUID
    let sequence: UInt64
    let membership: SharedLibraryMembership
    let vote: SharedMembershipVote?
    let observed: [CausalDot]
    var sequences: [UUID: UInt64] {
      Dictionary(uniqueKeysWithValues: observed.map { ($0.writer, $0.counter) })
    }
  }
  private struct Envelope: Codable, Sendable {
    let payload: Payload
    let checksum: String
  }

  func load() async throws -> SharedMemberSnapshot {
    if let witness,
      !witness.isOutside(root) || !witness.matches(library: initial.libraryID, writer: writer)
    {
      throw SharedLibraryRepositoryError.differentBinding
    }
    let root = self.root
    let directory = self.directory
    let access = self.access
    let files = try await Task.detached {
      try Self.validateRoot(root)
      try Self.validate(directory, root: root)
      guard FileManager.default.fileExists(atPath: directory.path) else { return [URL]() }
      return try FileManager.default.contentsOfDirectory(
        at: directory, includingPropertiesForKeys: nil
      )
      .compactMap { file -> URL? in
        let name = file.lastPathComponent
        if name.hasPrefix("."), name.hasSuffix(".icloud") {
          return directory.appendingPathComponent(String(name.dropFirst().dropLast(7)))
        }
        return name.hasSuffix(".json") ? file : nil
      }
    }.value
    let heads = try await withThrowingTaskGroup(of: Payload.self, returning: [Payload].self) {
      group in
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
      for (owner, sequence) in head.sequences {
        sequences[owner] = max(sequences[owner] ?? 0, sequence)
      }
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
    if let witness {
      let destination = self.destination
      let writer = self.writer
      if FileManager.default.fileExists(atPath: destination.path)
        || FileManager.default.fileExists(atPath: witness.fileURL(for: "members").path)
      {
        let proof = SharedOwnerHeadSummary(
          sequence: sequences[writer] ?? 0,
          fingerprint: membership.fingerprint, membership: membership)
        let recovered: Payload? = try await witness.withWrite(
          at: destination, key: "members",
          decode: {
            try Self.witnessSummary(Self.decode($0, expected: writer))
          }, observed: proof
        ) { _, bytes in
          .init(bytes: nil, result: try bytes.map { try Self.decode($0, expected: writer) })
        }
        if let recovered {
          membership = try membership.merged(with: recovered.membership)
          for (source, sequence) in recovered.sequences {
            sequences[source] = max(sequences[source] ?? 0, sequence)
          }
          if recovered.sequence == sequences[writer], let vote = recovered.vote {
            votes[writer] = vote
          }
        }
      }
    }
    return .init(membership: membership, votes: votes, sequences: sequences)
  }

  func commit(
    base: SharedMemberSnapshot, membership: SharedLibraryMembership,
    vote: SharedMembershipVote? = nil,
    observing: Bool = false
  )
    async throws -> SharedMemberSnapshot
  {
    if let witness,
      !witness.isOutside(root) || !witness.matches(library: initial.libraryID, writer: writer)
    {
      throw SharedLibraryRepositoryError.differentBinding
    }
    let gate = self.gate
    let gateItems = try gate?.items(outside: root) ?? []
    _ = try initial.merged(with: membership)
    let root = self.root
    let directory = self.directory
    let writer = self.writer
    let destination = self.destination
    try await Task.detached {
      try Self.validateRoot(root)
      try Self.validate(directory, root: root)
      if !FileManager.default.fileExists(atPath: directory.path) {
        do {
          try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        } catch {
          guard
            (try? FileManager.default.attributesOfItem(atPath: directory.path)[.type])
              as? FileAttributeType
              == .typeDirectory
          else { throw error }
        }
      }
    }.value
    let execute:
      @Sendable (CoordinatedFileAccess.Scope, Data?) throws -> SharedOwnerPreparedWrite<
        SharedMemberSnapshot
      > = { scope, data in
        try Self.validateRoot(root)
        try Self.validate(scope.url, root: root)
        let existing = try data.map { try Self.decode($0, expected: writer) }
        let latest = existing?.membership ?? base.membership
        let current =
          try observing
          ? latest.merged(with: base.membership).merged(with: membership)
          : membership.rebased(from: base.membership, onto: latest)
        var sequences = base.sequences
        var votes = base.votes
        if let existing {
          for (owner, sequence) in existing.sequences {
            sequences[owner] = max(sequences[owner] ?? 0, sequence)
          }
          if let vote, existing.vote != base.votes[writer], existing.vote != vote {
            throw SharedLibraryRepositoryError.staleRevision
          }
        }
        let acceptedVote = vote ?? existing?.vote
        if let acceptedVote {
          guard acceptedVote.writer == writer else {
            throw SharedLibraryRepositoryError.invalidEnvelope
          }
          votes[writer] = acceptedVote
        }
        if let existing, existing.sequence == sequences[writer], existing.membership == current,
          existing.vote == acceptedVote
        {
          return .init(
            bytes: nil, result: .init(membership: current, votes: votes, sequences: sequences))
        }
        let (sequence, overflow) = (sequences[writer] ?? 0).addingReportingOverflow(1)
        guard !overflow else { throw SharedLibraryRepositoryError.sequenceExhausted }
        sequences[writer] = sequence
        let payload = Payload(
          schemaVersion: 1, writer: writer, sequence: sequence, membership: current,
          vote: acceptedVote,
          observed: sequences.map { .init(writer: $0.key, counter: $0.value) }.sorted {
            $0.writer.uuidString < $1.writer.uuidString
          })
        let envelope = Envelope(payload: payload, checksum: try SharedStateFingerprint.of(payload))
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let bytes = try encoder.encode(envelope)
        try scope.checkCancellation()
        return .init(
          bytes: bytes, result: .init(membership: current, votes: votes, sequences: sequences))
      }
    if let witness {
      let proof = SharedOwnerHeadSummary(
        sequence: base.sequences[writer] ?? 0,
        fingerprint: base.membership.fingerprint, membership: base.membership)
      return try await witness.withWrite(
        at: destination, key: "members",
        decode: {
          try Self.witnessSummary(Self.decode($0, expected: writer))
        }, observed: proof, gate: gate, body: execute)
    }
    return try await access.withWrites([.init(destination)] + gateItems) { scopes in
      let scope = scopes[0]
      if let gate { try gate.validate(scopes[scopes.count - 1], outside: root) }
      let bytes =
        FileManager.default.fileExists(atPath: scope.url.path)
        ? try Data(contentsOf: scope.url) : nil
      let prepared = try execute(scope, bytes)
      if let bytes = prepared.bytes {
        try scope.checkCancellation()
        try bytes.write(to: scope.url, options: .atomic)
      }
      return prepared.result
    }
  }
  private static func witnessSummary(_ payload: Payload) throws -> SharedOwnerHeadSummary {
    .init(
      sequence: payload.sequence, fingerprint: try SharedStateFingerprint.of(payload),
      membership: payload.membership)
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
