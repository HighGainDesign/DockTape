// © 2026 High Gain Design. All rights reserved.
import CryptoKit
import Foundation

public struct SharedEntityIdentity: Codable, Hashable, Sendable {
  public let id: UUID
  public let kind: SharedEntityKind
  public init(id: UUID, kind: SharedEntityKind) {
    self.id = id
    self.kind = kind
  }
}

public enum SharedLibraryRepositoryError: Error, Equatable, Sendable {
  case unsupportedSchema(Int)
  case invalidEnvelope
  case unavailableRoot
  case invalidPath
  case differentBinding
  case staleRevision
  case sequenceExhausted
}

public enum SharedLibraryMutation: Sendable {
  case assign(field: String, value: SharedFieldValue)
  case generation(SharedDocument, component: SharedComponent)
  case generationEdit(
    component: SharedComponent, generation: UUID, key: String, value: SharedFieldValue)
  case delete
  case restore
}

public struct SharedLibrarySnapshot: Sendable {
  public let state: SharedEntityState
  public let ownerSequence: UInt64
  public let fingerprint: String
  public let projection: SharedProjectionCertificate?
  public let projectionVotes: [UUID: SharedProjectionVote]
  public let observedMembership: SharedLibraryMembership?
  fileprivate let binding: String
  fileprivate let writer: UUID
  fileprivate let observed: [UUID: UInt64]
  public var writers: Set<UUID> { Set(observed.keys) }
}

public struct SharedLibraryEdit: Sendable {
  public let base: SharedLibrarySnapshot
  public let changes: [SharedLibraryMutation]
  public init(base: SharedLibrarySnapshot, changes: [SharedLibraryMutation]) {
    self.base = base
    self.changes = changes
  }
}

/// Current writer-owned files hold merged state. Empty-change commits persist
/// observations without creating an alive write, allowing safe stale replay and
/// validated current checkpoint metadata. The coordinator owns enrollment,
/// refresh and user decisions; this layer validates and persists their records.
public actor SharedLibraryRepository {
  public nonisolated let root: URL
  public nonisolated let writerID: UUID
  private let access = CoordinatedFileAccess()
  private let binding: String
  private var witness: SharedOwnerWitness?
  private var trustedFoundation: SharedLibraryMembership?

  public init(
    root: URL, writerID: UUID, manifest: SharedBootstrapManifest? = nil,
    witness: SharedOwnerWitness? = nil
  ) {
    self.root = root.standardizedFileURL.resolvingSymlinksInPath()
    self.writerID = writerID
    self.witness = witness
    binding = Self.hash(Data(self.root.path.utf8))
    trustedFoundation = manifest.map {
      .init(libraryID: $0.libraryID, founder: $0.founder, bootstrapFingerprint: $0.fingerprint)
    }
  }

  func configure(manifest: SharedBootstrapManifest, witness: SharedOwnerWitness? = nil) throws {
    let incoming = SharedLibraryMembership(
      libraryID: manifest.libraryID, founder: manifest.founder,
      bootstrapFingerprint: manifest.fingerprint)
    if let existing = trustedFoundation { _ = try existing.merged(with: incoming) }
    trustedFoundation = incoming
    if let witness {
      guard witness.isOutside(root), witness.matches(library: manifest.libraryID, writer: writerID)
      else {
        throw SharedLibraryRepositoryError.differentBinding
      }
      self.witness = witness
    }
  }

  nonisolated func accepts(_ snapshot: SharedLibrarySnapshot) -> Bool {
    snapshot.binding == binding && snapshot.writer == writerID
  }

  public func load(entity: SharedEntityIdentity) async throws -> SharedLibrarySnapshot {
    if let witness, !witness.isOutside(root) { throw SharedLibraryRepositoryError.invalidPath }
    let root = self.root
    let writer = writerID
    let access = self.access
    let binding = self.binding
    let foundation = trustedFoundation
    let directory = Self.directory(entity, root: root)
    try Self.validate(directory, root: root)
    let files = try await Task.detached {
      try Self.validateRoot(root)
      return try Self.headFiles(directory)
    }.value
    let heads = try await withThrowingTaskGroup(of: Envelope.self, returning: [Envelope].self) {
      group in
      for file in files {
        try Self.validate(file.url, root: root)
        group.addTask {
          let bytes = try await access.read(at: file.url)
          return try Self.decode(
            bytes, entity: entity, expectedWriter: file.writer, foundation: foundation)
        }
      }
      var result: [Envelope] = []
      for try await head in group { result.append(head) }
      return result
    }
    var observed: [UUID: UInt64] = [:]
    for head in heads {
      for (source, sequence) in head.watermarks {
        observed[source] = max(observed[source] ?? 0, sequence)
      }
    }
    var projection: SharedProjectionCertificate?
    var membership: SharedLibraryMembership?
    for head in heads {
      projection = try Self.joinedProjection(projection, head.projection)
      if let proof = head.projection?.membership {
        membership = try membership.map { try $0.merged(with: proof) } ?? proof
      }
    }
    var state = projection?.state ?? SharedEntityState(id: entity.id, kind: entity.kind)
    var seen: [UUID: Envelope] = [:]
    var votes: [UUID: SharedProjectionVote] = [:]
    for head in heads where head.sequence == observed[head.writerID] {
      if let earlier = seen[head.writerID],
        try Self.hash(Self.encode(earlier.payload)) != Self.hash(Self.encode(head.payload))
      {
        throw SharedLibraryRepositoryError.invalidEnvelope
      }
      seen[head.writerID] = head
      state = try state.merged(with: head.state)
      if let vote = head.projectionVote { votes[head.writerID] = vote }
    }
    if let witness {
      let destination = directory.appendingPathComponent(writer.uuidString.lowercased() + ".json")
      let key = Self.witnessKey(entity)
      if FileManager.default.fileExists(atPath: destination.path)
        || FileManager.default.fileExists(atPath: witness.fileURL(for: key).path)
      {
        let proof = Self.witnessSummary(
          state: state, sequence: observed[writer] ?? 0,
          fingerprint: try Self.hash(Self.encode(state)), membership: membership)
        let recovered: Envelope? = try await witness.withWrite(
          at: destination, key: key,
          decode: {
            Self.witnessSummary(
              try Self.decode($0, entity: entity, expectedWriter: writer, foundation: foundation))
          }, observed: proof
        ) { _, bytes in
          .init(
            bytes: nil,
            result: try bytes.map {
              try Self.decode($0, entity: entity, expectedWriter: writer, foundation: foundation)
            })
        }
        if let recovered {
          for (source, sequence) in recovered.watermarks {
            observed[source] = max(observed[source] ?? 0, sequence)
          }
          state = try state.merged(with: recovered.state)
          projection = try Self.joinedProjection(projection, recovered.projection)
          if recovered.sequence == observed[writer], let vote = recovered.projectionVote {
            votes[writer] = vote
          }
          if let proof = recovered.projection?.membership {
            membership = try membership.map { try $0.merged(with: proof) } ?? proof
          }
        }
      }
    }
    return try Self.snapshot(
      state, ownerSequence: observed[writer] ?? 0,
      observed: observed, binding: binding, writer: writer, projection: projection, votes: votes,
      membership: membership)
  }

  public func commit(_ edit: SharedLibraryEdit) async throws -> SharedLibrarySnapshot {
    try await transact(edit, operation: .edit)
  }

  public func acknowledgeProjection(
    _ proposal: SharedProjectionProposal, base: SharedLibrarySnapshot
  ) async throws
    -> SharedLibrarySnapshot
  {
    guard proposal.state.id == base.state.id, proposal.state.kind == base.state.kind,
      proposal.membership.cohort.contains(writerID)
    else { throw SharedLibraryRepositoryError.differentBinding }
    return try await transact(.init(base: base, changes: []), operation: .vote(proposal))
  }
  public func publishProjection(
    _ certificate: SharedProjectionCertificate, base: SharedLibrarySnapshot,
    membership: SharedLibraryMembership
  ) async throws -> SharedLibrarySnapshot {
    guard certificate.state.id == base.state.id, certificate.state.kind == base.state.kind else {
      throw SharedLibraryRepositoryError.differentBinding
    }
    guard membership.pendingWriters.isEmpty, !membership.hasConcurrentEnrollment,
      membership.fingerprint == certificate.membership.fingerprint
    else { throw SharedProjectionError.notReady }
    return try await transact(.init(base: base, changes: []), operation: .publish(certificate))
  }
  private enum Transaction: Sendable {
    case edit
    case vote(SharedProjectionProposal)
    case publish(SharedProjectionCertificate)
  }
  private func transact(_ edit: SharedLibraryEdit, operation: Transaction) async throws
    -> SharedLibrarySnapshot
  {
    if let witness, !witness.isOutside(root) { throw SharedLibraryRepositoryError.invalidPath }
    guard edit.base.binding == binding, edit.base.writer == writerID else {
      throw SharedLibraryRepositoryError.differentBinding
    }
    let entity = SharedEntityIdentity(id: edit.base.state.id, kind: edit.base.state.kind)
    let root = self.root
    let writer = writerID
    let binding = self.binding
    let foundation = trustedFoundation
    let destination = Self.directory(entity, root: root).appendingPathComponent(
      writer.uuidString.lowercased() + ".json")
    try Self.validate(destination, root: root)
    try await Task.detached {
      try Self.prepareDirectory(entity, root: root)
    }.value
    let execute:
      @Sendable (CoordinatedFileAccess.Scope, Data?) throws -> SharedOwnerPreparedWrite<
        SharedLibrarySnapshot
      > = { scope, data in
        try Self.validateRoot(root)
        try Self.validate(scope.url, root: root)
        try scope.checkCancellation()
        let existing: Envelope?
        existing = try data.map {
          try Self.decode($0, entity: entity, expectedWriter: writer, foundation: foundation)
        }
        try scope.checkCancellation()
        var observed = edit.base.observed
        if let existing {
          for (source, sequence) in existing.watermarks {
            observed[source] = max(observed[source] ?? 0, sequence)
          }
        }
        var current = edit.base.state
        if let existing, existing.sequence == observed[writer] {
          current = try current.merged(with: existing.state)
        }
        var projection = try Self.joinedProjection(edit.base.projection, existing?.projection)
        var membership = edit.base.observedMembership
        if let proof = projection?.membership {
          membership = try membership.map { try $0.merged(with: proof) } ?? proof
        }
        var votes = edit.base.projectionVotes
        var vote = existing?.projectionVote
        switch operation {
        case .edit:
          try Self.validateBase(edit, against: current)
          for mutation in edit.changes { try Self.apply(mutation, to: &current, writer: writer) }
        case .vote(let proposal):
          guard let foundation else { throw SharedLibraryRepositoryError.invalidEnvelope }
          _ = try foundation.merged(with: proposal.membership)
          let actual = try SharedProjectionProposal(state: current, membership: proposal.membership)
          guard actual.revision == proposal.revision else {
            throw SharedLibraryRepositoryError.staleRevision
          }
          vote = .init(writer: writer, revision: proposal.revision, cohort: proposal.cohort)
        case .publish(let certificate):
          guard let foundation else { throw SharedLibraryRepositoryError.invalidEnvelope }
          try certificate.validate(binding: foundation)
          projection = try Self.joinedProjection(projection, certificate)
          current = try current.merged(with: projection!.state)
          membership =
            try membership.map { try $0.merged(with: certificate.membership) }
            ?? certificate.membership
        }
        if let accepted = vote {
          let candidate = try? current.compacting(SharedGenerationCompaction.proposed(for: current))
          let revision = try candidate.map { try Self.hash(Self.encode($0)) }
          if revision != accepted.revision { vote = nil }
        }
        if let vote { votes[writer] = vote } else { votes.removeValue(forKey: writer) }
        // Merely seeing a peer's observation of this same semantic state
        // must not generate another observation for it to acknowledge.
        // Persist new semantic context, not a watermark-only echo loop.
        if let existing, existing.sequence == observed[writer], current == existing.state,
          projection == existing.projection,
          vote == existing.projectionVote
        {
          return .init(
            bytes: nil,
            result: try Self.snapshot(
              current, ownerSequence: existing.sequence, observed: observed, binding: binding,
              writer: writer,
              projection: projection, votes: votes, membership: membership))
        }
        if existing == nil && current.lifecycle == .uninitialized {
          return .init(
            bytes: nil,
            result: try Self.snapshot(
              current, ownerSequence: 0, observed: observed, binding: binding, writer: writer,
              projection: projection, votes: votes, membership: membership))
        }
        let (sequence, overflow) = (observed[writer] ?? 0).addingReportingOverflow(1)
        guard !overflow else { throw SharedLibraryRepositoryError.sequenceExhausted }
        observed[writer] = sequence
        let envelope = try Envelope(
          writerID: writer, sequence: sequence, state: current, watermarks: observed,
          projectionVote: vote,
          projection: projection)
        let bytes = try Self.encode(envelope)
        try scope.checkCancellation()
        return .init(
          bytes: bytes,
          result: try Self.snapshot(
            current, ownerSequence: sequence, observed: observed, binding: binding, writer: writer,
            projection: projection, votes: votes, membership: membership))
      }
    if let witness {
      let proof = Self.witnessSummary(
        state: edit.base.state, sequence: edit.base.ownerSequence,
        fingerprint: edit.base.fingerprint, membership: edit.base.observedMembership)
      return try await witness.withWrite(
        at: destination, key: Self.witnessKey(entity),
        decode: {
          Self.witnessSummary(
            try Self.decode($0, entity: entity, expectedWriter: writer, foundation: foundation))
        }, observed: proof, body: execute)
    }
    return try await access.withWrite(at: destination) { scope in
      let data =
        FileManager.default.fileExists(atPath: scope.url.path)
        ? try Data(contentsOf: scope.url) : nil
      let prepared = try execute(scope, data)
      if let bytes = prepared.bytes {
        try scope.checkCancellation()
        try bytes.write(to: scope.url, options: .atomic)
      }
      return prepared.result
    }
  }

  public func scan() async throws -> [SharedEntityIdentity] {
    let root = self.root
    return try await Task.detached {
      try Self.validateRoot(root)
      var result: [SharedEntityIdentity] = []
      for kind in [SharedEntityKind.recording, .folder, .template] {
        let parent = Self.parent(kind, root: root)
        try Self.validate(parent, root: root)
        for url in try Self.contents(parent) {
          guard let id = UUID(uuidString: url.lastPathComponent) else { continue }
          try Self.validate(url, root: root)
          if !(try Self.headFiles(url)).isEmpty { result.append(.init(id: id, kind: kind)) }
        }
      }
      return result.sorted {
        ($0.kind.rawValue, $0.id.uuidString) < ($1.kind.rawValue, $1.id.uuidString)
      }
    }.value
  }

  /// Verify a bootstrap's referenced owner head before enrolling a writer.
  /// Later heads may supersede its seed, but retain the immutable initial claim.
  public func containsBootstrapReference(
    entity: SharedEntityIdentity, writer: UUID,
    sequence: UInt64, fingerprint: String, initialPath: String
  ) async throws -> Bool {
    let destination = Self.directory(entity, root: root).appendingPathComponent(
      writer.uuidString.lowercased() + ".json")
    try Self.validateRoot(root)
    try Self.validate(destination, root: root)
    let files = try await Task.detached {
      try Self.headFiles(destination.deletingLastPathComponent())
    }.value
    guard files.contains(where: { $0.url == destination }) else { return false }
    let envelope = try Self.decode(
      await access.read(at: destination), entity: entity, expectedWriter: writer,
      foundation: trustedFoundation)
    guard envelope.sequence >= sequence,
      envelope.state.value(for: "initialPath") == .text(initialPath)
    else {
      return false
    }
    if envelope.sequence > sequence { return true }
    return try Self.hash(Self.encode(envelope.state)) == fingerprint
  }

  private static func witnessKey(_ entity: SharedEntityIdentity) -> String {
    entity.kind.rawValue + "." + entity.id.uuidString
  }
  private static func witnessSummary(_ envelope: Envelope) -> SharedOwnerHeadSummary {
    witnessSummary(
      state: envelope.state, sequence: envelope.sequence, fingerprint: envelope.checksum,
      membership: envelope.projection?.membership)
  }
  private static func witnessSummary(
    state: SharedEntityState, sequence: UInt64, fingerprint: String,
    membership: SharedLibraryMembership?
  ) -> SharedOwnerHeadSummary {
    .init(
      sequence: sequence, fingerprint: fingerprint,
      contexts: state.fields.mapValues(\.causalContext),
      retired: state.compaction?.context ?? [], membership: membership,
      activeGenerations: Set(
        [SharedComponent.transcript, .summary].flatMap { state.generationValues(for: $0).map(\.id) }
      ))
  }

  private static func validateBase(_ edit: SharedLibraryEdit, against current: SharedEntityState)
    throws
  {
    for mutation in edit.changes {
      let fields: Set<String>
      switch mutation {
      case .assign(let field, _): fields = [field]
      case .generation(_, let component):
        fields = Set(edit.base.state.fields.keys.filter { $0.hasPrefix(component.rawValue + ".") })
          .union(current.fields.keys.filter { $0.hasPrefix(component.rawValue + ".") })
          .union([component.rawValue + ".content"])
      case .generationEdit(let component, let generation, let key, _):
        fields = [
          component.rawValue + ".content",
          "\(component.rawValue).edits.\(generation.uuidString.lowercased()).\(key)",
        ]
      case .delete, .restore:
        guard edit.base.state == current else { throw SharedLibraryRepositoryError.staleRevision }
        continue
      }
      for field in fields
      where (edit.base.state.fields[field]?.values ?? []) != (current.fields[field]?.values ?? []) {
        throw SharedLibraryRepositoryError.staleRevision
      }
    }
  }

  private static func apply(
    _ mutation: SharedLibraryMutation, to state: inout SharedEntityState, writer: UUID
  ) throws {
    switch mutation {
    case .assign(let field, let value): try state.assign(field: field, value: value, writer: writer)
    case .generation(let document, let component):
      try state.assignGeneration(document, component: component, writer: writer)
    case .generationEdit(let component, let generation, let key, let value):
      try state.assignGenerationEdit(
        component: component, generation: generation, key: key, value: value, writer: writer)
    case .delete: try state.delete(writer: writer)
    case .restore: try state.restore(writer: writer)
    }
  }

  private struct Probe: Decodable { let schemaVersion: Int }
  private struct Payload: Codable {
    let schemaVersion: Int
    let writerID: UUID
    let sequence: UInt64
    let state: SharedEntityState
    let observed: [CausalDot]
    let projectionVote: SharedProjectionVote?
    let projection: SharedProjectionCertificate?
  }
  private struct Envelope: Codable, Sendable {
    let schemaVersion: Int
    let writerID: UUID
    let sequence: UInt64
    let state: SharedEntityState
    let observed: [CausalDot]
    let projectionVote: SharedProjectionVote?
    let projection: SharedProjectionCertificate?
    let checksum: String
    var watermarks: [UUID: UInt64] {
      Dictionary(uniqueKeysWithValues: observed.map { ($0.writer, $0.counter) })
    }
    var payload: Payload {
      .init(
        schemaVersion: schemaVersion, writerID: writerID, sequence: sequence, state: state,
        observed: observed,
        projectionVote: projectionVote, projection: projection)
    }

    init(
      writerID: UUID, sequence: UInt64, state: SharedEntityState, watermarks: [UUID: UInt64],
      projectionVote: SharedProjectionVote? = nil, projection: SharedProjectionCertificate? = nil
    ) throws {
      schemaVersion = 1
      self.writerID = writerID
      self.sequence = sequence
      self.state = state
      self.projectionVote = projectionVote
      self.projection = projection
      observed = watermarks.map { CausalDot(writer: $0.key, counter: $0.value) }.sorted {
        $0.writer.uuidString < $1.writer.uuidString
      }
      checksum = try SharedLibraryRepository.hash(
        SharedLibraryRepository.encode(
          Payload(
            schemaVersion: 1,
            writerID: writerID, sequence: sequence, state: state, observed: observed,
            projectionVote: projectionVote, projection: projection)))
    }
  }

  private static func decode(
    _ bytes: Data, entity: SharedEntityIdentity, expectedWriter: UUID?,
    foundation: SharedLibraryMembership? = nil
  ) throws -> Envelope {
    let decoder = JSONDecoder()
    let version = try decoder.decode(Probe.self, from: bytes).schemaVersion
    guard version == 1 else { throw SharedLibraryRepositoryError.unsupportedSchema(version) }
    let head = try decoder.decode(Envelope.self, from: bytes)
    guard head.sequence > 0, head.state.lifecycle != .uninitialized,
      head.state.compaction == head.projection?.state.compaction,
      head.state.id == entity.id, head.state.kind == entity.kind,
      expectedWriter == nil || head.writerID == expectedWriter,
      Set(head.observed.map(\.writer)).count == head.observed.count,
      head.observed.allSatisfy({ $0.counter > 0 }),
      head.observed.first(where: { $0.writer == head.writerID })?.counter == head.sequence,
      try hash(encode(head.payload)) == head.checksum
    else { throw SharedLibraryRepositoryError.invalidEnvelope }
    if let projection = head.projection {
      guard let foundation, projection.state.id == entity.id, projection.state.kind == entity.kind
      else {
        throw SharedLibraryRepositoryError.invalidEnvelope
      }
      try projection.validate(binding: foundation)
    }
    if let vote = head.projectionVote {
      guard vote.writer == head.writerID, vote.revision.count == 64, vote.cohort.count == 64 else {
        throw SharedLibraryRepositoryError.invalidEnvelope
      }
    }
    return head
  }

  private static func joinedProjection(
    _ lhs: SharedProjectionCertificate?, _ rhs: SharedProjectionCertificate?
  )
    throws -> SharedProjectionCertificate?
  {
    guard let lhs else { return rhs }
    guard let rhs else { return lhs }
    let context = try lhs.state.compaction!.joined(with: rhs.state.compaction!)
    if lhs.state.compaction != rhs.state.compaction {
      return context == rhs.state.compaction ? rhs : lhs
    }
    guard lhs.state == rhs.state else { throw SharedProjectionError.invalidCertificate }
    if rhs.membership.cohort.isStrictSuperset(of: lhs.membership.cohort) { return rhs }
    if lhs.membership.cohort.isStrictSuperset(of: rhs.membership.cohort) { return lhs }
    // Equivalent payloads use deterministic proof bytes; all historical
    // cohort proofs are separately retained in observedMembership.
    return lhs.fingerprint < rhs.fingerprint ? lhs : rhs
  }

  private static func snapshot(
    _ state: SharedEntityState, ownerSequence: UInt64, observed: [UUID: UInt64],
    binding: String, writer: UUID, projection: SharedProjectionCertificate? = nil,
    votes: [UUID: SharedProjectionVote] = [:], membership: SharedLibraryMembership? = nil
  ) throws -> SharedLibrarySnapshot {
    .init(
      state: state, ownerSequence: ownerSequence, fingerprint: try hash(encode(state)),
      projection: projection,
      projectionVotes: votes, observedMembership: membership,
      binding: binding, writer: writer, observed: observed)
  }

  private static func encode<T: Encodable>(_ value: T) throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    return try encoder.encode(value)
  }
  private static func hash(_ bytes: Data) -> String {
    SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
  }

  private static func parent(_ kind: SharedEntityKind, root: URL) -> URL {
    let name: String
    switch kind {
    case .recording: name = "records"
    case .folder: name = "folders"
    case .template: name = "templates"
    }
    return root.appendingPathComponent(".docktape").appendingPathComponent(name)
  }
  private static func directory(_ entity: SharedEntityIdentity, root: URL) -> URL {
    parent(entity.kind, root: root).appendingPathComponent(entity.id.uuidString.lowercased())
  }
  private static func validateRoot(_ root: URL) throws {
    guard root.isFileURL else { throw SharedLibraryRepositoryError.invalidPath }
    // URL resource values cache prior existence. Query the filesystem afresh
    // so a disconnected/deleted provider root cannot look resident.
    guard
      (try? FileManager.default.attributesOfItem(atPath: root.path)[.type]) as? FileAttributeType
        == .typeDirectory
    else {
      throw SharedLibraryRepositoryError.unavailableRoot
    }
  }

  private static func prepareDirectory(_ entity: SharedEntityIdentity, root: URL) throws {
    try validateRoot(root)
    var current = root
    for name in [
      ".docktape", parent(entity.kind, root: root).lastPathComponent,
      entity.id.uuidString.lowercased(),
    ] {
      current.appendPathComponent(name)
      try validate(current, root: root)
      if (try? current.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true { continue }
      do {
        try FileManager.default.createDirectory(at: current, withIntermediateDirectories: false)
      } catch {
        // A simultaneous creator may have made this same directory;
        // never repair a missing library root by recreating its parents.
        guard (try? current.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else {
          throw error
        }
      }
      try validate(current, root: root)
    }
  }

  private static func validate(_ url: URL, root: URL) throws {
    let prefix = root.path.hasSuffix("/") ? root.path : root.path + "/"
    guard url.standardizedFileURL.resolvingSymlinksInPath().path.hasPrefix(prefix) else {
      throw SharedLibraryRepositoryError.invalidPath
    }
  }
  private static func contents(_ directory: URL) throws -> [URL] {
    do {
      return try FileManager.default.contentsOfDirectory(
        at: directory, includingPropertiesForKeys: nil)
    } catch {
      let ns = error as NSError
      if (ns.domain == NSCocoaErrorDomain && ns.code == NSFileReadNoSuchFileError)
        || (ns.domain == NSPOSIXErrorDomain && ns.code == Int(ENOENT))
      {
        return []
      }
      throw error
    }
  }
  private static func headFiles(_ directory: URL) throws -> [(url: URL, writer: UUID?)] {
    try contents(directory).compactMap { source in
      let name = source.lastPathComponent
      let logical =
        name.hasPrefix(".") && name.hasSuffix(".icloud")
        ? String(name.dropFirst().dropLast(7)) : name
      guard logical.hasSuffix(".json"), !logical.hasPrefix(".") else { return nil }
      return (
        directory.appendingPathComponent(logical), UUID(uuidString: String(logical.dropLast(5)))
      )
    }
  }
}
