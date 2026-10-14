// © 2026 High Gain Design. All rights reserved.
import Foundation

public enum SharedOwnerWitnessError: Error, Equatable, Sendable {
  case invalidWitness, differentBinding, rollback, reusedSequence, pendingRootChanged
}
public struct SharedOwnerHeadSummary: Codable, Equatable, Sendable {
  public let sequence: UInt64
  public let fingerprint: String
  public let contexts: [String: [CausalDot]]
  public let retired: [CausalDot]
  public let membership: SharedLibraryMembership?
  public let activeGenerations: Set<UUID>
  public init(
    sequence: UInt64, fingerprint: String, contexts: [String: [CausalDot]] = [:],
    retired: [CausalDot] = [], membership: SharedLibraryMembership? = nil,
    activeGenerations: Set<UUID> = []
  ) {
    self.sequence = sequence
    self.fingerprint = fingerprint
    self.contexts = contexts
    self.retired = retired
    self.membership = membership
    self.activeGenerations = activeGenerations
  }
  private enum CodingKeys: String, CodingKey {
    case sequence, fingerprint, contexts, retired, membership, activeGenerations
  }
  public func encode(to encoder: Encoder) throws {
    var values = encoder.container(keyedBy: CodingKeys.self)
    try values.encode(sequence, forKey: .sequence)
    try values.encode(fingerprint, forKey: .fingerprint)
    try values.encode(contexts, forKey: .contexts)
    try values.encode(retired, forKey: .retired)
    try values.encodeIfPresent(membership, forKey: .membership)
    try values.encode(
      activeGenerations.sorted { $0.uuidString < $1.uuidString }, forKey: .activeGenerations)
  }
  func validate() throws {
    guard sequence > 0, SharedLibraryOperation.validHash(fingerprint) else {
      throw SharedOwnerWitnessError.invalidWitness
    }
    for dots in Array(contexts.values) + [retired] {
      guard dots.allSatisfy({ $0.counter > 0 }), Set(dots.map(\.writer)).count == dots.count else {
        throw SharedOwnerWitnessError.invalidWitness
      }
    }
  }
  func covers(_ previous: Self) throws -> Bool {
    if let membership = previous.membership {
      guard let current = self.membership, try current.merged(with: membership) == current else {
        return false
      }
    }
    let floor = Dictionary(uniqueKeysWithValues: retired.map { ($0.writer, $0.counter) })
    for (field, dots) in previous.contexts {
      let current = Dictionary(
        uniqueKeysWithValues: (contexts[field] ?? []).map { ($0.writer, $0.counter) })
      let pieces = field.split(separator: ".", maxSplits: 3)
      let isRetiredEdit =
        pieces.count == 4 && ["transcript", "summary"].contains(String(pieces[0]))
        && pieces[1] == "edits"
        && UUID(uuidString: String(pieces[2])).map { !activeGenerations.contains($0) } == true
      for dot in dots {
        let covered = max(current[dot.writer] ?? 0, isRetiredEdit ? (floor[dot.writer] ?? 0) : 0)
        if covered < dot.counter { return false }
      }
    }
    return true
  }
}
public struct SharedOwnerPreparedWrite<Output: Sendable>: Sendable {
  public let bytes: Data?
  public let result: Output
  public init(bytes: Data?, result: Output) {
    self.bytes = bytes
    self.result = result
  }
}

/// One current local checkpoint/journal per owner stream, outside the provider.
/// Pending bytes are an in-progress metadata publication, not an audio backup
/// or a historical archive. They are cleared once its shared commit is witnessed.
public struct SharedOwnerWitness: Sendable {
  private let directory: URL
  private let libraryID: UUID
  private let writerID: UUID
  private let access = CoordinatedFileAccess()
  public init(directory: URL, libraryID: UUID, writerID: UUID) {
    self.directory = directory.standardizedFileURL.resolvingSymlinksInPath()
    self.libraryID = libraryID
    self.writerID = writerID
  }
  func isOutside(_ root: URL) -> Bool {
    let current = directory.standardizedFileURL.resolvingSymlinksInPath()
    let root = root.standardizedFileURL.resolvingSymlinksInPath()
    return current != root && !SharedLibraryMaterializer.contained(current, in: root)
  }
  func matches(library: UUID, writer: UUID) -> Bool { library == libraryID && writer == writerID }
  public func fileURL(for key: String) -> URL {
    directory.appendingPathComponent(libraryID.uuidString)
      .appendingPathComponent(writerID.uuidString)
      .appendingPathComponent(SharedLibraryOperation.fingerprint(Data(key.utf8)) + ".json")
  }
  func checkpointFingerprint() throws -> String {
    let stream = directory.appendingPathComponent(libraryID.uuidString).appendingPathComponent(writerID.uuidString)
    struct Checkpoint: Encodable {
      struct Entry: Encodable { let name: String; let fingerprint: String }
      let library: UUID
      let writer: UUID
      let files: [Entry]
    }
    var entries: [Checkpoint.Entry] = []
    if FileManager.default.fileExists(atPath: stream.path) {
      for file in try FileManager.default.contentsOfDirectory(at: stream, includingPropertiesForKeys: [])
        .filter({ $0.pathExtension == "json" }).sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
        guard SharedLibraryMaterializer.contained(file.resolvingSymlinksInPath(), in: stream) else {
          throw SharedOwnerWitnessError.invalidWitness
        }
        entries.append(.init(name: file.lastPathComponent,
          fingerprint: SharedLibraryOperation.fingerprint(try Data(contentsOf: file))))
      }
    }
    return try SharedStateFingerprint.of(Checkpoint(library: libraryID, writer: writerID, files: entries))
  }

  private struct Record: Codable, Sendable {
    let schema: Int
    let library: UUID
    let writer: UUID
    let key: String
    var accepted: SharedOwnerHeadSummary?
    var pending: Data?
    var pendingParent: SharedOwnerHeadSummary?
  }
  private struct Envelope: Codable {
    let record: Record
    let checksum: String
  }
  public func withWrite<Output: Sendable>(
    at head: URL, key: String,
    decode: @escaping @Sendable (Data) throws -> SharedOwnerHeadSummary,
    afterPublish: @escaping @Sendable () throws -> Void = {},
    observed: SharedOwnerHeadSummary? = nil,
    gate: SharedLibraryLocalGate? = nil,
    bindings: [SharedMaterializationBinding] = [],
    body:
      @escaping @Sendable (CoordinatedFileAccess.Scope, Data?) throws -> SharedOwnerPreparedWrite<
        Output
      >
  ) async throws -> Output {
    guard !key.isEmpty else { throw SharedOwnerWitnessError.invalidWitness }
    try observed.map { if $0.sequence > 0 { try $0.validate() } }
    let file = fileURL(for: key)
    guard !SharedLibraryMaterializer.contained(file, in: head.deletingLastPathComponent()) else {
      throw SharedLibraryOperationError.unsafePath
    }
    try FileManager.default.createDirectory(
      at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
    var local = file.deletingLastPathComponent()
    var excluded = URLResourceValues()
    excluded.isExcludedFromBackup = true
    try local.setResourceValues(excluded)
    let library = libraryID
    let writer = writerID
    let directory = self.directory
    let intendedHead = head.standardizedFileURL.resolvingSymlinksInPath()
    let gateItems = try gate?.items(outside: head.deletingLastPathComponent()) ?? []
    for binding in bindings { _ = try await RecordingFileAccess().waitUntilAvailable(at: binding.file, knownToExist: true) }
    let writes = [.init(head), .init(file)] + gateItems
    return try await access.withWrites(writes, reading: bindings.map(\.file)) { scopes in
      let target = scopes[0]
      let checkpoint = scopes[1]
      for (binding, read) in zip(bindings, scopes.dropFirst(writes.count)) {
        guard read.url.standardizedFileURL.resolvingSymlinksInPath() == binding.file.standardizedFileURL.resolvingSymlinksInPath(),
              try binding.validate(Data(contentsOf: read.url)) else { throw SharedLibraryRepositoryError.staleRevision }
      }
      if let gate { try gate.validate(scopes[2], outside: head.deletingLastPathComponent()) }
      guard target.url.standardizedFileURL.resolvingSymlinksInPath() == intendedHead,
        SharedLibraryMaterializer.contained(checkpoint.url, in: directory)
      else {
        throw SharedLibraryOperationError.unsafePath
      }
      var record = Record(
        schema: 1, library: library, writer: writer, key: key, accepted: nil, pending: nil,
        pendingParent: nil)
      if FileManager.default.fileExists(atPath: checkpoint.url.path) {
        let envelope = try JSONDecoder().decode(
          Envelope.self, from: Data(contentsOf: checkpoint.url))
        guard envelope.record.schema == 1,
          envelope.checksum == (try SharedStateFingerprint.of(envelope.record))
        else {
          throw SharedOwnerWitnessError.invalidWitness
        }
        guard envelope.record.library == library, envelope.record.writer == writer,
          envelope.record.key == key
        else {
          throw SharedOwnerWitnessError.differentBinding
        }
        record = envelope.record
      }
      var current =
        FileManager.default.fileExists(atPath: target.url.path)
        ? try Data(contentsOf: target.url) : nil
      var summary = try current.map(decode)
      try summary?.validate()
      try record.accepted?.validate()
      try record.pendingParent?.validate()
      // Recover a single interrupted publication before allocating any
      // counter. Its durable parent and semantic coverage bind the replay.
      if let pending = record.pending {
        let proposed = try decode(pending)
        try proposed.validate()
        if let accepted = record.accepted {
          guard proposed.sequence > accepted.sequence, try proposed.covers(accepted) else {
            throw SharedOwnerWitnessError.invalidWitness
          }
        }
        if summary == proposed {
          current = pending
        } else {
          guard summary == record.pendingParent else {
            throw SharedOwnerWitnessError.pendingRootChanged
          }
          try target.checkCancellation()
          try pending.write(to: target.url, options: .atomic)
          current = pending
        }
        summary = proposed
        record.accepted = proposed
        record.pending = nil
        record.pendingParent = nil
        try Self.save(record, at: checkpoint.url)
      }
      if let accepted = record.accepted {
        let physicalIsCurrent = summary.map { $0.sequence >= accepted.sequence } ?? false
        if physicalIsCurrent {
          guard let summary, try summary.covers(accepted) else {
            throw SharedOwnerWitnessError.rollback
          }
          if summary.sequence == accepted.sequence, summary.fingerprint != accepted.fingerprint {
            throw SharedOwnerWitnessError.reusedSequence
          }
        } else {
          // A validated peer can restore causal context. Sequence-only
          // claims are insufficient: it must cover every known field
          // or certified retired namespace/membership certificate.
          guard let observed, observed.sequence >= accepted.sequence,
            !accepted.contexts.isEmpty || accepted.membership != nil,
            try observed.covers(accepted)
          else { throw SharedOwnerWitnessError.rollback }
        }
      }
      let prepared = try body(target, current)
      guard let bytes = prepared.bytes else {
        if let summary, summary.sequence > (record.accepted?.sequence ?? 0) {
          record.accepted = summary
          try Self.save(record, at: checkpoint.url)
        }
        return prepared.result
      }
      let proposed = try decode(bytes)
      try proposed.validate()
      guard
        proposed.sequence
          > max(
            summary?.sequence ?? 0, max(record.accepted?.sequence ?? 0, observed?.sequence ?? 0)),
        SharedLibraryOperation.validHash(proposed.fingerprint),
        try record.accepted.map({ try proposed.covers($0) }) ?? true
      else {
        throw SharedOwnerWitnessError.reusedSequence
      }
      for scope in scopes { try scope.checkCancellation() }
      if record.accepted == nil { record.accepted = summary }
      record.pendingParent = summary
      record.pending = bytes
      try Self.save(record, at: checkpoint.url)
      try target.checkCancellation()
      try bytes.write(to: target.url, options: .atomic)
      try afterPublish()
      record.accepted = proposed
      record.pending = nil
      record.pendingParent = nil
      // Return the committed result even if cancellation crossed its
      // publish point; a cancellation cannot claim a nonexistent rollback.
      try Self.save(record, at: checkpoint.url)
      return prepared.result
    }
  }
  private static func save(_ record: Record, at file: URL) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    let bytes = try encoder.encode(
      Envelope(record: record, checksum: SharedStateFingerprint.of(record)))
    try bytes.write(to: file, options: .atomic)
    var url = file
    var values = URLResourceValues()
    values.isExcludedFromBackup = true
    try url.setResourceValues(values)
  }
}
