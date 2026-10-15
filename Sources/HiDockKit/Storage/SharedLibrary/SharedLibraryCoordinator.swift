// © 2026 High Gain Design. All rights reserved.
import Foundation
import Darwin

public enum SharedLibraryCoordinatorError: Error, Equatable, Sendable {
  case notEnabled, bootstrapPending, enrollmentPending, differentBinding, staleReview, staleJob,
    unrecognizedWriter,
    externalChanged
}
public struct SharedLibraryViewSnapshot: Sendable {
  public let libraryID: UUID
  let repository: SharedLibrarySnapshot
  public var state: SharedEntityState { repository.state }
  public var fingerprint: String { repository.fingerprint }
  public var confirmedState: SharedEntityState? { repository.projection?.state }
}
public struct SharedRecordingReference: Hashable, Codable, Sendable {
  public let libraryID: UUID
  public let entityID: UUID
}
public struct SharedCoordinatorEdit: Sendable {
  public let base: SharedLibraryViewSnapshot
  public let changes: [SharedLibraryMutation]
  public init(base: SharedLibraryViewSnapshot, changes: [SharedLibraryMutation]) {
    self.base = base
    self.changes = changes
  }
}
public struct SharedLibraryJobToken: Sendable {
  let id: UUID
  let library: UUID
  let entity: SharedEntityIdentity
  let lifecycle: String
  let component: SharedComponent?
  let input: String
  let output: SharedComponent?
  let snapshot: SharedLibraryViewSnapshot
  let inputFile: SharedMaterializationBinding?
  public let recordingMode: String
  let lease = SharedMaterializationLease()
}
/// A UI decision bound to the exact entity, physical plan and membership
/// reviewed. Its opaque snapshot is never refreshed into new consent.
public struct SharedRecordingOperationReview: Identifiable, Sendable {
  public var id: UUID { base.state.id }
  public let title: String
  public let paths: [String]
  public let completedSteps: Int
  public let totalSteps: Int
  public let needsReplanning: Bool
  public let hasActiveWork: Bool
  public let waitingForMacs: [String]
  public let canResume: Bool
  public let canAcknowledge: Bool
  public var canReplan: Bool {
    needsReplanning && !hasActiveWork && base.state.conflicts.isEmpty && (
      (isLocal && base.state.lifecycle == .alive && operation.steps.allSatisfy { if case .move = $0 { return true }; return false }) ||
      (base.state.lifecycle == .deleted && operation.steps.allSatisfy { if case .trash = $0 { return true }; return false }))
  }
  let base: SharedLibraryViewSnapshot
  let operation: SharedLibraryOperation
  let cohort: String
  let isLocal: Bool
  public let purpose: SharedDestructivePurpose?
}

public struct SharedRecordingReplanReview: Identifiable, Sendable {
  public var id: UUID { original.id }
  public let destination: String
  public let sources: [String]
  public var isDeletion: Bool { original.purpose == .delete }
  let original: SharedRecordingOperationReview
  let steps: [SharedLibraryOperation.Step]
  let witnesses: [SharedFilePathWitness]
  let retainedFiles: [String: String]
  let reviewedExistingDestinations: [String]
}
struct SharedFilePathWitness: Sendable {
  let path: String
  let fingerprint: String?
}

public struct SharedExternalContent: Equatable, Sendable {
  public let libraryID: UUID
  public let versionID: String?
  public let id: UUID
  public let entity: SharedEntityIdentity
  public let component: SharedComponent
  public let url: URL
  public let fingerprint: String
  public let document: SharedDocument
}
/// Opaque consent for one actual sidecar and the exact state shown beside it.
/// Damaged/foreign JSON may be replaced with reviewed current content, never adopted.
public struct SharedSidecarReview: Identifiable, Sendable {
  public var id: String { entity.id.uuidString + component.rawValue + fingerprint }
  public let filename: String
  public let component: SharedComponent
  public let currentText: String
  public let changedText: String?
  let entity: SharedEntityIdentity
  let snapshot: SharedLibraryViewSnapshot
  let url: URL
  let fingerprint: String
  let current: SharedDocument
  let changed: SharedDocument?
}
/// Exact, short-lived consent to restore a bootstrap aggregate whose first
/// publication may have been interrupted. No external metadata is adopted.
public struct SharedBootstrapProjectionReview: Identifiable, Sendable {
  public let id: String
  public let filename: String
  public let currentText: String
  public let changedText: String
  let root: URL
  let libraryID: UUID
  let fingerprint: String
  let outputFingerprint: String
}
public enum SharedLibraryChange: Sendable {
  case loading(UUID, SharedEntityIdentity)
  case entity(UUID, SharedEntityIdentity, String)
  case files(UUID)
  case failure(String)
}

/// Identity/revision-bound reads and semantic mutations. Reads don't wait for
/// unrelated entity hydration or writer enrollment. Edits require admitted
/// membership; refresh publishes observations, never an alive lifecycle write.
public actor SharedLibraryCoordinator {
  public nonisolated let root: URL
  public nonisolated let writerID: UUID
  private var bootstrapReviewTickets: Set<String> = []
  private let bootstrap: LegacyLibraryBootstrap
  private let versionAccess: RecordingFileVersionAccess
  private let repository: SharedLibraryRepository
  private let witnessDirectory: URL?
  private let afterCommit: @Sendable () async -> Void
  private let afterPublishedLibraryRead: @Sendable () async throws -> Void
  private let trash: @Sendable (URL) throws -> Void
  private var manifest: SharedBootstrapManifest?
  private var members: SharedMemberRepository?
  private var gate: SharedLibraryLocalGate?
  private var cache: [SharedEntityIdentity: SharedLibraryViewSnapshot] = [:]
  private var requests: [SharedEntityIdentity: UInt64] = [:]
  private var authorityEpoch: UInt64 = 0
  private var transitions = 0
  private var authorityRevision: String?
  private var authorityLease: SharedMaterializationLease?
  private var leasedRevisions: [SharedEntityIdentity: String] = [:]
  private var jobs: [UUID: SharedLibraryJobToken] = [:]
  private var jobLeases: [UUID: SharedLocalJobLease] = [:]
  private func revokeAuthority() {
    authorityLease?.revoke()
    authorityLease = nil
    authorityRevision = nil
    leasedRevisions.removeAll()
    authorityEpoch &+= 1
  }
  private func beginTransition() { revokeAuthority(); transitions += 1 }
  private func endTransition() { transitions -= 1 }

  private var monitor: SharedLibraryChangeMonitor?
  private var monitorRefresh: Task<Void, Never>?
  private var listeners: [UUID: AsyncStream<SharedLibraryChange>.Continuation] = [:]
  public init(
    root: URL, writerID: UUID, versionAccess: RecordingFileVersionAccess = .init(),
    witnessDirectory: URL? = nil, afterCommit: @escaping @Sendable () async -> Void = {},
    afterPublishedLibraryRead: @escaping @Sendable () async throws -> Void = {},
    trash: @escaping @Sendable (URL) throws -> Void = { try SharedLibraryMaterializer.moveToTrash($0) }
  ) {
    self.root = root.standardizedFileURL.resolvingSymlinksInPath()
    self.writerID = writerID
    self.versionAccess = versionAccess
    self.witnessDirectory = witnessDirectory
    self.afterCommit = afterCommit
    self.afterPublishedLibraryRead = afterPublishedLibraryRead
    self.trash = trash
    bootstrap = LegacyLibraryBootstrap(
      root: root, writerID: writerID, witnessDirectory: witnessDirectory)
    repository = SharedLibraryRepository(root: root, writerID: writerID)
  }
  public func enable() async throws -> SharedBootstrapManifest {
    let manifest = try await bootstrap.enable()
    try await install(manifest)
    let members = try memberRepository()
    let initial = try await members.load()
    _ = try await members.commit(base: initial, membership: initial.membership)
    return manifest
  }
  private func install(_ manifest: SharedBootstrapManifest) async throws {
    if let previous = self.manifest,
      previous.libraryID != manifest.libraryID || previous.fingerprint != manifest.fingerprint
    {
      cache.removeAll()
      throw SharedLibraryCoordinatorError.differentBinding
    }
    let witness = witnessDirectory.map {
      SharedOwnerWitness(directory: $0, libraryID: manifest.libraryID, writerID: writerID)
    }
    if gate == nil, let directory = witnessDirectory {
      let local = SharedLibraryLocalGate(file: directory.appendingPathComponent("Gates")
        .appendingPathComponent(manifest.libraryID.uuidString).appendingPathComponent(writerID.uuidString + ".lock"))
      try await local.prepare(outside: root)
      gate = local
    }
    try await repository.configure(manifest: manifest, witness: witness, gate: gate)
    self.manifest = manifest
    if members == nil {
      members = SharedMemberRepository(
        root: root, writer: writerID, manifest: manifest, witness: witness, gate: gate)
    }
  }
  private func bind(force: Bool = false) async throws -> SharedBootstrapManifest {
    if !force, let manifest { return manifest }
    let header = try await bootstrap.publishedManifest()
    switch header {
    case .notEnabled: throw SharedLibraryCoordinatorError.notEnabled
    case .ready(let manifest), .pending(let manifest):
      try await install(manifest)
      return manifest
    }
  }
  private func memberRepository() throws -> SharedMemberRepository {
    guard let members else { throw SharedLibraryCoordinatorError.notEnabled }
    return members
  }
  public func mayEdit() async throws -> Bool {
    _ = try await bind(force: true)
    guard case .ready = try await bootstrap.publishedManifest() else { return false }
    let members = try memberRepository()
    let snapshot = try await members.load()
    guard snapshot.membership.mayEdit(writerID) else { return false }
    _ = try await members.commit(base: snapshot, membership: snapshot.membership)
    return true
  }
  /// Display metadata only. This does not grant edit or cleanup permission.
  public func writerLabels(libraryID: UUID) async throws -> [UUID: String] {
    let manifest = try await bind(force: true)
    guard manifest.libraryID == libraryID else { throw SharedLibraryCoordinatorError.differentBinding }
    let membership = try await memberRepository().load().membership
    guard membership.libraryID == libraryID else { throw SharedLibraryCoordinatorError.differentBinding }
    let names = Dictionary(uniqueKeysWithValues: membership.cohort.map { writer in
      let label = writer == writerID ? "This Mac" : membership.label(for: writer).trimmingCharacters(in: .whitespacesAndNewlines)
      return (writer, label.isEmpty ? "Another Mac" : label)
    })
    return names.reduce(into: [UUID: String]()) { labels, entry in
      let (writer, label) = entry
      let peers = names.keys.filter { $0 != writer && names[$0] == label }
      guard !peers.isEmpty else { labels[writer] = label; return }
      let id = writer.uuidString.lowercased()
      var length = 8
      while length < id.count && peers.contains(where: { $0.uuidString.lowercased().prefix(length) == id.prefix(length) }) { length += 4 }
      labels[writer] = label + " · " + id.prefix(length)
    }
  }
  public func requestEnrollment(requestID: UUID, label: String) async throws {
    beginTransition(); defer { endTransition() }
    let manifest = try await bind(force: true)
    guard manifest.complete else { throw SharedLibraryCoordinatorError.bootstrapPending }
    let members = try memberRepository()
    let base = try await members.load()
    var membership = base.membership
    if !membership.mayEdit(writerID) {
      try membership.requestJoin(.init(writer: writerID, requestID: requestID, label: label))
    }
    _ = try await members.commit(base: base, membership: membership)
    try await refresh()
  }

  public func startMonitoring() async throws {
    _ = try await bind(force: true)
    await stopMonitoring()
    monitor = SharedLibraryChangeMonitor(root: root) { [weak self] in await self?.scheduleRefresh()
    }
  }
  public func stopMonitoring() async {
    let existing = monitor
    monitor = nil
    await existing?.close()
    let task = monitorRefresh
    monitorRefresh = nil
    task?.cancel()
    await task?.value
  }
  private func scheduleRefresh() {
    guard monitor != nil else { return }
    monitorRefresh?.cancel()
    monitorRefresh = Task { [weak self] in
      guard let self else { return }
      do {
        try await self.refresh()
        try Task.checkCancellation()
        let manifest = try await self.bind()
        await self.reportFileChange(library: manifest.libraryID)
      } catch {
        guard !Task.isCancelled else { return }
        await self.reportRefreshError(error.localizedDescription)
      }
    }
  }
  private func reportFileChange(library: UUID) {
    guard monitor != nil, !Task.isCancelled else { return }
    // Canonical sidecar/provider changes may leave every authoritative entity
    // unchanged. Consumers still need to inspect/review those actual files.
    for listener in listeners.values { listener.yield(.files(library)) }
  }
  private func reportRefreshError(_ message: String) {
    guard monitor != nil else { return }
    for listener in listeners.values { listener.yield(.failure(message)) }
  }

  public func events() -> AsyncStream<SharedLibraryChange> {
    let id = UUID()
    return AsyncStream { continuation in
      listeners[id] = continuation
      continuation.onTermination = { [weak self] _ in Task { await self?.removeListener(id) } }
    }
  }
  private func removeListener(_ id: UUID) { listeners.removeValue(forKey: id) }
  private func publish(
    _ snapshot: SharedLibraryViewSnapshot, entity: SharedEntityIdentity, request: UInt64
  ) {
    guard requests[entity] == request else { return }
    if let leased = leasedRevisions[entity], leased != snapshot.fingerprint { revokeAuthority() }
    let changed = cache[entity]?.fingerprint != snapshot.fingerprint
    cache[entity] = snapshot
    if changed {
      for listener in listeners.values {
        listener.yield(.entity(snapshot.libraryID, entity, snapshot.fingerprint))
      }
    }
  }
  private func beginRead(_ entity: SharedEntityIdentity) -> UInt64 {
    let next = (requests[entity] ?? 0) &+ 1
    requests[entity] = next
    if let manifest {
      for listener in listeners.values { listener.yield(.loading(manifest.libraryID, entity)) }
    }
    return next
  }
  public func read(_ entity: SharedEntityIdentity) async throws -> SharedLibraryViewSnapshot {
    let manifest = try await bind()
    let request = beginRead(entity)
    let snapshot = try await repository.load(entity: entity)
    let view = SharedLibraryViewSnapshot(libraryID: manifest.libraryID, repository: snapshot)
    publish(view, entity: entity, request: request)
    return view
  }

  public func snapshots(kinds: Set<SharedEntityKind>) async throws -> [SharedLibraryViewSnapshot] {
    _ = try await bind(force: true)
    let entities = try await repository.scan().filter { kinds.contains($0.kind) }
    return try await withThrowingTaskGroup(of: SharedLibraryViewSnapshot.self) { group in
      for entity in entities { group.addTask { try await self.read(entity) } }
      var result: [SharedLibraryViewSnapshot] = []
      for try await view in group { result.append(view) }
      return result.sorted { ($0.state.kind.rawValue, $0.state.id.uuidString) < ($1.state.kind.rawValue, $1.state.id.uuidString) }
    }
  }

  /// Progressive display reads retain per-entity errors until resident entries
  /// have had a chance to arrive. They never confer namespace mutation authority.
  func snapshots(kinds: Set<SharedEntityKind>, onSnapshot: @escaping @Sendable (SharedLibraryViewSnapshot) async -> Void) async throws -> [SharedLibraryViewSnapshot] {
    _ = try await bind(force: true)
    let entities = try await repository.scan().filter { kinds.contains($0.kind) }
    return try await withThrowingTaskGroup(of: Result<SharedLibraryViewSnapshot, Error>.self) { group in
      for entity in entities {
        group.addTask {
          do {
            let view = try await self.read(entity)
            try Task.checkCancellation()
            await onSnapshot(view)
            return .success(view)
          } catch { return .failure(error) }
        }
      }
      var result: [SharedLibraryViewSnapshot] = []
      var failure: Error?
      for try await entry in group {
        switch entry {
        case .success(let view): result.append(view)
        case .failure(let error): if failure == nil { failure = error }
        }
      }
      try Task.checkCancellation()
      if let failure { throw failure }
      return result.sorted { ($0.state.kind.rawValue, $0.state.id.uuidString) < ($1.state.kind.rawValue, $1.state.id.uuidString) }
    }
  }

  /// Resolve an existing identity, never derive a new ID from an unfamiliar
  /// filename. Initial-path hits read only that recording and its ancestors,
  /// so a cold unrelated recording cannot block a resident one.
  public func recording(at relativePath: String) async throws -> SharedLibraryViewSnapshot {
    let path = try SharedLibraryIdentity.normalized(relativePath)
    let manifest = try await bind()
    if let reference = manifest.references.first(where: { $0.entity.kind == .recording && $0.initialPath == path }) {
      let view = try await read(reference.entity)
      if try await currentPath(view) == path { return view }
      // The bootstrap identifies the original recording, not a permanent
      // reservation of its old name after a completed rename. Look up the
      // current owner when another recording legitimately reuses that path.
    }
    var matches: [SharedLibraryViewSnapshot] = []
    for entity in try await repository.scan() where entity.kind == .recording {
      let view = try await read(entity)
      if try await currentPath(view) == path { matches.append(view) }
    }
    guard matches.count == 1 else {
      throw matches.isEmpty ? SharedSidecarError.unknownRecording : SharedSidecarError.ambiguousPath
    }
    return matches[0]
  }
  func pathIndex(for views: [SharedLibraryViewSnapshot], caseSensitive: Bool = false) async throws -> SharedLibraryPathIndex {
    let manifest = try await bind(force: true)
    let membership = try await memberRepository().load().membership
    let locations = try await SharedPublishedLocations.load(root: root, manifest: manifest, membership: membership, afterLibraryRead: afterPublishedLibraryRead)
    return try SharedLibraryPathIndex(states: views.map(\.state), caseSensitive: caseSensitive,
      retainedLocations: locations.reservations(states: views.map(\.state), library: manifest.libraryID))
  }
  public func reference(to filename: String) async throws -> SharedRecordingReference {
    let view = try await recording(at: filename)
    return .init(libraryID: view.libraryID, entityID: view.state.id)
  }
  public func resolve(_ reference: SharedRecordingReference) async throws -> String {
    try await resolve(reference, beforeValidation: {})
  }
  func resolve(_ reference: SharedRecordingReference, beforeValidation: @escaping @Sendable () async throws -> Void) async throws -> String {
    // Resolution precedes job pinning and user consent. A background metadata
    // refresh may invalidate this read without changing the recording's path.
    for attempt in 0..<3 {
      try Task.checkCancellation()
      do { return try await resolveAttempt(reference, beforeValidation: beforeValidation) }
      catch SharedLibraryCoordinatorError.staleJob where attempt < 2 { continue }
    }
    throw SharedLibraryCoordinatorError.staleJob
  }
  private func resolveAttempt(_ reference: SharedRecordingReference, beforeValidation: @escaping @Sendable () async throws -> Void) async throws -> String {
    let manifest = try await bind(force: true)
    guard manifest.libraryID == reference.libraryID else { throw SharedLibraryCoordinatorError.differentBinding }
    let view = try await read(.init(id: reference.entityID, kind: .recording))
    guard view.libraryID == reference.libraryID, view.state.lifecycle == .alive else { throw SharedLibraryCoordinatorError.staleJob }
    let path = try await currentPath(view)
    let membership = try await memberRepository().load().membership
    let published = try await SharedPublishedLocations.load(root: root, manifest: manifest, membership: membership, afterLibraryRead: afterPublishedLibraryRead)
    guard published.recordings[reference.entityID]?.contains(path) == true else { throw SharedLibraryOperationError.unfinishedOperation }
    for original in published.recordings[reference.entityID] ?? [] where original != path {
      let stem = (original as NSString).deletingPathExtension
      for suffix in [".mp3", ".transcript.json", ".summary.json", ".txt", ".transcript.md", ".summary.md"] {
        let url = root.appendingPathComponent(stem + suffix)
        let placeholder = url.deletingLastPathComponent().appendingPathComponent("." + url.lastPathComponent + ".icloud")
        if FileManager.default.fileExists(atPath: url.path) || FileManager.default.fileExists(atPath: placeholder.path) { throw SharedLibraryOperationError.unfinishedOperation }
      }
    }
    try await beforeValidation()
    let latest = try await read(.init(id: reference.entityID, kind: .recording))
    guard latest.libraryID == reference.libraryID, latest.fingerprint == view.fingerprint,
          try await currentPath(latest) == path else { throw SharedLibraryCoordinatorError.staleJob }
    return path
  }
  private func currentPath(_ view: SharedLibraryViewSnapshot) async throws -> String {
    try await currentPathProof(view).path
  }
  private func currentPathProof(_ view: SharedLibraryViewSnapshot) async throws -> (path: String, ancestors: [SharedLibrarySnapshot]) {
    var ancestors: [SharedLibrarySnapshot] = []
    guard case .text(let title)? = view.state.value(for: "title"), !title.contains("/") else {
      throw SharedSidecarError.ambiguousPath
    }
    var parts = [title + ".mp3"]
    var parent = view.state.value(for: "folder")
    var visited: Set<UUID> = [view.state.id]
    while let value = parent {
      guard case .text(let text) = value, let id = UUID(uuidString: text), visited.insert(id).inserted else {
        throw SharedSidecarError.ambiguousPath
      }
      let parentView = try await read(.init(id: id, kind: .folder))
      ancestors.append(parentView.repository)
      let folder = parentView.state
      guard folder.lifecycle == .alive, case .text(let name)? = folder.value(for: "name"), !name.contains("/") else {
        throw SharedSidecarError.ambiguousPath
      }
      parts.insert(name, at: 0)
      parent = folder.value(for: "parent")
    }
    return (try SharedLibraryIdentity.normalized(parts.joined(separator: "/")), ancestors)
  }

  public func refresh() async throws {
    beginTransition(); defer { endTransition() }
    let manifest = try await bind(force: true)
    let members = try memberRepository()
    var membershipSnapshot = try await members.load()
    let entities = try await repository.scan()
    let tickets = entities.map { ($0, beginRead($0)) }
    let repository = self.repository
    var snapshots: [SharedLibrarySnapshot] = []
    try await withThrowingTaskGroup(of: (SharedEntityIdentity, UInt64, SharedLibrarySnapshot).self)
    { group in
      for (entity, ticket) in tickets {
        group.addTask { (entity, ticket, try await repository.load(entity: entity)) }
      }
      for try await (entity, ticket, snapshot) in group {
        snapshots.append(snapshot)
        publish(
          .init(libraryID: manifest.libraryID, repository: snapshot), entity: entity,
          request: ticket)
      }
    }
    var observedMembership = membershipSnapshot.membership
    for snapshot in snapshots {
      if let proof = snapshot.observedMembership {
        observedMembership = try observedMembership.merged(with: proof)
      }
    }
    if observedMembership != membershipSnapshot.membership {
      membershipSnapshot = try await members.commit(
        base: membershipSnapshot, membership: observedMembership, observing: true)
    }
    let membership = membershipSnapshot.membership
    if membership.mayEdit(writerID) {
      membershipSnapshot = try await members.commit(
        base: membershipSnapshot, membership: membership)
      for snapshot in snapshots {
        _ = try await repository.commit(.init(base: snapshot, changes: []))
      }
    }
    guard !membership.pendingWriters.isEmpty || membership.hasConcurrentEnrollment,
      membership.cohort.contains(writerID) || membership.pendingWriters.contains(writerID),
      snapshots.allSatisfy({ $0.state.conflicts.isEmpty }),
      case .ready = try await bootstrap.readiness()
    else {
      try await advanceProjections(entities)
      return
    }
    struct Checkpoint: Encodable {
      struct Entry: Encodable {
        let id: UUID
        let kind: SharedEntityKind
        let revision: String
      }
      let bootstrap: String
      let entries: [Entry]
    }
    let checkpoint = try SharedStateFingerprint.of(
      Checkpoint(
        bootstrap: manifest.fingerprint,
        entries: snapshots.map {
          .init(id: $0.state.id, kind: $0.state.kind, revision: $0.fingerprint)
        }.sorted { ($0.kind.rawValue, $0.id.uuidString) < ($1.kind.rawValue, $1.id.uuidString) }))
    let proposal = try membership.proposal(checkpoint: checkpoint)
    let vote = SharedMembershipVote(
      writer: writerID, proposal: proposal.fingerprint, checkpoint: checkpoint)
    membershipSnapshot = try await members.commit(
      base: membershipSnapshot, membership: membership, vote: vote)
    let voters = membership.requiredVoters(for: proposal).compactMap {
      membershipSnapshot.votes[$0]
    }
    let certificate: SharedMembershipCertificate
    do {
      certificate = try membershipSnapshot.membership.certify(proposal, votes: voters)
    } catch SharedMembershipError.incompleteVotes { return } catch SharedMembershipError
      .staleProposal
    { return }
    var accepted = membershipSnapshot.membership
    try accepted.accept(certificate)
    _ = try await members.commit(base: membershipSnapshot, membership: accepted)
    try await advanceProjections(entities)
  }

  private func advanceProjections(_ entities: [SharedEntityIdentity]) async throws {
    let members = try memberRepository()
    for entity in entities {
      try Task.checkCancellation()
      var memberSnapshot = try await members.load()
      let base = try await repository.load(entity: entity)
      if let proof = base.observedMembership {
        let observed = try memberSnapshot.membership.merged(with: proof)
        if observed != memberSnapshot.membership {
          memberSnapshot = try await members.commit(
            base: memberSnapshot, membership: observed, observing: true)
        }
      }
      let membership = memberSnapshot.membership
      guard membership.mayEdit(writerID), membership.pendingWriters.isEmpty,
        !membership.hasConcurrentEnrollment, base.writers.isSubset(of: membership.cohort),
        base.state.conflicts.isEmpty
      else { continue }
      let proposal = try SharedProjectionProposal(state: base.state, membership: membership)
      do {
        _ = try await repository.acknowledgeProjection(proposal, base: base)
      } catch SharedLibraryRepositoryError.staleRevision { continue }
      let observed = try await repository.load(entity: entity)
      let currentMembership = try await members.load().membership
      guard currentMembership.fingerprint == proposal.cohort else { continue }
      let actual = try? SharedProjectionProposal(
        state: observed.state, membership: currentMembership)
      guard actual?.revision == proposal.revision else { continue }
      let votes = observed.projectionVotes.values.filter {
        membership.cohort.contains($0.writer) && $0.revision == proposal.revision
          && $0.cohort == proposal.cohort
      }
      guard votes.count == membership.cohort.count else { continue }
      let certificate = try proposal.certify(votes: Array(votes))
      _ = try await repository.publishProjection(
        certificate, base: observed, membership: currentMembership)
      _ = try await read(entity)
    }
  }

  private func operationReceipts(library: UUID) throws -> URL {
    guard let directory = witnessDirectory else { throw SharedLibraryOperationError.invalidOperation }
    return directory.appendingPathComponent("Operations").appendingPathComponent(library.uuidString).appendingPathComponent(writerID.uuidString)
  }
  private var audioIntentField: String { "materialization.audio." + writerID.uuidString.lowercased() }
  private func preparedAudioDocument(library: UUID, entity: SharedEntityIdentity,
      inputRevision: String, step: SharedLibraryOperation.Step, inputAudioFingerprint: String? = nil) throws -> SharedDocument {
    try SharedDocument(id: UUID(), json: JSONEncoder().encode(SharedPreparedAudioIntent(
      libraryID: library, entity: entity, inputRevision: inputRevision, step: step, inputAudioFingerprint: inputAudioFingerprint)))
  }
  private func markAudioPublished(entity: SharedEntityIdentity, selected: String) async throws -> SharedLibraryViewSnapshot {
    let base = try await read(entity)
    guard base.state.lifecycle == .alive, base.state.conflicts.isEmpty,
          base.state.value(for: "audioFingerprint") == .text(selected) else { throw SharedLibraryCoordinatorError.staleReview }
    var changes: [SharedLibraryMutation] = [.assign(field: "audioPublished", value: .text(selected))]
    if case .document = base.state.value(for: audioIntentField) { changes.append(.assign(field: audioIntentField, value: .unset)) }
    return try await commit(.init(base: base, changes: changes), review: false, exact: true)
  }
  private func preparedAudioIntent(view: SharedLibraryViewSnapshot) throws -> SharedPreparedAudioIntent {
    guard view.state.lifecycle == .alive, view.state.conflicts.isEmpty,
      case .document(let document)? = view.state.value(for: audioIntentField),
      let intent = try? JSONDecoder().decode(SharedPreparedAudioIntent.self, from: document.json), intent.schema == 1,
      intent.libraryID == view.libraryID, intent.entity == SharedEntityIdentity(id: view.state.id, kind: .recording) else {
      throw SharedLibraryOperationError.invalidOperation
    }
    return intent
  }
  private func reconstructAudioIntent(view: SharedLibraryViewSnapshot, materializer: SharedLibraryMaterializer) async throws {
    let intent = try preparedAudioIntent(view: view)
    let path: String, selected: String
    switch intent.step {
    case .publishAudio(let value, _, let fingerprint), .replaceAudio(let value, _, _, let fingerprint, _): path = value; selected = fingerprint
    default: throw SharedLibraryOperationError.invalidOperation
    }
    guard view.state.value(for: "audioFingerprint") == .text(selected) else { throw SharedLibraryOperationError.unfinishedOperation }
    let views = try await snapshots(kinds: [.recording, .folder])
    let index = try await pathIndex(for: views)
    guard index.resolvedPaths[view.state.id] == path, index.owners(of: path) == [view.state.id] else { throw SharedLibraryOperationError.pathConflict(path) }
    let operation = try SharedLibraryOperation(libraryID: view.libraryID, entity: intent.entity,
      inputRevision: intent.inputRevision, outputRevision: SharedLibraryOperation.revision(for: view.state), steps: [intent.step], inputAudioFingerprint: intent.inputAudioFingerprint)
    try await Task.detached { try await materializer.recordIntent(operation) }.value
  }
  /// Compare actual audio, retain source identity across path changes, and stage
  /// only newly supplied bytes. Replacement permission remains cohort-bound.
  func importAudio(_ bytes: Data, entry: FileEntry, rawMD5: String,
                   beforeReplay: @escaping @Sendable () throws -> Void = {}) async throws
    -> (outcome: SharedRecordingFileOutcome, changed: Bool) {
    guard try await mayEdit() else { throw SharedLibraryCoordinatorError.enrollmentPending }
    let source = try SharedLibraryIdentity.normalized(entry.filename)
    guard !source.contains("/") else { throw SharedLibraryIdentityError.invalidRelativePath }
    let defaultPath = (source as NSString).deletingPathExtension + ".mp3"
    let views = try await snapshots(kinds: [.recording, .folder])
    let index = try await pathIndex(for: views)
    var matches: [SharedLibraryViewSnapshot] = []
    for view in views where view.state.kind == .recording {
      let metadata = try SharedRecordingMetadataAdapter.render(view)
      if metadata.deviceFilename == source || (metadata.deviceFilename == nil && index.resolvedPaths[view.state.id] == defaultPath) {
        matches.append(view)
      }
    }
    guard matches.count <= 1 else { throw SharedSidecarError.ambiguousPath }
    let reported = entry.md5.lowercased()
    let verifiedMD5 = rawMD5 == reported && reported != String(repeating: "0", count: 32) ? rawMD5 : nil
    let base: SharedLibraryViewSnapshot
    let filename: String
    var hasPublishedAudio = false
    if let existing = matches.first {
      guard existing.state.lifecycle == .alive, existing.state.conflicts.isEmpty else { throw SharedSidecarError.conflictedContent }
      let manifest = try await bind(force: true)
      let membership = try await memberRepository().load().membership
      let locations = try await SharedPublishedLocations.load(root: root, manifest: manifest, membership: membership, afterLibraryRead: afterPublishedLibraryRead)
      hasPublishedAudio = locations.recordings[existing.state.id]?.isEmpty == false
      if hasPublishedAudio {
        filename = try await resolve(.init(libraryID: existing.libraryID, entityID: existing.state.id))
      } else {
        // A newly accepted import may have been cancelled before staging. Its
        // source claim already owns an identity; retry supplies bytes to it.
        guard existing.state.fields["audioPublished"] != nil,
              existing.state.value(for: "audioPublished") != existing.state.value(for: "audioFingerprint"),
              let path = index.resolvedPaths[existing.state.id], index.owners(of: path) == [existing.state.id] else {
          throw SharedLibraryOperationError.unfinishedOperation
        }
        filename = path
      }
      base = existing
    } else {
      guard index.owners(of: defaultPath).isEmpty else { throw SharedLibraryOperationError.pathConflict(defaultPath) }
      let stem = (defaultPath as NSString).deletingPathExtension
      for suffix in [".mp3", ".transcript.json", ".summary.json", ".txt", ".transcript.md", ".summary.md"] {
        let url = root.appendingPathComponent(stem + suffix)
        let placeholder = url.deletingLastPathComponent().appendingPathComponent("." + url.lastPathComponent + ".icloud")
        guard !FileManager.default.fileExists(atPath: url.path), !FileManager.default.fileExists(atPath: placeholder.path) else { throw SharedLibraryOperationError.pathConflict(stem + suffix) }
      }
      let id = try verifiedMD5.map { try SharedLibraryIdentity.deviceImport(filename: source, sourceMD5: $0) } ?? UUID()
      base = try await read(.init(id: id, kind: .recording))
      guard base.state.fields.isEmpty else { throw SharedLibraryOperationError.unfinishedOperation }
      filename = defaultPath
    }
    let entity = SharedEntityIdentity(id: base.state.id, kind: .recording)
    let receipts = try operationReceipts(library: base.libraryID)
    let materializer = try await makeMaterializer(entity: entity, paths: [filename], receipts: receipts)
    if let progress = try await materializer.progress(entity: entity, libraryID: base.libraryID),
       progress.completedSteps < progress.operation.steps.count {
      guard base.state.value(for: "audioFingerprint") == .text(SharedLibraryOperation.fingerprint(bytes)) else { throw SharedLibraryOperationError.unfinishedOperation }
      return (try await resumeRecordingOperation(id: entity.id), true)
    }
    let previous = try SharedRecordingMetadataAdapter.render(base)
    let selected = SharedLibraryOperation.fingerprint(bytes)
    if previous.sourceMD5 == reported, reported.count == 32, rawMD5 != reported, previous.audioSHA256 != selected {
      throw HiDockError.transferFailed("The downloaded recording failed its device checksum. Existing audio was left unchanged.")
    }
    let actual = try await RecordingFileAccess().readDataIfPresent(at: root.appendingPathComponent(filename), knownToExist: hasPublishedAudio)
    let actualHash = actual.map(SharedLibraryOperation.fingerprint)
    let priorHash: String?
    if case .text(let fingerprint)? = base.state.value(for: "audioFingerprint") { priorHash = fingerprint }
    else { priorHash = previous.audioSHA256 }
    let parsed = FilenameParsing.parse(filename)
    let mode = previous.mode ?? (parsed.mode == .unknown ? nil : parsed.mode.rawValue)
    let recordedAt = previous.recordedAt ?? parsed.date
    var metadata = previous
    metadata.deviceFilename = source; metadata.sourceMD5 = verifiedMD5
    metadata.audioSHA256 = selected; metadata.mode = mode; metadata.recordedAt = recordedAt
    guard let old = try JSONSerialization.jsonObject(with: JSONEncoder().encode(previous)) as? [String: Any],
          let next = try JSONSerialization.jsonObject(with: JSONEncoder().encode(metadata)) as? [String: Any] else { throw SharedSidecarError.invalidContent }
    var changes: [SharedLibraryMutation] = []
    if base.state.fields.isEmpty {
      changes += [.assign(field: "initialPath", value: .text(filename)),
                  .assign(field: "title", value: .text((filename as NSString).deletingPathExtension)),
                  .assign(field: "folder", value: .unset)]
    }
    for key in Set(old.keys).union(next.keys).sorted() {
      let encode: (Any) throws -> Data = { try JSONSerialization.data(withJSONObject: $0, options: [.fragmentsAllowed, .sortedKeys]) }
      let before = try old[key].map(encode), after = try next[key].map(encode)
      if before != after { changes.append(.assign(field: "metadata." + key, value: after.map { .text(String(decoding: $0, as: UTF8.self)) } ?? .unset)) }
    }
    if base.state.value(for: "audioFingerprint") != .text(selected) { changes.append(.assign(field: "audioFingerprint", value: .text(selected))) }
    // Never publish the new baseline until its sole canonical audio was replaced.
    if actualHash != selected && base.state.value(for: "audioPublished") == nil {
      changes.append(.assign(field: "audioPublished", value: priorHash.map(SharedFieldValue.text) ?? .unset))
    }
    if actualHash == selected {
      let accepted = changes.isEmpty ? base : try await commit(.init(base: base, changes: changes), review: false, exact: true)
      if accepted.state.fields["audioPublished"] != nil, accepted.state.value(for: "audioPublished") != .text(selected) {
        throw SharedLibraryOperationError.unfinishedOperation
      }
      _ = try await projectOutputs()
      return (.init(filename: filename, result: .complete, projectionError: nil, view: accepted), false)
    }
    let stagingDirectory = root.appendingPathComponent(".docktape/staging/" + entity.id.uuidString)
    var reusable: String?
    for file in LibraryFileDiscovery.files(in: stagingDirectory, suffix: ".mp3").sorted(by: { $0.relativePath < $1.relativePath }) {
      guard !file.relativePath.contains("/"), UUID(uuidString: String(file.relativePath.dropLast(4))) != nil else { throw SharedLibraryOperationError.unsafePath }
      let candidate = stagingDirectory.appendingPathComponent(file.relativePath)
      guard SharedLibraryMaterializer.contained(candidate, in: stagingDirectory),
            SharedLibraryMaterializer.contained(candidate, in: root) else { throw SharedLibraryOperationError.unsafePath }
      if let stagedBytes = try await RecordingFileAccess().readDataIfPresent(at: candidate, knownToExist: true),
         SharedLibraryOperation.fingerprint(stagedBytes) == selected {
        reusable = ".docktape/staging/" + entity.id.uuidString + "/" + file.relativePath
        break
      }
    }
    let stager = try await makeInputStager(entity: entity, library: base.libraryID)
    let staged: String
    if let reusable { staged = reusable }
    else { staged = try await stager.stageNewAudio(bytes, entity: entity) }
    let repair = priorHash == selected
    let step: SharedLibraryOperation.Step = !hasPublishedAudio
      ? .publishAudio(path: filename, staged: staged, selectedFingerprint: selected)
      : .replaceAudio(path: filename, staged: staged, expectedFingerprint: actualHash, selectedFingerprint: selected, repair: repair)
    if case .document = base.state.value(for: fileIntentField) { changes.append(.assign(field: fileIntentField, value: .unset)) }
    changes.append(.assign(field: audioIntentField, value: .document(try preparedAudioDocument(
      library: base.libraryID, entity: entity, inputRevision: base.fingerprint, step: step, inputAudioFingerprint: priorHash))))
    let accepted: SharedLibraryViewSnapshot
    do { accepted = try await commit(.init(base: base, changes: changes), review: false, exact: true) }
    catch {
      // Cleanup refuses any currently accepted matching input, including a
      // peer's concurrent acceptance. Never delete an accepted sole copy.
      try? await Task.detached { try await stager.discardStagedAudio(staged, entity: entity, fingerprint: selected) }.value
      throw error
    }
    let operation = try SharedLibraryOperation(libraryID: accepted.libraryID, entity: entity,
      inputRevision: base.fingerprint, outputRevision: SharedLibraryOperation.revision(for: accepted.state), steps: [step], inputAudioFingerprint: priorHash)
    try await Task.detached { try await materializer.recordIntent(operation) }.value
    try Task.checkCancellation()
    if !repair && hasPublishedAudio {
      let permission = try await operationAuthority(entity: entity, paths: [])
      if !permission.hasPendingWork { try await acknowledgeOperation(entity: entity, purpose: .replaceAudio, expectedRevision: operation.outputRevision) }
    }
    try beforeReplay()
    let result = try await materializer.replay(operation)
    var completed = accepted, projectionError: String?
    if result == .complete {
      completed = try await markAudioPublished(entity: entity, selected: selected)
      do { _ = try await projectOutputs() } catch { projectionError = error.localizedDescription }
    }
    return (.init(filename: filename, result: result, projectionError: projectionError, view: completed), true)
  }

  public func mergeRecordings(filenames: [String], as filename: String,
                              references: [String: SharedRecordingReference] = [:],
                              beforeSourceProof: @escaping @Sendable (SharedEntityIdentity) async throws -> Void = { _ in },
                              beforeCommit: @escaping @Sendable () async throws -> Void = {}) async throws -> SharedRecordingFileOutcome {
    guard filenames.count >= 2 else { throw HiDockError.invalidFilename("Need at least 2 recordings to merge") }
    guard try await mayEdit() else { throw SharedLibraryCoordinatorError.enrollmentPending }
    let path = try SharedLibraryIdentity.normalized(filename)
    guard !path.contains("/"), path.hasSuffix(".mp3") else { throw SharedLibraryIdentityError.invalidRelativePath }
    var tokens: [SharedLibraryJobToken] = []
    do {
      var concatenator = MP3Concatenator()
      var dates: [Date] = [], mode: String?, sources: [String] = []
      for input in filenames {
        let reference: SharedRecordingReference
        if let captured = references[input] { reference = captured }
        else { reference = try await self.reference(to: input) }
        let current = try await resolve(reference)
        let entity = SharedEntityIdentity(id: reference.entityID, kind: .recording)
        let url = root.appendingPathComponent(current)
        let token = try await pinJob(entity, audioURL: url)
        tokens.append(token)
        guard let data = try await RecordingFileAccess().readDataIfPresent(at: url, knownToExist: true) else { throw CocoaError(.fileReadNoSuchFile) }
        try concatenator.append(data)
        let metadata = try SharedRecordingMetadataAdapter.render(token.snapshot)
        if let date = metadata.recordedAt ?? FilenameParsing.parse((current as NSString).lastPathComponent).date { dates.append(date) }
        if mode == nil { mode = token.recordingMode }
        sources.append(current)
      }
      let bytes = try concatenator.output()
      let metadata = RecordingStore.RecordingMeta(mode: mode?.isEmpty == false ? mode : nil,
        deviceFilename: nil, mergedFrom: sources, recordedAt: dates.min(), audioSHA256: SharedLibraryOperation.fingerprint(bytes))
      let outcome = try await publishMergedAudio(bytes, filename: path, metadata: metadata, tokens: tokens, beforeSourceProof: beforeSourceProof, beforeCommit: beforeCommit)
      for token in tokens { await finishJob(token) }
      return outcome
    } catch {
      for token in tokens { await finishJob(token) }
      throw error
    }
  }
  private func publishMergedAudio(_ bytes: Data, filename: String, metadata: RecordingStore.RecordingMeta,
                                  tokens: [SharedLibraryJobToken], beforeSourceProof: @Sendable (SharedEntityIdentity) async throws -> Void,
                                  beforeCommit: @Sendable () async throws -> Void) async throws -> SharedRecordingFileOutcome {
    let views = try await snapshots(kinds: [.recording, .folder])
    let index = try await pathIndex(for: views)
    let stem = (filename as NSString).deletingPathExtension
    guard index.owners(of: filename).isEmpty else { throw SharedLibraryOperationError.pathConflict(filename) }
    for suffix in [".mp3", ".transcript.json", ".summary.json", ".transcript.md", ".summary.md", ".txt"] {
      let url = root.appendingPathComponent(stem + suffix)
      let placeholder = url.deletingLastPathComponent().appendingPathComponent("." + url.lastPathComponent + ".icloud")
      guard !FileManager.default.fileExists(atPath: url.path), !FileManager.default.fileExists(atPath: placeholder.path) else { throw SharedLibraryOperationError.pathConflict(stem + suffix) }
    }
    let manifest = try await bind(force: true)
    let entity = SharedEntityIdentity(id: UUID(), kind: .recording)
    let base = try await repository.load(entity: entity)
    var bindings: [SharedMaterializationBinding] = []
    let membership = try await memberRepository().load().membership
    for token in tokens {
      try await validateJob(token)
      guard token.library == manifest.libraryID, let owned = jobs[token.id], let inputFile = owned.inputFile, !owned.lease.isRevoked else { throw SharedLibraryCoordinatorError.staleJob }
      try await beforeSourceProof(token.entity)
      let fresh = try await repository.load(entity: token.entity)
      guard fresh.state.lifecycle == .alive,
            try Self.lifecycleRevision(fresh.state) == token.lifecycle,
            try Self.inputRevision(fresh.state, component: token.component) == token.input else { throw SharedLibraryCoordinatorError.staleJob }
      try Self.validateProcessingState(fresh.state, input: token.component, output: nil)
      guard fresh.writers.isSubset(of: membership.cohort) else { throw SharedLibraryCoordinatorError.unrecognizedWriter }
      bindings += try repository.readBindings(fresh, validateSourceSet: true)
      bindings.append(inputFile)
    }
    bindings.append(.init(file: root.appendingPathComponent(".docktape/format.json")) { data in
      guard let value = try? JSONDecoder().decode(SharedBootstrapManifest.self, from: data) else { return false }
      return value.complete && value.libraryID == manifest.libraryID && value.fingerprint == manifest.fingerprint
    })
    // Several sources share the format anchor. Keep one read accessor while
    // retaining every independent source-set and format predicate.
    let groups = Dictionary(grouping: bindings, by: \.file)
    let proofs = groups.map { file, predicates in
      SharedMaterializationBinding(file: file) { data in
        for predicate in predicates where try !predicate.validate(data) { return false }
        return true
      }
    }.sorted { $0.file.path < $1.file.path }
    let selected = SharedLibraryOperation.fingerprint(bytes)
    let provenance = tokens.map { token in ["library": token.library.uuidString, "entity": token.entity.id.uuidString, "inputRevision": token.input] }
    var changes: [SharedLibraryMutation] = [
      .assign(field: "initialPath", value: .text(filename)), .assign(field: "title", value: .text(stem)),
      .assign(field: "folder", value: .unset), .assign(field: "audioFingerprint", value: .text(selected)),
      .assign(field: "audioPublished", value: .unset),
      .assign(field: "legacyMetadata", value: .document(try SharedDocument(id: UUID(), json: JSONEncoder().encode(metadata)))),
      .assign(field: "mergeSources", value: .document(try SharedDocument(id: UUID(), json: JSONSerialization.data(withJSONObject: provenance, options: .sortedKeys))))]
    let materializer = try await makeMaterializer(entity: entity, paths: [filename], receipts: operationReceipts(library: manifest.libraryID))
    let stager = try await makeInputStager(entity: entity, library: manifest.libraryID)
    let staged = try await stager.stageNewAudio(bytes, entity: entity)
    let step = SharedLibraryOperation.Step.publishAudio(path: filename, staged: staged, selectedFingerprint: selected)
    changes.append(.assign(field: audioIntentField, value: .document(try preparedAudioDocument(
      library: manifest.libraryID, entity: entity, inputRevision: base.fingerprint, step: step))))
    do { try await beforeCommit(); try Task.checkCancellation() }
    catch {
      try? await Task.detached { try await stager.discardStagedAudio(staged, entity: entity, fingerprint: selected) }.value
      throw error
    }
    let leases = tokens.map(\.lease)
    let validate: @Sendable (SharedEntityState) throws -> Void = { state in
      guard state.lifecycle == .uninitialized, leases.allSatisfy({ !$0.isRevoked }) else { throw SharedLibraryCoordinatorError.staleJob }
    }
    let accepted: SharedLibrarySnapshot
    beginTransition()
    do {
      accepted = try await repository.commit(.init(base: base, changes: changes, validation: validate, bindings: proofs))
      endTransition()
    } catch {
      endTransition()
      try? await Task.detached { try await stager.discardStagedAudio(staged, entity: entity, fingerprint: selected) }.value
      throw error
    }
    var view = SharedLibraryViewSnapshot(libraryID: manifest.libraryID, repository: accepted)
    publish(view, entity: entity, request: beginRead(entity))
    await afterCommit()
    let operation = try SharedLibraryOperation(libraryID: manifest.libraryID, entity: entity,
      inputRevision: base.fingerprint, outputRevision: SharedLibraryOperation.revision(for: view.state),
      steps: [step])
    try await Task.detached { try await materializer.recordIntent(operation) }.value
    try Task.checkCancellation()
    let result = try await materializer.replay(operation)
    var projectionError: String?
    if result == .complete {
      view = try await markAudioPublished(entity: entity, selected: selected)
      do { _ = try await projectOutputs() } catch { projectionError = error.localizedDescription }
    }
    return .init(filename: filename, result: result, projectionError: projectionError, view: view)
  }

  private var fileIntentField: String { SharedEntityState.fileIntentField(writer: writerID) }
  private func preparedFileOperation(base: SharedLibraryViewSnapshot, steps: [SharedLibraryOperation.Step]) -> SharedPreparedFileOperation {
    .init(libraryID: base.libraryID, entity: .init(id: base.state.id, kind: base.state.kind), inputRevision: base.fingerprint, steps: steps)
  }
  private func discardCancelledDeletion(view: SharedLibraryViewSnapshot, reader: SharedLibraryMaterializer) async throws {
    guard view.state.lifecycle == .alive, view.state.conflicts.isEmpty,
          let previous = try await reader.progress(entity: .init(id: view.state.id, kind: view.state.kind), libraryID: view.libraryID),
          previous.completedSteps == 0, !previous.phaseWasAttempted,
          previous.operation.steps.allSatisfy({ if case .trash = $0 { return true }; return false }) else { return }
    try await reader.discardSupersededDeletion(previous.operation)
  }

  private func currentDeletionIntentOwner(in view: SharedLibraryViewSnapshot) throws -> UUID? {
    guard view.state.lifecycle == .deleted, view.state.conflicts.isEmpty else { return nil }
    // A previous Delete→Keep can leave this writer's stale durable intent.
    // Prefer a currently bound deletion, retaining its accepted file hashes.
    let prefix = "materialization.files."
    let owners = view.state.fields.keys.compactMap { field -> UUID? in
      guard field.hasPrefix(prefix) else { return nil }
      return UUID(uuidString: String(field.dropFirst(prefix.count)))
    }.sorted { lhs, rhs in
      if lhs == writerID { return rhs != writerID }
      return rhs != writerID && lhs.uuidString < rhs.uuidString
    }
    for owner in owners {
      guard case .document(let document)? = view.state.value(for: SharedEntityState.fileIntentField(writer: owner)),
            let intent = try? JSONDecoder().decode(SharedAcceptedFileIntent.self, from: document.json),
            intent.schema == 1, intent.libraryID == view.libraryID,
            intent.entity == SharedEntityIdentity(id: view.state.id, kind: view.state.kind),
            !intent.steps.isEmpty, intent.steps.allSatisfy({ if case .trash = $0 { return true }; return false }),
            try view.state.fileIntentGuardRevision(writer: owner) == intent.guardRevision else { continue }
      return owner
    }
    return nil
  }
  private func currentFolderIntentOwner(in view: SharedLibraryViewSnapshot) throws -> UUID? {
    guard view.state.kind == .folder, view.state.conflicts.isEmpty else { return nil }
    let prefix = "materialization.files."
    let owners = view.state.fields.keys.filter { $0.hasPrefix(prefix) }.compactMap { UUID(uuidString: String($0.dropFirst(prefix.count))) }
      .sorted { $0 == writerID ? $1 != writerID : $1 != writerID && $0.uuidString < $1.uuidString }
    return try owners.first { owner in
      guard case .document(let document)? = view.state.value(for: SharedEntityState.fileIntentField(writer: owner)),
            let intent = try? JSONDecoder().decode(SharedAcceptedFileIntent.self, from: document.json),
            intent.schema == 1, intent.libraryID == view.libraryID, intent.entity == .init(id: view.state.id, kind: .folder), intent.steps.count == 1 else { return false }
      return try view.state.fileIntentGuardRevision(writer: owner) == intent.guardRevision
    }
  }
  private func recoverFileIntent(view: SharedLibraryViewSnapshot, reader: SharedLibraryMaterializer, intentWriter: UUID? = nil,
                                 reviewedFolder: SharedLibraryViewSnapshot? = nil, expectedCohort: String? = nil) async throws -> Bool {
    let owner = try intentWriter ?? currentDeletionIntentOwner(in: view) ?? currentFolderIntentOwner(in: view) ?? writerID
    let field = SharedEntityState.fileIntentField(writer: owner)
    guard case .document(let document)? = view.state.value(for: field) else { return true }
    guard let intent = try? JSONDecoder().decode(SharedAcceptedFileIntent.self, from: document.json), intent.schema == 1 else { throw SharedLibraryOperationError.invalidReceipt }
    guard intent.libraryID == view.libraryID, intent.entity == SharedEntityIdentity(id: view.state.id, kind: view.state.kind) else { throw SharedLibraryOperationError.differentBinding }
    if view.state.lifecycle == .alive, view.state.conflicts.isEmpty,
       intent.steps.allSatisfy({ if case .trash = $0 { return true }; return false }) {
      try await discardCancelledDeletion(view: view, reader: reader)
      return try await reader.progress(entity: intent.entity, libraryID: intent.libraryID) == nil
    }
    guard view.state.conflicts.isEmpty, try view.state.fileIntentGuardRevision(writer: owner) == intent.guardRevision else { return false }
    guard intent.steps.allSatisfy({ step in
      switch step { case .move, .moveDirectory, .trash, .createDirectory, .removeEmptyDirectory: return true; default: return false }
    }) else { throw SharedLibraryOperationError.invalidOperation }
    let previous = try await reader.progress(entity: intent.entity, libraryID: intent.libraryID)
    if let previous, previous.operation.steps == intent.steps, previous.operation.inputRevision == intent.inputRevision,
       previous.operation.reviewedExistingDestinations == intent.reviewedExistingDestinations {
      if view.state.kind == .folder, intent.steps.count == 1,
         try !SharedLibraryOperation.matchesRevision(previous.operation.outputRevision, state: view.state) {
        switch intent.steps[0] {
        case .moveDirectory, .removeEmptyDirectory:
          let materializer = try await makeMaterializer(entity: intent.entity, paths: Array(previous.operation.canonicalPaths),
            receipts: operationReceipts(library: intent.libraryID), expectedCohort: expectedCohort, reviewedFolder: reviewedFolder)
          try await materializer.refreshFolderOperationAuthority(previous, intentWriter: owner)
        default: break
        }
      }
      return true
    }
    var operation = try SharedLibraryOperation(libraryID: intent.libraryID, entity: intent.entity,
      inputRevision: intent.inputRevision, outputRevision: SharedLibraryOperation.revision(for: view.state), steps: intent.steps)
    operation.reviewedExistingDestinations = intent.reviewedExistingDestinations
    if let previous, previous.completedSteps < previous.operation.steps.count {
      let materializer = try await makeMaterializer(entity: intent.entity, paths: Array(operation.canonicalPaths), receipts: operationReceipts(library: intent.libraryID))
      if intent.replacesOperationID == previous.operation.id, intent.inputRevision == previous.operation.outputRevision {
        do { try await Task.detached { try await materializer.replan(operation, replacing: previous.operation.id) }.value }
        catch SharedLibraryOperationError.unfinishedOperation { return false }
      } else if view.state.lifecycle == .deleted, previous.completedSteps == 0, !previous.phaseWasAttempted,
                previous.operation.steps.allSatisfy({ if case .trash = $0 { return true }; return false }),
                operation.steps.allSatisfy({ if case .trash = $0 { return true }; return false }),
                previous.operation.canonicalPaths.isSubset(of: operation.canonicalPaths) {
        do { try await Task.detached { try await materializer.adoptUnstartedDeletion(operation, replacing: previous.operation) }.value }
        catch SharedLibraryOperationError.unfinishedOperation { return false }
      } else { return false }
    } else { try await Task.detached { try await reader.recordIntent(operation) }.value }
    return true
  }
  private struct FolderMoveMember: Codable, Sendable {
    let id: UUID
    let kind: SharedEntityKind
    let path: String
  }
  private struct FolderMoveScope: Codable, Sendable {
    let library: UUID
    let folder: UUID
    let destination: String
    let members: [FolderMoveMember]
  }

  public func renameFolder(from source: String, to destination: String, reference: SharedFolderReference? = nil,
                           afterMutation: @escaping @Sendable (Int) throws -> Void = { _ in }) async throws -> SharedFolderFileOutcome {
    _ = try SharedLibraryIdentity.normalized(source); _ = try SharedLibraryIdentity.normalized(destination)
    guard !source.contains("/"), !destination.contains("/") else { throw SharedLibraryIdentityError.invalidRelativePath }
    let views = try await snapshots(kinds: [.recording, .folder])
    let sensitive = (try? root.resourceValues(forKeys: [.volumeSupportsCaseSensitiveNamesKey]))?.volumeSupportsCaseSensitiveNames ?? false
    let index = try await pathIndex(for: views, caseSensitive: sensitive)
    let matches = views.filter { view in
      view.state.kind == .folder && (index.resolvedPaths[view.state.id] == source || view.state.value(for: "physicalPath") == .text(source))
    }
    guard matches.count == 1, let base = matches.first else { throw SharedLibraryPathError.ambiguousPath }
    if let reference, reference.libraryID != base.libraryID || reference.entityID != base.state.id { throw SharedLibraryCoordinatorError.differentBinding }
    guard index.owners(of: source) == [base.state.id] else { throw SharedLibraryOperationError.pathConflict(source) }
    guard base.state.lifecycle == .alive, base.state.conflicts.isEmpty else { throw SharedSidecarError.conflictedContent }
    if source == destination { return .init(id: base.state.id, name: destination, result: .complete, projectionError: nil) }
    let entity = SharedEntityIdentity(id: base.state.id, kind: .folder)
    let receipts = try operationReceipts(library: base.libraryID)
    let reader = try await makeMaterializer(entity: entity, paths: [], receipts: receipts)
    if let progress = try await reader.progress(entity: entity, libraryID: base.libraryID), progress.completedSteps < progress.operation.steps.count {
      guard case .moveDirectory(let old, let new, _) = progress.operation.steps.first, old == source, new == destination else { throw SharedLibraryOperationError.unfinishedOperation }
      return try await resumeFolderOperation(id: entity.id, afterMutation: afterMutation)
    }
    guard index.owners(of: destination).isEmpty else { throw SharedLibraryOperationError.pathConflict(destination) }
    let target = root.appendingPathComponent(destination)
    guard !FileManager.default.fileExists(atPath: target.path),
          !FileManager.default.fileExists(atPath: root.appendingPathComponent("." + destination + ".icloud").path) else { throw SharedLibraryOperationError.pathConflict(destination) }
    let inventory = try await SharedDirectoryInventory.prepare(at: root.appendingPathComponent(source))
    let manifest = try await bind(force: true)
    let membership = try await memberRepository().load().membership
    let published = try await SharedPublishedLocations.load(root: root, manifest: manifest, membership: membership, afterLibraryRead: afterPublishedLibraryRead)
    for view in views where view.state.kind == .recording {
      guard let path = index.resolvedPaths[view.state.id], path.hasPrefix(source + "/") else { continue }
      let stem = (path as NSString).deletingPathExtension
      for (suffix, kind) in [(".transcript.json", "transcript"), (".summary.json", "summary")] {
        let relative = String((stem + suffix).dropFirst(source.count + 1))
        if let entry = inventory.entries.first(where: { $0.path == relative && !$0.directory }),
           let data = try await RecordingFileAccess().readDataIfPresent(at: root.appendingPathComponent(stem + suffix), knownToExist: true) {
          guard SharedLibraryOperation.fingerprint(data) == entry.fingerprint else { throw SharedLibraryOperationError.contentChanged(stem + suffix) }
          try published.validateCompanion(path: stem + suffix, bytes: data, entity: view.state.id, library: base.libraryID, kind: kind)
        }
      }
    }
    let materializer = try await makeMaterializer(entity: entity, paths: [source, destination], receipts: receipts, afterMutation: afterMutation)
    let scope = FolderMoveScope(library: base.libraryID, folder: entity.id, destination: destination,
      members: views.compactMap { view in
        guard view.state.id != entity.id, let path = index.resolvedPaths[view.state.id], path.hasPrefix(source + "/") else { return nil }
        return FolderMoveMember(id: view.state.id, kind: view.state.kind, path: destination + String(path.dropFirst(source.count)))
      }.sorted { $0.id.uuidString < $1.id.uuidString })
    let document = try SharedDocument(id: UUID(), json: JSONEncoder().encode(scope))
    let accepted = try await commit(.init(base: base, changes: [.assign(field: "name", value: .text(destination)),
      .assign(field: "physicalPath", value: .text(source)), .assign(field: "moveScope", value: .document(document))]), review: false, exact: true,
      preparedFileOperation: preparedFileOperation(base: base, steps: [.moveDirectory(source: source, destination: destination, inventory: inventory)]))
    let operation = try SharedLibraryOperation(libraryID: base.libraryID, entity: entity,
      inputRevision: base.fingerprint, outputRevision: SharedLibraryOperation.revision(for: accepted.state),
      steps: [.moveDirectory(source: source, destination: destination, inventory: inventory)])
    // The semantic commit has happened. Save its recovery plan even if
    // cancellation arrived in the post-commit callback; never claim rollback.
    try await Task.detached { try await materializer.recordIntent(operation) }.value
    try Task.checkCancellation()
    let result = try await materializer.replay(operation)
    return try await completeFolderMove(view: accepted, operation: operation, destination: destination, result: result)
  }
  public func resumeFolderOperation(id: UUID, afterMutation: @escaping @Sendable (Int) throws -> Void = { _ in }) async throws -> SharedFolderFileOutcome {
    try await resumeFolderOperation(id: id, intentWriter: nil, reviewed: nil, afterMutation: afterMutation)
  }
  private func resumeFolderOperation(id: UUID, intentWriter: UUID?, reviewed: SharedFolderOperationReview?, afterMutation: @escaping @Sendable (Int) throws -> Void) async throws -> SharedFolderFileOutcome {
    let entity = SharedEntityIdentity(id: id, kind: .folder)
    let view = try await read(entity)
    if let reviewed {
      guard reviewed.base.libraryID == view.libraryID, repository.accepts(reviewed.base.repository) else { throw SharedLibraryCoordinatorError.differentBinding }
      guard reviewed.base.state == view.state else { throw SharedLibraryCoordinatorError.staleReview }
    }
    let receipts = try operationReceipts(library: view.libraryID)
    let reader = try await makeMaterializer(entity: entity, paths: [], receipts: receipts, expectedCohort: reviewed?.cohort, reviewedFolder: reviewed?.base)
    let oldProgress = try await reader.progress(entity: entity, libraryID: view.libraryID)
    let alreadyMoved: Bool
    if let oldProgress, oldProgress.completedSteps == oldProgress.operation.steps.count,
       case .moveDirectory(_, let destination, _) = oldProgress.operation.steps.first {
      alreadyMoved = view.state.lifecycle == .alive && view.state.conflicts.isEmpty && view.state.value(for: "physicalPath") == .text(destination) && view.state.value(for: "name") == .text(destination)
    } else { alreadyMoved = false }
    if !alreadyMoved, try await !recoverFileIntent(view: view, reader: reader, intentWriter: intentWriter, reviewedFolder: reviewed?.base, expectedCohort: reviewed?.cohort) {
      return .init(id: id, name: view.state.value(for: "name").flatMap { if case .text(let name) = $0 { return name }; return nil } ?? "", result: .needsReplanning, projectionError: nil)
    }
    guard let progress = try await reader.progress(entity: entity, libraryID: view.libraryID) else { throw SharedLibraryOperationError.invalidOperation }
    if let expected = reviewed?.operation {
      guard progress.operation.steps == expected.steps, progress.operation.inputRevision == expected.inputRevision else { throw SharedLibraryCoordinatorError.staleReview }
    }
    if case .createDirectory(let path) = progress.operation.steps.first, progress.operation.steps.count == 1 {
      let materializer = try await makeMaterializer(entity: entity, paths: [path], receipts: receipts, afterMutation: afterMutation, expectedCohort: reviewed?.cohort, reviewedFolder: reviewed?.base)
      let result = try await materializer.replay(progress.operation)
      var projectionError: String?
      if result == .complete { do { _ = try await projectOutputs() } catch { projectionError = error.localizedDescription } }
      return .init(id: id, name: path, result: result, projectionError: projectionError)
    }
    guard case .moveDirectory(let source, let destination, _) = progress.operation.steps.first else { throw SharedLibraryOperationError.invalidOperation }
    if progress.completedSteps == progress.operation.steps.count,
       view.state.lifecycle == .alive, view.state.conflicts.isEmpty,
       view.state.value(for: "physicalPath") == .text(destination),
       view.state.value(for: "name") == .text(destination) {
      let permission = try await operationAuthority(entity: entity, paths: [], reviewedFolder: reviewed?.base, expectedCohort: reviewed?.cohort)
      guard try await folderMoveFilesStatus(progress.operation, permission: permission, allowLaterEdits: true) == .complete else {
        return .init(id: id, name: destination, result: .needsReplanning, projectionError: nil)
      }
      var projectionError: String?
      do { _ = try await projectOutputs() } catch { projectionError = error.localizedDescription }
      return .init(id: id, name: destination, result: .complete, projectionError: projectionError)
    }
    let materializer = try await makeMaterializer(entity: entity, paths: [source, destination], receipts: receipts, afterMutation: afterMutation, expectedCohort: reviewed?.cohort, reviewedFolder: reviewed?.base)
    let result = try await materializer.replay(progress.operation)
    return try await completeFolderMove(view: view, operation: progress.operation, destination: destination, result: result)
  }
  private func completeFolderMove(view: SharedLibraryViewSnapshot, operation: SharedLibraryOperation, destination: String, result: SharedMaterializationResult) async throws -> SharedFolderFileOutcome {
    var projectionError: String?
    if result == .complete {
      if view.state.value(for: "physicalPath") != .text(destination) {
        // Rebind the accepted inventory to the final metadata without taking a
        // new physical snapshot. A peer may receive this before the directory.
        let prepared = SharedPreparedFileOperation(libraryID: view.libraryID,
          entity: .init(id: view.state.id, kind: .folder), inputRevision: operation.inputRevision, steps: operation.steps)
        _ = try await commit(.init(base: view, changes: [.assign(field: "physicalPath", value: .text(destination))]),
          review: false, exact: true, preparedFileOperation: prepared)
      }
      do { _ = try await projectOutputs() } catch { projectionError = error.localizedDescription }
    }
    return .init(id: view.state.id, name: destination, result: result, projectionError: projectionError)
  }

  public func reviewFolderOperation(id: UUID) async throws -> SharedFolderOperationReview? {
    for attempt in 0..<5 {
      do { return try await reviewFolderOperationAttempt(id: id) }
      catch {
        guard attempt < 4, error as? SharedLibraryOperationError == .staleAuthority, !Task.isCancelled else { throw error }
        try await Task.sleep(for: .milliseconds(25 << attempt))
      }
    }
    throw SharedLibraryOperationError.staleAuthority
  }
  private func reviewFolderOperationAttempt(id: UUID) async throws -> SharedFolderOperationReview? {
    let entity = SharedEntityIdentity(id: id, kind: .folder)
    let view = try await read(entity)
    let reader = try await makeMaterializer(entity: entity, paths: [], receipts: operationReceipts(library: view.libraryID))
    let progress = try await reader.progress(entity: entity, libraryID: view.libraryID)
    var request: FolderDeletionRequest?
    if case .document(let document)? = view.state.value(for: "deletionRequest") {
      let value = try JSONDecoder().decode(FolderDeletionRequest.self, from: document.json)
      guard value.library == view.libraryID, value.folder == id, !value.path.contains("/"),
            Set(value.members.map(\.id)).count == value.members.count,
            value.members.allSatisfy({ $0.path.hasPrefix(value.path + "/") }) else { throw SharedLibraryOperationError.invalidOperation }
      _ = try SharedLibraryIdentity.normalized(value.path)
      request = value
    }
    let prefix = "materialization.files."
    var candidates: [(owner: UUID, intent: SharedAcceptedFileIntent, valid: Bool)] = []
    for field in view.state.fields.keys.sorted() where field.hasPrefix(prefix) {
      guard let owner = UUID(uuidString: String(field.dropFirst(prefix.count))),
            case .document(let document)? = view.state.value(for: field) else { continue }
      let intent = try JSONDecoder().decode(SharedAcceptedFileIntent.self, from: document.json)
      guard intent.schema == 1, intent.libraryID == view.libraryID, intent.entity == entity, intent.steps.count == 1 else { throw SharedLibraryOperationError.invalidReceipt }
      switch intent.steps[0] { case .createDirectory, .moveDirectory, .removeEmptyDirectory: break; default: throw SharedLibraryOperationError.invalidReceipt }
      candidates.append((owner, intent, try view.state.fileIntentGuardRevision(writer: owner) == intent.guardRevision))
    }
    let selected = candidates.first(where: { $0.owner == writerID && $0.valid }) ?? candidates.first(where: { $0.valid })
      ?? candidates.first(where: { $0.owner == writerID }) ?? candidates.first
    var operation: SharedLibraryOperation?
    if let selected {
      if let progress, progress.operation.steps == selected.intent.steps, progress.operation.inputRevision == selected.intent.inputRevision { operation = progress.operation }
      else { operation = try .init(libraryID: view.libraryID, entity: entity, inputRevision: selected.intent.inputRevision,
        outputRevision: SharedLibraryOperation.revision(for: view.state), steps: selected.intent.steps) }
    } else { operation = progress?.operation }
    guard request != nil || operation != nil else { return nil }
    let purpose: SharedFolderOperationReview.Purpose
    if request != nil { purpose = .delete }
    else {
      switch operation?.steps.first {
      case .createDirectory: purpose = .create
      case .moveDirectory: purpose = .rename
      case .removeEmptyDirectory: purpose = .delete
      default: throw SharedLibraryOperationError.invalidOperation
      }
    }
    var paths = operation.map { Array($0.canonicalPaths) } ?? []
    if let request { paths += [request.path] + request.members.map(\.path) }
    paths = Array(Set(paths)).sorted()
    // Children retain their own recording/folder authorities. This inspection
    // checks only the root path while aggregating descendant jobs and state.
    let authorityPaths = request.map { [$0.path] } ?? paths
    let permission = try await operationAuthority(entity: entity, paths: purpose == .rename ? [] : authorityPaths)
    guard try SharedLibraryOperation.matchesRevision(SharedLibraryOperation.revision(for: view.state), state: permission.state) else { throw SharedLibraryOperationError.staleAuthority }
    var conflict = !view.state.conflicts.isEmpty
    if !conflict, view.state.lifecycle == .alive {
      if purpose == .rename, let operation {
        let status = try await folderMoveFilesStatus(operation, permission: permission,
          allowLaterEdits: progress == nil || progress?.completedSteps == progress?.operation.steps.count)
        if status == .complete, selected?.valid == true,
           progress == nil || progress?.completedSteps == progress?.operation.steps.count,
           case .moveDirectory(_, let destination, _) = operation.steps.first,
           view.state.value(for: "physicalPath") == .text(destination), view.state.value(for: "name") == .text(destination) { return nil }
        conflict = status == .conflict || !permission.directoryScopeMatches
      }
      if purpose == .create, selected?.valid == true, case .createDirectory(let destination)? = operation?.steps.first,
         try await folderDirectoryIsPresent(destination, permission: permission) { return nil }
    }
    let valid = request != nil && view.state.lifecycle == .alive ? true : selected?.valid == true
    let needsReplanning = conflict || !valid
    if purpose == .delete, !needsReplanning, view.state.lifecycle == .deleted {
      let removalPaths = request.map { [$0.path] } ?? paths
      if try await acknowledgedRemovalIsPresent(paths: removalPaths, permission: permission) { return nil }
    }
    let approved = permission.approvedWriters(for: .delete)
    let stable = permission.membership.pendingWriters.isEmpty && !permission.membership.hasConcurrentEnrollment
    let deleting = purpose == .delete && view.state.lifecycle == .deleted
    let waiting = deleting ? permission.membership.cohort.subtracting(approved).map { $0 == writerID ? "This Mac" : permission.membership.label(for: $0) }.sorted() : []
    let canAcknowledge = deleting && !needsReplanning && !permission.hasPendingWork && !permission.hasLiveDescendants
      && stable && permission.membership.cohort.contains(writerID) && !approved.contains(writerID)
    let canResume = !needsReplanning && !permission.hasPendingWork && permission.membership.mayEdit(writerID)
      && (!deleting || permission.mayDestroy(.delete))
    let name = request?.path ?? view.state.value(for: "name").flatMap { if case .text(let text) = $0 { return text }; return nil } ?? "Folder"
    return .init(name: name, purpose: purpose, paths: paths, waitingForMacs: waiting, hasActiveWork: permission.hasPendingWork,
      needsReplanning: needsReplanning, canAcknowledge: canAcknowledge, canResume: canResume, base: view,
      cohort: permission.membership.fingerprint, deletionRequest: request != nil, operation: operation, intentWriter: selected?.owner)
  }
  private enum FolderMoveFilesStatus { case complete, pending, conflict }
  /// Completion is a physical proof, not a metadata/receipt assertion. The
  /// original inventory remains authoritative for ordinary files; only exact
  /// current derived exports may differ after the accepted move is published.
  private func folderMoveFilesStatus(_ operation: SharedLibraryOperation, permission: SharedMaterializationAuthority, allowLaterEdits: Bool = false) async throws -> FolderMoveFilesStatus {
    guard operation.steps.count == 1, case .moveDirectory(let source, let destination, let original) = operation.steps[0],
          permission.state.lifecycle == .alive, permission.state.conflicts.isEmpty, permission.directoryScopeMatches || allowLaterEdits,
          case .document(let document)? = permission.state.value(for: "moveScope"),
          let scope = try? JSONDecoder().decode(FolderMoveScope.self, from: document.json),
          scope.library == permission.libraryID, scope.folder == permission.state.id, scope.destination == destination,
          let gate else { return .conflict }
    let views = try await snapshots(kinds: [.recording, .folder])
    for view in views {
      guard leasedRevisions[.init(id: view.state.id, kind: view.state.kind)] == view.fingerprint else { throw SharedLibraryOperationError.staleAuthority }
    }
    let index = try SharedLibraryPathIndex(states: views.map(\.state), caseSensitive: false)
    var requiredOriginal = Dictionary(uniqueKeysWithValues: original.entries.map { ($0.path, $0) })
    var alternatives: [String: Set<String>] = [:], requiredFiles: Set<String> = [], allowedDirectories: Set<String> = []
    let suffixes = [".mp3", ".transcript.json", ".summary.json", ".transcript.md", ".summary.md", ".txt"]
    if allowLaterEdits {
      // Completed moves must not reappear after later accepted child work.
      // Replace only known recording slots with their current semantic proofs;
      // unknown/ordinary original files still require their original hashes.
      for member in scope.members where member.kind == .recording {
        let stem = String((member.path as NSString).deletingPathExtension.dropFirst(destination.count + 1))
        for suffix in suffixes { requiredOriginal.removeValue(forKey: stem + suffix) }
      }
      for member in scope.members where member.kind == .folder {
        if views.first(where: { $0.state.id == member.id })?.state.lifecycle == .deleted {
          requiredOriginal.removeValue(forKey: String(member.path.dropFirst(destination.count + 1)))
        }
      }
    }
    for view in views where view.state.lifecycle == .alive {
      guard let path = index.resolvedPaths[view.state.id], path.hasPrefix(destination + "/") else { continue }
      if view.state.kind == .folder {
        if allowLaterEdits { allowedDirectories.insert(String(path.dropFirst(destination.count + 1))) }
        continue
      }
      guard view.state.kind == .recording, view.state.conflicts.isEmpty, index.owners(of: path) == [view.state.id] else { return .conflict }
      let member = scope.members.first { $0.id == view.state.id && $0.kind == .recording }
      if !allowLaterEdits && member?.path != path { return .conflict }
      for (file, bytes) in try SharedLibraryReadableExport.files(view: view, recordingPath: path) {
        alternatives[String(file.dropFirst(destination.count + 1)), default: []].insert(SharedLibraryOperation.fingerprint(bytes))
      }
      if allowLaterEdits {
        let relative = String(path.dropFirst(destination.count + 1)), stem = (relative as NSString).deletingPathExtension
        requiredFiles.insert(relative)
        if let member {
          let oldStem = String((member.path as NSString).deletingPathExtension.dropFirst(destination.count + 1))
          for suffix in suffixes {
            if let hash = original.entries.first(where: { $0.path == oldStem + suffix })?.fingerprint {
              alternatives[stem + suffix, default: []].insert(hash)
            }
          }
        }
        if case .text(let hash)? = view.state.value(for: "audioFingerprint"), SharedLibraryOperation.validHash(hash) {
          alternatives[relative, default: []].insert(hash)
        }
        for (owner, _, intent) in try SharedPublishedLocations.fileIntents(state: view.state, library: view.libraryID) {
          guard let writer = UUID(uuidString: owner), try view.state.fileIntentGuardRevision(writer: writer) == intent.guardRevision else { continue }
          for step in intent.steps {
            if case .move(_, let target, let hash) = step, target == path { alternatives[relative, default: []].insert(hash) }
          }
        }
      }
    }
    let expected = requiredOriginal, accepted = alternatives, required = requiredFiles, directories = allowedDirectories
    let bindings = permission.additionalBindings + (permission.binding.map { [$0] } ?? [])
    let root = self.root, from = root.appendingPathComponent(source), to = root.appendingPathComponent(destination)
    let placeholder = from.deletingLastPathComponent().appendingPathComponent("." + from.lastPathComponent + ".icloud")
    let items = try gate.items(outside: root)
    return try await CoordinatedFileAccess().withWrites(items, reading: [root] + bindings.map(\.file) + [from, placeholder, to]) { scopes in
      try gate.validate(scopes[0], outside: root)
      guard !permission.revisionLease.isRevoked, try permission.validateLocalCommit(),
            scopes[items.count].url.standardizedFileURL.resolvingSymlinksInPath() == root.standardizedFileURL.resolvingSymlinksInPath() else { throw SharedLibraryOperationError.staleAuthority }
      try SharedLibraryMaterializer.checkRoot(root)
      for (binding, read) in zip(bindings, scopes.dropFirst(items.count + 1)) {
        guard read.url.standardizedFileURL.resolvingSymlinksInPath() == binding.file.standardizedFileURL.resolvingSymlinksInPath(),
              try binding.validate(Data(contentsOf: read.url)) else { throw SharedLibraryOperationError.staleAuthority }
      }
      let files = Array(scopes.suffix(3))
      for (expected, actual) in zip([from, placeholder, to], files) {
        guard actual.url.standardizedFileURL == expected.standardizedFileURL,
              SharedLibraryMaterializer.contained(actual.url, in: root) else { throw SharedLibraryOperationError.unsafePath }
      }
      try files[0].checkCancellation()
      let fm = FileManager.default
      let hasSource = fm.fileExists(atPath: files[0].url.path)
      let hasPlaceholder = fm.fileExists(atPath: files[1].url.path)
      let hasDestination = fm.fileExists(atPath: files[2].url.path)
      if hasSource || hasPlaceholder {
        guard !hasDestination else { return .conflict }
        if hasPlaceholder && !hasSource { return .pending }
        return (try? SharedDirectoryInventory.capture(at: files[0].url)) == original ? .pending : .conflict
      }
      guard hasDestination else { return .pending }
      guard let actual = try? SharedDirectoryInventory.capture(at: files[2].url) else { return .conflict }
      let current = Dictionary(uniqueKeysWithValues: actual.entries.map { ($0.path, $0) })
      for entry in expected.values {
        guard let present = current[entry.path], present.directory == entry.directory else { return .conflict }
        if !entry.directory, present.fingerprint != entry.fingerprint,
           !accepted[entry.path, default: []].contains(present.fingerprint ?? "") { return .conflict }
      }
      for path in required {
        guard let entry = current[path], !entry.directory, accepted[path, default: []].contains(entry.fingerprint ?? "") else { return .conflict }
      }
      for entry in actual.entries where expected[entry.path] == nil {
        if entry.directory { guard directories.contains(entry.path) else { return .conflict } }
        else if !accepted[entry.path, default: []].contains(entry.fingerprint ?? "") { return .conflict }
      }
      return .complete
    }
  }
  private func folderDirectoryIsPresent(_ path: String, permission: SharedMaterializationAuthority) async throws -> Bool {
    guard let gate else { return false }
    let bindings = permission.additionalBindings + (permission.binding.map { [$0] } ?? [])
    let root = self.root, directory = root.appendingPathComponent(path), items = try gate.items(outside: root)
    return try await CoordinatedFileAccess().withWrites(items, reading: [root] + bindings.map(\.file) + [directory]) { scopes in
      try gate.validate(scopes[0], outside: root)
      guard !permission.revisionLease.isRevoked, try permission.validateLocalCommit(),
            scopes[items.count].url.standardizedFileURL.resolvingSymlinksInPath() == root.standardizedFileURL.resolvingSymlinksInPath() else { return false }
      try SharedLibraryMaterializer.checkRoot(root)
      for (binding, scope) in zip(bindings, scopes.dropFirst(items.count + 1)) {
        guard scope.url.standardizedFileURL.resolvingSymlinksInPath() == binding.file.standardizedFileURL.resolvingSymlinksInPath(),
              try binding.validate(Data(contentsOf: scope.url)) else { return false }
      }
      let actual = scopes[items.count + bindings.count + 1].url
      guard actual.standardizedFileURL == directory.standardizedFileURL,
            SharedLibraryMaterializer.contained(actual, in: root) else { return false }
      try scopes[0].checkCancellation()
      return (try? FileManager.default.attributesOfItem(atPath: actual.path)[.type] as? FileAttributeType) == .typeDirectory
    }
  }
  private func validateFolderReview(_ review: SharedFolderOperationReview) async throws {
    let current = try await read(.init(id: review.id, kind: .folder))
    guard current.libraryID == review.base.libraryID, repository.accepts(review.base.repository) else { throw SharedLibraryCoordinatorError.differentBinding }
    guard current.fingerprint == review.base.fingerprint else { throw SharedLibraryCoordinatorError.staleReview }
    guard try await memberRepository().load().membership.fingerprint == review.cohort else { throw SharedLibraryOperationError.staleAuthority }
    guard try await mayEdit() else { throw SharedLibraryCoordinatorError.enrollmentPending }
  }
  public func acknowledgeReviewedFolderOperation(_ review: SharedFolderOperationReview) async throws {
    try await validateFolderReview(review)
    guard review.canAcknowledge, review.purpose == .delete else { throw SharedLibraryOperationError.invalidOperation }
    try await acknowledgeOperation(entity: .init(id: review.id, kind: .folder), purpose: .delete,
      expectedRevision: SharedLibraryOperation.revision(for: review.base.state), expectedCohort: review.cohort)
  }
  public func resumeReviewedFolderOperation(_ review: SharedFolderOperationReview) async throws -> SharedFolderFileOutcome {
    try await validateFolderReview(review)
    guard review.canResume else { throw SharedLibraryOperationError.invalidOperation }
    if review.deletionRequest { return try await resumeFolderDeletion(id: review.id, reviewedFolder: review.base, expectedCohort: review.cohort) }
    guard let operation = review.operation else { throw SharedLibraryOperationError.invalidOperation }
    if case .removeEmptyDirectory(let path) = operation.steps.first { return try await removeDeletedEmptyFolder(id: review.id, path: path, reviewedFolder: review.base, expectedCohort: review.cohort) }
    return try await resumeFolderOperation(id: review.id, intentWriter: review.intentWriter, reviewed: review, afterMutation: { _ in })
  }

  private struct FolderDeletionMember: Codable, Sendable {
    let id: UUID
    let kind: SharedEntityKind
    let path: String
    let revision: String
  }
  private struct FolderDeletionRequest: Codable, Sendable {
    let library: UUID
    let folder: UUID
    let path: String
    let members: [FolderDeletionMember]
  }
  private func validatedFolderDeletionRequest(_ document: SharedDocument, base: SharedLibraryViewSnapshot) throws -> FolderDeletionRequest {
    let request = try JSONDecoder().decode(FolderDeletionRequest.self, from: document.json)
    guard base.state.kind == .folder, request.library == base.libraryID, request.folder == base.state.id,
          !request.path.contains("/"), (try? SharedLibraryIdentity.normalized(request.path)) == request.path,
          Set(request.members.map(\.id)).count == request.members.count,
          Set(request.members.map(\.path)).count == request.members.count,
          request.members.allSatisfy({ member in
            member.id != request.folder && (member.kind == .recording || member.kind == .folder)
              && member.path.hasPrefix(request.path + "/")
              && (try? SharedLibraryIdentity.normalized(member.path)) == member.path
              && !member.revision.isEmpty
              && (member.kind != .recording || member.path.hasSuffix(".mp3"))
          }) else { throw SharedLibraryOperationError.differentBinding }
    return request
  }
  public func folderDeletionRequestChoices(_ base: SharedLibraryViewSnapshot) async throws -> [SharedFolderDeletionRequestReview] {
    let manifest = try await bind(force: true)
    guard base.libraryID == manifest.libraryID, repository.accepts(base.repository) else { throw SharedLibraryCoordinatorError.differentBinding }
    guard base.state.kind == .folder, base.state.lifecycle == .alive || base.state.lifecycle == .deleted else { return [] }
    return (base.state.fields["deletionRequest"]?.values ?? []).compactMap { value in
      guard case .document(let document) = value, let request = try? validatedFolderDeletionRequest(document, base: base) else { return nil }
      return SharedFolderDeletionRequestReview(path: request.path,
        members: request.members.sorted { $0.path < $1.path }.map { .init(path: $0.path, kind: $0.kind) }, base: base, document: document)
    }.sorted { $0.document.id.uuidString < $1.document.id.uuidString }
  }
  /// Saves only the reviewed request. It grants no cleanup/acknowledgment authority.
  public func resolveFolderDeletionRequest(_ review: SharedFolderDeletionRequestReview) async throws -> SharedLibraryViewSnapshot {
    let request = try validatedFolderDeletionRequest(review.document, base: review.base)
    guard review.base.state.fields["deletionRequest"]?.values.contains(review.value) == true else { throw SharedLibraryCoordinatorError.staleReview }
    var prepared: SharedPreparedFileOperation?
    if review.base.state.lifecycle == .deleted {
      let entity = SharedEntityIdentity(id: review.base.state.id, kind: .folder)
      let steps: [SharedLibraryOperation.Step] = [.removeEmptyDirectory(path: request.path)]
      let prefix = "materialization.files."
      let fields = review.base.state.fields.keys.filter { $0.hasPrefix(prefix) }.sorted {
        if $0 == fileIntentField { return $1 != fileIntentField }
        if $1 == fileIntentField { return false }
        return $0 < $1
      }
      let candidates = fields.compactMap { field -> SharedAcceptedFileIntent? in
        guard case .document(let document)? = review.base.state.value(for: field),
              let intent = try? JSONDecoder().decode(SharedAcceptedFileIntent.self, from: document.json),
              intent.schema == 1, intent.libraryID == review.base.libraryID, intent.entity == entity, intent.steps == steps else { return nil }
        return intent
      }
      let reader = try await makeMaterializer(entity: entity, paths: [], receipts: operationReceipts(library: review.base.libraryID))
      let previous = try await reader.progress(entity: entity, libraryID: review.base.libraryID)
      // An unrelated intent owned by this writer must not be overwritten,
      // even if a peer has a matching removal intent for the local receipt.
      if fields.contains(fileIntentField), !candidates.contains(where: { candidate in
        guard case .document(let own)? = review.base.state.value(for: fileIntentField),
              let intent = try? JSONDecoder().decode(SharedAcceptedFileIntent.self, from: own.json) else { return false }
        return candidate.steps == intent.steps && candidate.inputRevision == intent.inputRevision
      }) { throw SharedLibraryOperationError.unfinishedOperation }
      let original: SharedAcceptedFileIntent?
      if let previous {
        guard previous.operation.steps == steps, let matching = candidates.first(where: {
          $0.inputRevision == previous.operation.inputRevision && $0.reviewedExistingDestinations == previous.operation.reviewedExistingDestinations
        }) else { throw SharedLibraryOperationError.unfinishedOperation }
        original = matching
      } else {
        guard fields.isEmpty || !candidates.isEmpty else { throw SharedLibraryOperationError.unfinishedOperation }
        original = candidates.first
      }
      var plan = SharedPreparedFileOperation(libraryID: review.base.libraryID, entity: entity,
        inputRevision: original?.inputRevision ?? review.base.fingerprint, steps: steps)
      plan.replacesOperationID = original?.replacesOperationID
      plan.retainedFiles = original?.retainedFiles ?? [:]
      plan.reviewedExistingDestinations = original?.reviewedExistingDestinations
      prepared = plan
    }
    var changes: [SharedLibraryMutation] = review.base.state.lifecycle == .deleted ? [.restore] : []
    changes.append(.assign(field: "deletionRequest", value: review.value))
    if review.base.state.lifecycle == .deleted { changes.append(.delete) }
    return try await commit(.init(base: review.base, changes: changes), review: true, exact: true, preparedFileOperation: prepared)
  }
  public func deleteFolder(named name: String, reference: SharedFolderReference? = nil, beforeFinalRemoval: @escaping @Sendable () async throws -> Void = {}) async throws -> SharedFolderFileOutcome {
    _ = try SharedLibraryIdentity.normalized(name)
    guard !name.contains("/") else { throw SharedLibraryIdentityError.invalidRelativePath }
    let views = try await snapshots(kinds: [.recording, .folder])
    let sensitive = (try? root.resourceValues(forKeys: [.volumeSupportsCaseSensitiveNamesKey]))?.volumeSupportsCaseSensitiveNames ?? false
    let index = try await pathIndex(for: views, caseSensitive: sensitive)
    let matches = views.filter { $0.state.kind == .folder && index.resolvedPaths[$0.state.id] == name }
    guard matches.count == 1, let base = matches.first else { throw SharedLibraryPathError.ambiguousPath }
    if let reference, reference.libraryID != base.libraryID || reference.entityID != base.state.id { throw SharedLibraryCoordinatorError.differentBinding }
    guard index.owners(of: name) == [base.state.id] else { throw SharedLibraryOperationError.pathConflict(name) }
    if case .document = base.state.value(for: "deletionRequest") {
      return try await resumeFolderDeletion(id: base.state.id, beforeFinalRemoval: beforeFinalRemoval)
    }
    guard base.state.lifecycle == .alive, base.state.conflicts.isEmpty else { throw SharedSidecarError.conflictedContent }
    if let physical = base.state.value(for: "physicalPath"), physical != .text(name) { throw SharedLibraryOperationError.unfinishedOperation }
    let members = views.filter { $0.state.id != base.state.id && (index.resolvedPaths[$0.state.id]?.hasPrefix(name + "/") == true) }
    guard members.allSatisfy({ $0.state.lifecycle == .alive && $0.state.conflicts.isEmpty }) else { throw SharedSidecarError.conflictedContent }
    let request = FolderDeletionRequest(library: base.libraryID, folder: base.state.id, path: name,
      members: members.map { .init(id: $0.state.id, kind: $0.state.kind, path: index.resolvedPaths[$0.state.id]!, revision: $0.fingerprint) }.sorted { $0.path < $1.path })
    _ = try await commit(.init(base: base, changes: [.assign(field: "deletionRequest", value: .document(try SharedDocument(id: UUID(), json: JSONEncoder().encode(request))))]), review: false, exact: true)
    return try await resumeFolderDeletion(id: base.state.id, beforeFinalRemoval: beforeFinalRemoval)
  }
  public func resumeFolderDeletion(id: UUID, reviewedFolder: SharedLibraryViewSnapshot? = nil, expectedCohort: String? = nil,
                                   beforeMemberDeletion: @escaping @Sendable () async throws -> Void = {}, beforeFinalRemoval: @escaping @Sendable () async throws -> Void = {}) async throws -> SharedFolderFileOutcome {
    let rootEntity = SharedEntityIdentity(id: id, kind: .folder)
    let view = try await read(rootEntity)
    if let reviewedFolder {
      guard reviewedFolder.libraryID == view.libraryID, repository.accepts(reviewedFolder.repository) else { throw SharedLibraryCoordinatorError.differentBinding }
      guard reviewedFolder.state == view.state else { throw SharedLibraryCoordinatorError.staleReview }
    }
    guard view.state.conflicts.isEmpty, case .document(let document)? = view.state.value(for: "deletionRequest") else { throw SharedSidecarError.conflictedContent }
    let request = try JSONDecoder().decode(FolderDeletionRequest.self, from: document.json)
    guard request.library == view.libraryID, request.folder == id, !request.path.contains("/"),
          Set(request.members.map(\.id)).count == request.members.count,
          request.members.allSatisfy({ $0.path.hasPrefix(request.path + "/") }) else { throw SharedLibraryOperationError.differentBinding }
    let views = try await snapshots(kinds: [.recording, .folder])
    let index = try await pathIndex(for: views)
    let expected = Set(request.members.map(\.id))
    let actual = Set(views.filter { $0.state.id != id && index.resolvedPaths[$0.state.id]?.hasPrefix(request.path + "/") == true }.map { $0.state.id })
    guard actual == expected, index.resolvedPaths[id] == request.path else { return .init(id: id, name: request.path, result: .needsReplanning, projectionError: nil) }
    if view.state.lifecycle == .deleted {
      let permission = try await operationAuthority(entity: rootEntity, paths: [request.path], reviewedFolder: reviewedFolder, expectedCohort: expectedCohort)
      if try await acknowledgedRemovalIsPresent(paths: [request.path], permission: permission) {
        return .init(id: id, name: request.path, result: .complete, projectionError: nil)
      }
    }
    for member in request.members {
      guard let current = views.first(where: { $0.state.id == member.id && $0.state.kind == member.kind }),
            current.state.conflicts.isEmpty,
            current.state.lifecycle == .deleted || current.fingerprint == member.revision else { return .init(id: id, name: request.path, result: .needsReplanning, projectionError: nil) }
    }
    let permission = try await operationAuthority(entity: rootEntity, paths: [], reviewedFolder: reviewedFolder, expectedCohort: expectedCohort)
    if permission.hasPendingWork { return .init(id: id, name: request.path, result: .waitingForActiveWork, projectionError: nil) }
    for member in request.members where member.kind == .recording {
      try await beforeMemberDeletion()
      let entity = SharedEntityIdentity(id: member.id, kind: .recording)
      let current = try await read(entity)
      let receipts = try operationReceipts(library: view.libraryID)
      let reader = try await makeMaterializer(entity: entity, paths: [], receipts: receipts)
      if let progress = try await reader.progress(entity: entity, libraryID: view.libraryID),
         progress.operation.steps.allSatisfy({ if case .trash = $0 { return true }; return false }) {
        if progress.completedSteps < progress.operation.steps.count {
          let result = try await resumeRecordingOperation(id: member.id, expectedCohort: expectedCohort, reviewedFolder: reviewedFolder)
          if result.result != .complete { return .init(id: id, name: request.path, result: result.result, projectionError: result.projectionError) }
        }
      } else {
        if current.state.lifecycle == .deleted && !FileManager.default.fileExists(atPath: root.appendingPathComponent(member.path).path) {
          let stem = String(member.path.dropLast(4))
          let paths = [".mp3", ".transcript.json", ".summary.json", ".txt", ".transcript.md", ".summary.md"].map { stem + $0 }
          let permission = try await operationAuthority(entity: entity, paths: paths, reviewedFolder: reviewedFolder, expectedCohort: expectedCohort)
          if try await acknowledgedRemovalIsPresent(paths: paths, permission: permission) { continue }
          return .init(id: id, name: request.path, result: .waitingForFile(member.path), projectionError: nil)
        }
        let result = try await deleteRecording(filename: member.path,
          reference: .init(libraryID: view.libraryID, entityID: member.id), expectedMember: member,
          reviewedFolder: reviewedFolder, expectedCohort: expectedCohort)
        if result.result != .complete { return .init(id: id, name: request.path, result: result.result, projectionError: result.projectionError) }
      }
    }
    let folders = request.members.filter { $0.kind == .folder }.sorted { $0.path.count > $1.path.count }
    for member in folders {
      let outcome = try await removeDeletedEmptyFolder(id: member.id, path: member.path, reviewedFolder: reviewedFolder, expectedCohort: expectedCohort)
      if outcome.result != .complete { return .init(id: id, name: request.path, result: outcome.result, projectionError: outcome.projectionError) }
    }
    try await beforeFinalRemoval()
    return try await removeDeletedEmptyFolder(id: id, path: request.path, reviewedFolder: reviewedFolder, expectedCohort: expectedCohort)
  }
  /// A mirrored deletion is complete only with exact cohort permission and
  /// coordinated absence of every owned path and any iCloud placeholders.
  /// This does not claim that this Mac moved the original files to Trash.
  private func acknowledgedRemovalIsPresent(paths: [String], permission: SharedMaterializationAuthority,
                                             unstarted operation: SharedLibraryOperation? = nil) async throws -> Bool {
    guard permission.mayDestroy(.delete), let gate else { return false }
    let bindings = permission.additionalBindings + (permission.binding.map { [$0] } ?? [])
    for binding in bindings { _ = try await RecordingFileAccess().waitUntilAvailable(at: binding.file, knownToExist: true) }
    let items = try gate.items(outside: root)
    let receipt = try operation.map { try operationReceipts(library: $0.libraryID).appendingPathComponent($0.entity.id.uuidString + ".json") }
    let root = self.root
    return try await CoordinatedFileAccess().withWrites(items, reading: [root] + bindings.map(\.file) + (receipt.map { [$0] } ?? [])) { scopes in
      try gate.validate(scopes[0], outside: root)
      guard !permission.revisionLease.isRevoked, try permission.validateLocalCommit() else { return false }
      let directory = scopes[items.count].url
      try SharedLibraryMaterializer.checkRoot(directory)
      guard directory.standardizedFileURL.resolvingSymlinksInPath().path == root.standardizedFileURL.resolvingSymlinksInPath().path else { throw SharedLibraryOperationError.unsafePath }
      for (binding, scope) in zip(bindings, scopes.dropFirst(items.count + 1)) {
        guard scope.url.standardizedFileURL.resolvingSymlinksInPath() == binding.file.standardizedFileURL.resolvingSymlinksInPath(),
              try binding.validate(Data(contentsOf: scope.url)) else { return false }
      }
      if let operation, let receipt {
        let scope = scopes[items.count + 1 + bindings.count]
        guard scope.url.standardizedFileURL.resolvingSymlinksInPath() == receipt.standardizedFileURL.resolvingSymlinksInPath(),
              let bytes = try? Data(contentsOf: scope.url) else { return false }
        let current = try SharedOperationReceipt.decode(bytes)
        guard current.operation == operation, current.completed == 0, !current.attempting else { return false }
      }
      try scopes[0].checkCancellation()
      return paths.allSatisfy { path in
        let target = directory.appendingPathComponent(path)
        let placeholder = target.deletingLastPathComponent().appendingPathComponent("." + target.lastPathComponent + ".icloud")
        return !FileManager.default.fileExists(atPath: target.path) && !FileManager.default.fileExists(atPath: placeholder.path)
      }
    }
  }

  /// A reconstructed peer receipt is not local Trash progress. Recognize an
  /// acknowledged provider removal only while its receipt is still untouched,
  /// checking late companions and placeholders under the same authority.
  private func mirroredRecordingRemovalIsPresent(view: SharedLibraryViewSnapshot, progress: SharedLibraryOperationProgress,
                                                  expectedCohort: String? = nil, reviewedFolder: SharedLibraryViewSnapshot? = nil) async throws -> Bool {
    let operation = progress.operation
    guard progress.completedSteps == 0, !progress.phaseWasAttempted,
          let owner = try currentDeletionIntentOwner(in: view),
          case .document(let document)? = view.state.value(for: SharedEntityState.fileIntentField(writer: owner)),
          let intent = try? JSONDecoder().decode(SharedAcceptedFileIntent.self, from: document.json),
          intent.steps == operation.steps, intent.inputRevision == operation.inputRevision else { return false }
    var paths = operation.canonicalPaths
    for path in operation.canonicalPaths where path.hasSuffix(".mp3") {
      let stem = String(path.dropLast(4))
      paths.formUnion([".mp3", ".transcript.json", ".summary.json", ".txt", ".transcript.md", ".summary.md"].map { stem + $0 })
    }
    let permission = try await operationAuthority(entity: operation.entity, paths: Array(paths), reviewedFolder: reviewedFolder, expectedCohort: expectedCohort)
    if let expectedCohort, permission.membership.fingerprint != expectedCohort { throw SharedLibraryOperationError.staleAuthority }
    guard try SharedLibraryOperation.matchesRevision(operation.outputRevision, state: permission.state) else { return false }
    return try await acknowledgedRemovalIsPresent(paths: Array(paths), permission: permission, unstarted: operation)
  }

  private func removeDeletedEmptyFolder(id: UUID, path: String, reviewedFolder: SharedLibraryViewSnapshot? = nil, expectedCohort: String? = nil) async throws -> SharedFolderFileOutcome {
    let entity = SharedEntityIdentity(id: id, kind: .folder)
    let base = try await read(entity)
    let target = root.appendingPathComponent(path)
    if FileManager.default.fileExists(atPath: target.path), !(try FileManager.default.contentsOfDirectory(atPath: target.path)).isEmpty {
      return .init(id: id, name: path, result: .directoryNotEmpty(path), projectionError: nil)
    }
    let before = try await operationAuthority(entity: entity, paths: [path], reviewedFolder: reviewedFolder, expectedCohort: expectedCohort)
    if before.hasLiveDescendants { return .init(id: id, name: path, result: .needsReplanning, projectionError: nil) }
    let steps: [SharedLibraryOperation.Step] = [.removeEmptyDirectory(path: path)]
    let materializer = try await makeMaterializer(entity: entity, paths: [path], receipts: operationReceipts(library: base.libraryID), expectedCohort: expectedCohort, reviewedFolder: reviewedFolder)
    let accepted: SharedLibraryViewSnapshot
    if base.state.lifecycle != .deleted {
      accepted = try await commit(.init(base: base, changes: [.delete]), review: false, exact: true, bindings: folderReviewBindings(reviewedFolder, excluding: entity),
        preparedFileOperation: preparedFileOperation(base: base, steps: steps))
      let operation = try SharedLibraryOperation(libraryID: accepted.libraryID, entity: entity,
        inputRevision: base.fingerprint, outputRevision: SharedLibraryOperation.revision(for: accepted.state), steps: steps)
      try await Task.detached { try await materializer.recordIntent(operation) }.value
      try Task.checkCancellation()
    } else {
      accepted = base
      // A peer may have accepted the deletion before this Mac received its
      // directory removal. Use that original guarded intent, never fresh bytes
      // or a fresh lifecycle permission inferred from the tombstone alone.
      let prefix = "materialization.files."
      var candidates: [UUID] = []
      for field in base.state.fields.keys where field.hasPrefix(prefix) {
        guard let owner = UUID(uuidString: String(field.dropFirst(prefix.count))),
          case .document(let document)? = base.state.value(for: field),
          let intent = try? JSONDecoder().decode(SharedAcceptedFileIntent.self, from: document.json),
          intent.schema == 1, intent.libraryID == base.libraryID, intent.entity == entity, intent.steps == steps,
          try base.state.fileIntentGuardRevision(writer: owner) == intent.guardRevision else { continue }
        candidates.append(owner)
      }
      if let owner = candidates.sorted(by: { $0.uuidString < $1.uuidString }).first {
        guard try await recoverFileIntent(view: base, reader: materializer, intentWriter: owner) else {
          return .init(id: id, name: path, result: .needsReplanning, projectionError: nil)
        }
      }
    }
    guard let progress = try await materializer.progress(entity: entity, libraryID: accepted.libraryID),
      progress.operation.steps == steps,
      try SharedLibraryOperation.matchesRevision(progress.operation.outputRevision, state: accepted.state) else {
      return .init(id: id, name: path, result: .needsReplanning, projectionError: nil)
    }
    let operation = progress.operation
    let phaseFolder = reviewedFolder?.state.id == entity.id ? accepted : reviewedFolder
    let guardedMaterializer = try await makeMaterializer(entity: entity, paths: [path], receipts: operationReceipts(library: base.libraryID),
      expectedCohort: expectedCohort, reviewedFolder: phaseFolder)
    let permission = try await operationAuthority(entity: entity, paths: [path], reviewedFolder: phaseFolder, expectedCohort: expectedCohort)
    if !permission.hasPendingWork && !permission.hasLiveDescendants { try await acknowledgeOperation(entity: entity, purpose: .delete, expectedRevision: operation.outputRevision, expectedCohort: expectedCohort, reviewedFolder: phaseFolder) }
    let result = try await guardedMaterializer.replay(operation)
    var projectionError: String?
    if result == .complete { do { _ = try await projectOutputs() } catch { projectionError = error.localizedDescription } }
    return .init(id: id, name: path, result: result, projectionError: projectionError)
  }

  public func createSharedFolder(named name: String) async throws {
    _ = try SharedLibraryIdentity.normalized(name)
    guard !name.contains("/") else { throw SharedLibraryIdentityError.invalidRelativePath }
    let views = try await snapshots(kinds: [.recording, .folder])
    let index = try await pathIndex(for: views)
    guard index.owners(of: name).isEmpty, !FileManager.default.fileExists(atPath: root.appendingPathComponent(name).path) else {
      throw SharedLibraryOperationError.pathConflict(name)
    }
    let entity = SharedEntityIdentity(id: UUID(), kind: .folder)
    let base = try await read(entity)
    let materializer = try await makeMaterializer(entity: entity, paths: [name], receipts: operationReceipts(library: base.libraryID))
    let accepted = try await commit(.init(base: base, changes: [
      .assign(field: "initialPath", value: .text(name)), .assign(field: "name", value: .text(name)), .assign(field: "parent", value: .unset)]), review: false, exact: true,
      preparedFileOperation: preparedFileOperation(base: base, steps: [.createDirectory(path: name)]))
    let operation = try SharedLibraryOperation(libraryID: accepted.libraryID, entity: entity,
      inputRevision: base.fingerprint, outputRevision: SharedLibraryOperation.revision(for: accepted.state), steps: [.createDirectory(path: name)])
    try await Task.detached { try await materializer.recordIntent(operation) }.value
    try Task.checkCancellation()
    guard try await materializer.replay(operation) == .complete else { throw SharedLibraryOperationError.unfinishedOperation }
  }
  public func relocateRecording(filename: String, title: String? = nil, toFolder: String? = nil,
                                changeFolder: Bool = false, reference: SharedRecordingReference? = nil,
                                destinationReference: SharedFolderReference? = nil,
                                beforeCommit: @escaping @Sendable () async throws -> Void = {},
                                afterMutation: @escaping @Sendable (Int) throws -> Void = { _ in }) async throws -> SharedRecordingFileOutcome {
    let source = try SharedLibraryIdentity.normalized(filename)
    let initial = try await recording(at: source)
    if let reference, reference.libraryID != initial.libraryID || reference.entityID != initial.state.id { throw SharedLibraryCoordinatorError.differentBinding }
    if destinationReference != nil && (!changeFolder || toFolder == nil) { throw SharedLibraryCoordinatorError.differentBinding }
    var target: SharedFolderReference?
    if changeFolder, let toFolder { target = try await relocationFolder(named: toFolder, reference: destinationReference).reference }
    return try await relocateRecordingAttempt(filename: source, title: title, toFolder: toFolder, changeFolder: changeFolder,
      beforeCommit: beforeCommit, afterMutation: afterMutation, initial: initial, destinationReference: target, retries: 2)
  }
  private func relocateRecordingAttempt(filename: String, title: String?, toFolder: String?, changeFolder: Bool,
      beforeCommit: @escaping @Sendable () async throws -> Void, afterMutation: @escaping @Sendable (Int) throws -> Void,
      initial: SharedLibraryViewSnapshot, destinationReference: SharedFolderReference?, retries: Int) async throws -> SharedRecordingFileOutcome {
    let source = filename
    let selected = try await read(.init(id: initial.state.id, kind: .recording))
    if title != nil, selected.state.fields["title"] != initial.state.fields["title"] { throw SharedLibraryCoordinatorError.staleReview }
    if changeFolder, selected.state.fields["folder"] != initial.state.fields["folder"] { throw SharedLibraryCoordinatorError.staleReview }
    let base = try await recording(at: source)
    guard base.libraryID == initial.libraryID, base.state.id == initial.state.id else { throw SharedLibraryCoordinatorError.differentBinding }
    if title != nil, base.state.fields["title"] != initial.state.fields["title"] { throw SharedLibraryCoordinatorError.staleReview }
    if changeFolder, base.state.fields["folder"] != initial.state.fields["folder"] { throw SharedLibraryCoordinatorError.staleReview }
    let entity = SharedEntityIdentity(id: base.state.id, kind: .recording)
    guard base.state.lifecycle == .alive, base.state.conflicts.isEmpty else { throw SharedSidecarError.conflictedContent }
    var ancestorBindings: [SharedMaterializationBinding] = []
    let sourceFolder = (source as NSString).deletingLastPathComponent
    if !sourceFolder.isEmpty && sourceFolder != "." {
      guard case .text(let text)? = base.state.value(for: "folder"), let id = UUID(uuidString: text) else { throw SharedLibraryPathError.unknownPath }
      let placement = try await relocationFolder(named: sourceFolder,
        reference: .init(libraryID: base.libraryID, entityID: id), acceptingChildren: false)
      for view in placement.chain { ancestorBindings += try repository.readBindings(view.repository, validateSourceSet: true) }
    }
    let receipts = try operationReceipts(library: base.libraryID)
    let reader = try await makeMaterializer(entity: entity, paths: [], receipts: receipts)
    try await discardCancelledDeletion(view: base, reader: reader)
    if let progress = try await reader.progress(entity: entity, libraryID: base.libraryID),
       progress.completedSteps < progress.operation.steps.count { throw SharedLibraryOperationError.unfinishedOperation }
    let basename = title ?? ((source as NSString).lastPathComponent as NSString).deletingPathExtension
    _ = try SharedLibraryIdentity.normalized(basename)
    guard !basename.contains("/") else { throw SharedLibraryIdentityError.invalidRelativePath }
    var folder = (source as NSString).deletingLastPathComponent
    var changes: [SharedLibraryMutation] = []
    var destinationBindings = ancestorBindings
    if let title { changes.append(.assign(field: "title", value: .text(title))) }
    if changeFolder {
      folder = toFolder ?? ""
      if let toFolder {
        let destination = try await relocationFolder(named: toFolder, reference: destinationReference)
        for view in destination.chain { destinationBindings += try repository.readBindings(view.repository, validateSourceSet: true) }
        changes.append(.assign(field: "folder", value: .text(destination.reference.entityID.uuidString)))
      } else { changes.append(.assign(field: "folder", value: .unset)) }
    }
    let destination = folder.isEmpty ? basename + ".mp3" : folder + "/" + basename + ".mp3"
    if source == destination { return .init(filename: source, result: .complete, projectionError: nil, view: base) }
    let all = try await snapshots(kinds: [.recording, .folder])
    let sensitive = (try? root.resourceValues(forKeys: [.volumeSupportsCaseSensitiveNamesKey]))?.volumeSupportsCaseSensitiveNames ?? false
    let index = try await pathIndex(for: all, caseSensitive: sensitive)
    guard index.owners(of: destination).isEmpty else { throw SharedLibraryOperationError.pathConflict(destination) }
    let sourceStem = (source as NSString).deletingPathExtension
    let destinationStem = (destination as NSString).deletingPathExtension
    let manifest = try await bind(force: true)
    let membership = try await memberRepository().load().membership
    let published = try await SharedPublishedLocations.load(root: root, manifest: manifest, membership: membership, afterLibraryRead: afterPublishedLibraryRead)
    var steps: [SharedLibraryOperation.Step] = []
    var sourceBindings = published.proofs.map { file, hash in
      SharedMaterializationBinding(file: file) { SharedLibraryOperation.fingerprint($0) == hash }
    } + destinationBindings
    for suffix in [".mp3", ".transcript.json", ".summary.json", ".txt", ".transcript.md", ".summary.md"] {
      let from = sourceStem + suffix, to = destinationStem + suffix
      let target = root.appendingPathComponent(to)
      guard !FileManager.default.fileExists(atPath: target.path),
            !FileManager.default.fileExists(atPath: target.deletingLastPathComponent().appendingPathComponent("." + target.lastPathComponent + ".icloud").path) else {
        throw SharedLibraryOperationError.pathConflict(to)
      }
      if let bytes = try await RecordingFileAccess().readDataIfPresent(at: root.appendingPathComponent(from), knownToExist: suffix == ".mp3") {
        if suffix.hasSuffix(".json") {
          try published.validateCompanion(path: from, bytes: bytes, entity: entity.id, library: base.libraryID,
              kind: suffix == ".transcript.json" ? "transcript" : "summary")
        }
        let hash = SharedLibraryOperation.fingerprint(bytes)
        sourceBindings.append(.init(file: root.appendingPathComponent(from)) { SharedLibraryOperation.fingerprint($0) == hash })
        steps.append(.move(source: from, destination: to, fingerprint: hash))
      } else if suffix == ".mp3" { throw CocoaError(.fileReadNoSuchFile) }
    }
    // Ancestor source-set proofs share the format item. Coordinate it once,
    // while retaining every entity/source-set validator on that item.
    sourceBindings = Dictionary(grouping: sourceBindings, by: \.file).map { file, proofs in
      SharedMaterializationBinding(file: file) { bytes in try proofs.allSatisfy { try $0.validate(bytes) } }
    }.sorted { $0.file.path < $1.file.path }
    try await beforeCommit()
    // Accept the logical intent before touching any source. Receipt replay,
    // ownership and expected bytes make each related physical phase recoverable.
    let paths = steps.flatMap { step -> [String] in
      if case .move(let source, let destination, _) = step { return [source, destination] }
      return []
    }
    let materializer = try await makeMaterializer(entity: entity, paths: paths,
      receipts: receipts, afterMutation: afterMutation)
    let accepted: SharedLibraryViewSnapshot
    do { accepted = try await commit(.init(base: base, changes: changes), review: false, exact: true, bindings: sourceBindings, preparedFileOperation: preparedFileOperation(base: base, steps: steps)) }
    catch {
      let changed = error as? SharedLibraryRepositoryError == .staleRevision || error as? SharedLibraryCoordinatorError == .staleReview || error as? SharedLibraryOperationError == .staleAuthority
      guard retries > 0, changed, !Task.isCancelled else { throw error }
      return try await relocateRecordingAttempt(filename: source, title: title, toFolder: toFolder, changeFolder: changeFolder,
        beforeCommit: beforeCommit, afterMutation: afterMutation, initial: initial, destinationReference: destinationReference, retries: retries - 1)
    }
    let operation = try SharedLibraryOperation(libraryID: accepted.libraryID, entity: entity,
      inputRevision: base.fingerprint, outputRevision: SharedLibraryOperation.revision(for: accepted.state), steps: steps)
    try await Task.detached { try await materializer.recordIntent(operation) }.value
    try Task.checkCancellation()
    let result = try await materializer.replay(operation)
    var projectionError: String?
    if result == .complete {
      do { _ = try await projectOutputs() } catch { projectionError = error.localizedDescription }
    }
    return .init(filename: result == .complete ? destination : source, result: result, projectionError: projectionError, view: accepted)
  }

  private func relocationFolder(named name: String, reference: SharedFolderReference?, acceptingChildren: Bool = true) async throws
    -> (reference: SharedFolderReference, chain: [SharedLibraryViewSnapshot]) {
    _ = try SharedLibraryIdentity.normalized(name)
    let views = try await snapshots(kinds: [.folder])
    let sensitive = (try? root.resourceValues(forKeys: [.volumeSupportsCaseSensitiveNamesKey]))?.volumeSupportsCaseSensitiveNames ?? false
    let index = try await pathIndex(for: views, caseSensitive: sensitive)
    let matches = views.filter { index.resolvedPaths[$0.state.id] == name && $0.state.lifecycle == .alive }
    guard matches.count == 1, let destination = matches.first else { throw SharedLibraryPathError.unknownPath }
    if let reference, reference.libraryID != destination.libraryID || reference.entityID != destination.state.id { throw SharedLibraryCoordinatorError.differentBinding }
    guard index.owners(of: name) == [destination.state.id] else { throw SharedLibraryPathError.ambiguousPath }
    var chain: [SharedLibraryViewSnapshot] = [], current = destination, visited: Set<UUID> = []
    while true {
      guard visited.insert(current.state.id).inserted, current.state.lifecycle == .alive, current.state.conflicts.isEmpty else { throw SharedSidecarError.conflictedContent }
      if acceptingChildren, current.state.value(for: "deletionRequest") != nil { throw SharedLibraryOperationError.unfinishedOperation }
      if case .text(let physical)? = current.state.value(for: "physicalPath"), physical != index.resolvedPaths[current.state.id] { throw SharedLibraryOperationError.unfinishedOperation }
      chain.append(current)
      if current.state.fields["parent"]?.resolvedValue == .unset { break }
      guard case .text(let text)? = current.state.value(for: "parent"), let id = UUID(uuidString: text),
            let parent = views.first(where: { $0.state.id == id }) else { throw SharedLibraryPathError.unknownPath }
      current = parent
    }
    return (.init(libraryID: destination.libraryID, entityID: destination.state.id), chain)
  }

  private func folderReviewBindings(_ base: SharedLibraryViewSnapshot?, excluding entity: SharedEntityIdentity) throws -> [SharedMaterializationBinding] {
    guard let base else { return [] }
    if base.state.id == entity.id && entity.kind == .folder { return [] }
    guard base.state.kind == .folder, base.libraryID == manifest?.libraryID, repository.accepts(base.repository) else { throw SharedLibraryCoordinatorError.differentBinding }
    return try repository.readBindings(base.repository, validateSourceSet: true)
  }

  public func deleteSharedRecording(filename: String, reference: SharedRecordingReference? = nil) async throws -> SharedRecordingFileOutcome {
    try await deleteRecording(filename: filename, reference: reference)
  }
  /// Continue cleanup only for the exact semantic deletion the caller just
  /// reviewed. Accepted lifecycle state and physical completion remain distinct.
  public func prepareReviewedDeletion(_ base: SharedLibraryViewSnapshot) async throws -> SharedRecordingFileOutcome {
    guard base.state.kind == .recording, base.state.lifecycle == .deleted,
          base.state.conflicts.isEmpty else { throw SharedLibraryOperationError.invalidOperation }
    return try await deleteRecording(filename: currentPath(base), reference: .init(libraryID: base.libraryID, entityID: base.state.id), reviewed: base)
  }
  private func deleteRecording(filename: String, reference: SharedRecordingReference?, reviewed: SharedLibraryViewSnapshot? = nil,
                               expectedMember: FolderDeletionMember? = nil,
                               reviewedFolder: SharedLibraryViewSnapshot? = nil, expectedCohort: String? = nil) async throws -> SharedRecordingFileOutcome {
    let source: String, base: SharedLibraryViewSnapshot
    if let member = expectedMember {
      guard let reference, member.kind == .recording, reference.entityID == member.id else { throw SharedLibraryCoordinatorError.differentBinding }
      base = try await read(.init(id: member.id, kind: .recording))
      source = try await currentPath(base)
      guard source == member.path, base.state.lifecycle == .deleted || base.fingerprint == member.revision else { throw SharedLibraryCoordinatorError.staleReview }
    } else {
      if let reviewed { source = try await currentPath(reviewed) }
      else if let reference { source = try await resolve(reference) }
      else { source = try SharedLibraryIdentity.normalized(filename) }
      base = try await recording(at: source)
    }
    if let reference, reference.libraryID != base.libraryID || reference.entityID != base.state.id { throw SharedLibraryCoordinatorError.differentBinding }
    let entity = SharedEntityIdentity(id: base.state.id, kind: .recording)
    if let reviewed {
      guard reviewed.libraryID == base.libraryID, repository.accepts(reviewed.repository),
            reviewed.state == base.state else { throw SharedLibraryCoordinatorError.staleReview }
    }
    guard base.state.conflicts.isEmpty else { throw SharedSidecarError.conflictedContent }
    if base.state.lifecycle == .deleted, case .document = base.state.value(for: fileIntentField) {
      return try await resumeRecordingOperation(id: entity.id, expectedCohort: expectedCohort, reviewedFolder: reviewedFolder)
    }
    let receipts = try operationReceipts(library: base.libraryID)
    let reader = try await makeMaterializer(entity: entity, paths: [], receipts: receipts, expectedCohort: expectedCohort, reviewedFolder: reviewedFolder)
    try await discardCancelledDeletion(view: base, reader: reader)
    // Reuse an exact accepted peer deletion without rewriting lifecycle or
    // renewing its hashes. A competing intent would revoke cohort approvals.
    if try currentDeletionIntentOwner(in: base) != nil {
      return try await resumeRecordingOperation(id: entity.id, expectedCohort: expectedCohort, reviewedFolder: reviewedFolder)
    }
    if let progress = try await reader.progress(entity: entity, libraryID: base.libraryID),
       progress.completedSteps < progress.operation.steps.count {
      if progress.operation.steps.allSatisfy({ if case .trash = $0 { return true }; return false }) {
        return try await resumeRecordingOperation(id: entity.id, expectedCohort: expectedCohort, reviewedFolder: reviewedFolder)
      }
      throw SharedLibraryOperationError.unfinishedOperation
    }
    let manifest = try await bind(force: true)
    let membership = try await memberRepository().load().membership
    let published = try await SharedPublishedLocations.load(root: root, manifest: manifest, membership: membership, afterLibraryRead: afterPublishedLibraryRead)
    let stem = (source as NSString).deletingPathExtension
    var steps: [SharedLibraryOperation.Step] = []
    for suffix in [".mp3", ".transcript.json", ".summary.json", ".txt", ".transcript.md", ".summary.md"] {
      let path = stem + suffix
      if let bytes = try await RecordingFileAccess().readDataIfPresent(at: root.appendingPathComponent(path), knownToExist: suffix == ".mp3") {
        if suffix.hasSuffix(".json") {
          try published.validateCompanion(path: path, bytes: bytes, entity: entity.id, library: base.libraryID,
              kind: suffix == ".transcript.json" ? "transcript" : "summary")
        }
        steps.append(.trash(path: path, fingerprint: SharedLibraryOperation.fingerprint(bytes)))
      } else if suffix == ".mp3" { throw CocoaError(.fileReadNoSuchFile) }
    }
    let paths = steps.compactMap { step -> String? in
      if case .trash(let path, _) = step { return path }
      return nil
    }
    let materializer = try await makeMaterializer(entity: entity, paths: paths, receipts: receipts, expectedCohort: expectedCohort, reviewedFolder: reviewedFolder)
    let accepted = try await commit(.init(base: base, changes: [.delete]), review: false, exact: true, bindings: folderReviewBindings(reviewedFolder, excluding: entity),
      preparedFileOperation: preparedFileOperation(base: base, steps: steps))
    let operation = try SharedLibraryOperation(libraryID: accepted.libraryID, entity: entity,
      inputRevision: base.fingerprint, outputRevision: SharedLibraryOperation.revision(for: accepted.state), steps: steps)
    try await Task.detached { try await materializer.recordIntent(operation) }.value
    try Task.checkCancellation()
    let permission = try await operationAuthority(entity: entity, paths: Array(operation.canonicalPaths), reviewedFolder: reviewedFolder, expectedCohort: expectedCohort)
    if !permission.hasPendingWork { try await acknowledgeOperation(entity: entity, purpose: .delete, expectedRevision: operation.outputRevision, expectedCohort: expectedCohort, reviewedFolder: reviewedFolder) }
    let result = try await materializer.replay(operation)
    var projectionError: String?
    if result == .complete { do { _ = try await projectOutputs() } catch { projectionError = error.localizedDescription } }
    return .init(filename: source, result: result, projectionError: projectionError, view: accepted)
  }
  public func acknowledgeOperation(entity: SharedEntityIdentity, purpose: SharedDestructivePurpose, expectedRevision: String? = nil, expectedCohort: String? = nil,
                                   reviewedFolder: SharedLibraryViewSnapshot? = nil) async throws {
    let manifest = try await bind(force: true)
    guard let directory = witnessDirectory, let gate else { throw SharedLibraryOperationError.invalidOperation }
    let witness = SharedOwnerWitness(directory: directory, libraryID: manifest.libraryID, writerID: writerID)
    _ = try await SharedOperationAcknowledgmentStore(root: root, libraryID: manifest.libraryID, writer: writerID, witness: witness, gate: gate)
      .acknowledge(purpose: purpose, authority: {
        let permission = try await self.operationAuthority(entity: entity, paths: [], reviewedFolder: reviewedFolder, expectedCohort: expectedCohort)
        if let expectedCohort, permission.membership.fingerprint != expectedCohort { throw SharedLibraryOperationError.staleAuthority }
        if let expectedRevision, try !SharedLibraryOperation.matchesRevision(expectedRevision, state: permission.state) {
          throw SharedLibraryOperationError.staleAuthority
        }
        return permission
      })
    revokeAuthority()
  }

  public func reviewRecordingOperation(id: UUID) async throws -> SharedRecordingOperationReview? {
    let entity = SharedEntityIdentity(id: id, kind: .recording)
    let view = try await read(entity)
    let reader = try await makeMaterializer(entity: entity, paths: [], receipts: operationReceipts(library: view.libraryID))
    let fileGuardMatches = try await recoverFileIntent(view: view, reader: reader)
    var progress = try await reader.progress(entity: entity, libraryID: view.libraryID)
    if case .document = view.state.value(for: audioIntentField), progress == nil || progress?.completedSteps == progress?.operation.steps.count {
      try await reconstructAudioIntent(view: view, materializer: reader)
      progress = try await reader.progress(entity: entity, libraryID: view.libraryID)
    }
    if let progress, try await mirroredRecordingRemovalIsPresent(view: view, progress: progress) { return nil }
    var survivingAliases: [String] = []
    var retainedPaths: [String] = []
    if let progress, progress.completedSteps == progress.operation.steps.count {
      guard progress.operation.steps.allSatisfy({ if case .move = $0 { return true }; return false }),
            case .document(let document)? = view.state.value(for: fileIntentField) else { return nil }
      let manifest = try await bind(force: true)
      let membership = try await memberRepository().load().membership
      let published = try await SharedPublishedLocations.load(root: root, manifest: manifest, membership: membership, afterLibraryRead: afterPublishedLibraryRead)
      if published.completedFileIntents[id]?[writerID.uuidString.lowercased()] == SharedLibraryOperation.fingerprint(document.json) { return nil }
      let destination = try await currentPath(view)
      let locations = try published.reservations(states: [view.state], library: view.libraryID)
      for source in locations[id] ?? [] where source != destination {
        let stem = (source as NSString).deletingPathExtension
        for suffix in [".mp3", ".transcript.json", ".summary.json", ".txt", ".transcript.md", ".summary.md"] {
          let path = stem + suffix
          let url = root.appendingPathComponent(path)
          let placeholder = url.deletingLastPathComponent().appendingPathComponent("." + url.lastPathComponent + ".icloud")
          if FileManager.default.fileExists(atPath: url.path) || FileManager.default.fileExists(atPath: placeholder.path) { survivingAliases.append(path) }
        }
      }
    }
    if case .document(let document)? = view.state.value(for: fileIntentField) {
      let intent = try JSONDecoder().decode(SharedAcceptedFileIntent.self, from: document.json)
      retainedPaths = intent.retainedFiles.map { Array($0.keys) } ?? []
    }
    var operation = progress?.operation
    var planGuardMatches = fileGuardMatches
    if operation == nil {
      for (field, register) in view.state.fields.sorted(by: { $0.key < $1.key }) where field.hasPrefix("materialization.files.") {
        guard let owner = UUID(uuidString: String(field.dropFirst("materialization.files.".count))),
              owner == writerID || view.state.lifecycle == .deleted,
              case .document(let document)? = register.resolvedValue else { continue }
        let intent = try JSONDecoder().decode(SharedAcceptedFileIntent.self, from: document.json)
        guard intent.schema == 1, intent.libraryID == view.libraryID, intent.entity == entity,
              !intent.steps.isEmpty, intent.steps.allSatisfy({ switch $0 { case .move, .trash: return true; default: return false } }) else { throw SharedLibraryOperationError.invalidReceipt }
        planGuardMatches = try view.state.fileIntentGuardRevision(writer: owner) == intent.guardRevision
        operation = try .init(libraryID: view.libraryID, entity: entity, inputRevision: intent.inputRevision,
          outputRevision: SharedLibraryOperation.revision(for: view.state), steps: intent.steps)
        break
      }
    }
    if view.state.lifecycle == .alive, progress == nil,
       operation?.steps.allSatisfy({ if case .trash = $0 { return true }; return false }) == true { return nil }
    guard let operation else { return nil }
    let permission = try await operationAuthority(entity: entity, paths: [])
    guard try SharedLibraryOperation.matchesRevision(SharedLibraryOperation.revision(for: view.state), state: permission.state) else {
      throw SharedLibraryOperationError.staleAuthority
    }
    let purpose: SharedDestructivePurpose? = operation.steps.contains(where: { if case .trash = $0 { return true }; return false }) ? .delete
      : operation.steps.contains(where: { if case .replaceAudio(_, _, _, _, false) = $0 { return true }; return false }) ? .replaceAudio : nil
    if progress == nil, purpose == .delete, planGuardMatches, view.state.conflicts.isEmpty {
      let removal = try await operationAuthority(entity: entity, paths: Array(operation.canonicalPaths))
      if try await acknowledgedRemovalIsPresent(paths: Array(operation.canonicalPaths), permission: removal) { return nil }
    }
    let revisionMatches = try SharedLibraryOperation.matchesRevision(operation.outputRevision, state: view.state)
    let needsReplanning = !planGuardMatches || !view.state.conflicts.isEmpty || !revisionMatches || !survivingAliases.isEmpty
    let approved = purpose.map { permission.approvedWriters(for: $0) } ?? []
    let stable = permission.membership.pendingWriters.isEmpty && !permission.membership.hasConcurrentEnrollment
    let canAcknowledge = purpose != nil && !needsReplanning && !permission.hasPendingWork && !permission.hasLiveDescendants && stable && !approved.contains(writerID)
    let waiting = purpose == nil ? [] : permission.membership.cohort.subtracting(approved).map { $0 == writerID ? "This Mac" : permission.membership.label(for: $0) }.sorted()
    let name = view.state.value(for: "title").flatMap { if case .text(let name) = $0 { return name }; return nil } ?? "Recording"
    return .init(title: name, paths: Set(Array(operation.canonicalPaths) + retainedPaths).sorted(), completedSteps: progress?.completedSteps ?? 0,
      totalSteps: operation.steps.count, needsReplanning: needsReplanning, hasActiveWork: permission.hasPendingWork, waitingForMacs: waiting,
      canResume: progress != nil && !needsReplanning && !permission.hasPendingWork && (purpose.map { permission.mayDestroy($0) } ?? true),
      canAcknowledge: canAcknowledge, base: view, operation: operation, cohort: permission.membership.fingerprint,
      isLocal: progress != nil, purpose: purpose)
  }
  private func validateFileReview(_ review: SharedRecordingOperationReview) async throws {
    let current = try await read(.init(id: review.id, kind: .recording))
    guard current.libraryID == review.base.libraryID, repository.accepts(review.base.repository) else { throw SharedLibraryCoordinatorError.differentBinding }
    guard current.fingerprint == review.base.fingerprint else { throw SharedLibraryCoordinatorError.staleReview }
    guard try await memberRepository().load().membership.fingerprint == review.cohort else { throw SharedLibraryOperationError.staleAuthority }
  }
  public func prepareRecordingReplan(_ review: SharedRecordingOperationReview) async throws -> SharedRecordingReplanReview {
    try await validateFileReview(review)
    guard review.base.state.conflicts.isEmpty else { throw SharedLibraryOperationError.invalidOperation }
    if review.base.state.lifecycle == .deleted, review.operation.steps.allSatisfy({ if case .trash = $0 { return true }; return false }) {
      return try await prepareDeletionReplan(review)
    }
    guard review.isLocal, review.base.state.lifecycle == .alive,
          review.operation.steps.allSatisfy({ if case .move = $0 { return true }; return false }) else { throw SharedLibraryOperationError.invalidOperation }
    let destination = try await currentPath(review.base)
    let stem = (destination as NSString).deletingPathExtension
    var retained: [String: String] = [:]
    if case .document(let document)? = review.base.state.value(for: fileIntentField) {
      let intent = try JSONDecoder().decode(SharedAcceptedFileIntent.self, from: document.json)
      retained = intent.retainedFiles ?? [:]
    }
    for step in review.operation.steps {
      guard case .move(let source, let target, let hash) = step else { throw SharedLibraryOperationError.invalidOperation }
      for path in [source, target] {
        if let known = retained[path], known != hash { throw SharedLibraryOperationError.invalidReceipt }
        retained[path] = hash
      }
    }
    let suffixes = [".mp3", ".transcript.json", ".summary.json", ".txt", ".transcript.md", ".summary.md"]
    var witnesses: [SharedFilePathWitness] = [], steps: [SharedLibraryOperation.Step] = [], existingTargets: [String] = [], sources: [String] = []
    for suffix in suffixes {
      let candidates = retained.keys.filter { $0.hasSuffix(suffix) }.sorted()
      guard !candidates.isEmpty else { continue }
      let target = stem + suffix
      let hashes = Set(candidates.compactMap { retained[$0] })
      guard hashes.count == 1, let expected = hashes.first else { throw SharedLibraryOperationError.invalidReceipt }
      var present: [String] = []
      for path in Set(candidates + [target]).sorted() {
        let bytes = try await RecordingFileAccess().readDataIfPresent(at: root.appendingPathComponent(path))
        let actual = bytes.map(SharedLibraryOperation.fingerprint)
        witnesses.append(.init(path: path, fingerprint: actual))
        if let actual {
          guard candidates.contains(path) else { throw SharedLibraryOperationError.pathConflict(path) }
          guard actual == expected else { throw SharedLibraryOperationError.contentChanged(path) }
          present.append(path)
        }
      }
      guard !present.isEmpty else { throw CocoaError(.fileReadNoSuchFile) }
      if present.contains(target) { existingTargets.append(target) }
      let moving = present.filter { $0 != target }
      sources += present
      if moving.isEmpty {
        // A previous accepted phase already put this file at the selected path.
        guard let absentSource = candidates.first(where: { $0 != target }) else { throw SharedLibraryOperationError.invalidOperation }
        steps.append(.move(source: absentSource, destination: target, fingerprint: expected))
      } else { for source in moving { steps.append(.move(source: source, destination: target, fingerprint: expected)) } }
    }
    guard steps.contains(where: { if case .move(_, let target, _) = $0 { return target == destination }; return false }) else { throw SharedLibraryOperationError.invalidOperation }
    _ = try await operationAuthority(entity: review.operation.entity, paths: Array(Set(steps.flatMap { step -> [String] in if case .move(let source, let target, _) = step { return [source, target] }; return [] })))
    try await validateFileReview(review)
    return .init(destination: destination, sources: Array(Set(sources)).sorted(), original: review, steps: steps,
      witnesses: witnesses, retainedFiles: retained, reviewedExistingDestinations: existingTargets.sorted())
  }
  private func prepareDeletionReplan(_ review: SharedRecordingOperationReview) async throws -> SharedRecordingReplanReview {
    let reader = try await makeMaterializer(entity: review.operation.entity, paths: [], receipts: operationReceipts(library: review.base.libraryID))
    let progress = try await reader.progress(entity: review.operation.entity, libraryID: review.base.libraryID)
    guard progress.map({ $0.operation == review.operation }) ?? !review.isLocal else { throw SharedLibraryCoordinatorError.staleReview }
    var witnesses: [SharedFilePathWitness] = [], sources: [String] = [], retained: [String: String] = [:]
    for (index, step) in review.operation.steps.enumerated() {
      guard case .trash(let path, let hash) = step else { throw SharedLibraryOperationError.invalidOperation }
      let bytes = try await RecordingFileAccess().readDataIfPresent(at: root.appendingPathComponent(path))
      let actual = bytes.map(SharedLibraryOperation.fingerprint)
      if let actual {
        guard index >= (progress?.completedSteps ?? 0), actual == hash else { throw SharedLibraryOperationError.contentChanged(path) }
        sources.append(path)
      } else {
        guard let progress, index < progress.completedSteps || (index == progress.completedSteps && progress.phaseWasAttempted) else { throw CocoaError(.fileReadNoSuchFile) }
      }
      retained[path] = hash; witnesses.append(.init(path: path, fingerprint: actual))
    }
    _ = try await operationAuthority(entity: review.operation.entity, paths: Array(retained.keys))
    try await validateFileReview(review)
    return .init(destination: try await currentPath(review.base), sources: sources, original: review,
      steps: review.operation.steps, witnesses: witnesses, retainedFiles: retained, reviewedExistingDestinations: [])
  }

  public func applyRecordingReplan(_ prepared: SharedRecordingReplanReview,
      beforeCommit: @escaping @Sendable () async throws -> Void = {}) async throws -> SharedRecordingFileOutcome {
    let review = prepared.original
    try await validateFileReview(review)
    guard try await currentPath(review.base) == prepared.destination else { throw SharedLibraryCoordinatorError.staleReview }
    let receipts = try operationReceipts(library: review.base.libraryID)
    let reader = try await makeMaterializer(entity: review.operation.entity, paths: [], receipts: receipts)
    let progress = try await reader.progress(entity: review.operation.entity, libraryID: review.base.libraryID)
    guard progress.map({ $0.operation == review.operation }) ?? (!review.isLocal && prepared.isDeletion) else { throw SharedLibraryCoordinatorError.staleReview }
    let paths = Array(Set(prepared.steps.flatMap { step -> [String] in
      switch step { case .move(let source, let target, _): return [source, target]; case .trash(let path, _): return [path]; default: return [] }
    }))
    let permission = try await operationAuthority(entity: review.operation.entity, paths: paths)
    guard permission.membership.fingerprint == review.cohort, !permission.hasPendingWork else { throw SharedLibraryOperationError.staleAuthority }
    guard try await currentPath(review.base) == prepared.destination else { throw SharedLibraryCoordinatorError.staleReview }
    var bindings = permission.additionalBindings + (permission.binding.map { [$0] } ?? [])
    for witness in prepared.witnesses {
      if let expected = witness.fingerprint { bindings.append(.init(file: root.appendingPathComponent(witness.path)) { SharedLibraryOperation.fingerprint($0) == expected }) }
    }
    let root = self.root
    let absent = prepared.witnesses.filter { $0.fingerprint == nil }.map(\.path)
    let validate: @Sendable () throws -> Void = {
      for path in absent {
        let url = root.appendingPathComponent(path)
        let placeholder = url.deletingLastPathComponent().appendingPathComponent("." + url.lastPathComponent + ".icloud")
        guard !FileManager.default.fileExists(atPath: url.path), !FileManager.default.fileExists(atPath: placeholder.path) else { throw SharedLibraryOperationError.contentChanged(path) }
      }
    }
    try await beforeCommit(); try Task.checkCancellation()
    var plan = SharedPreparedFileOperation(libraryID: review.base.libraryID, entity: review.operation.entity,
      inputRevision: review.operation.outputRevision, steps: prepared.steps)
    plan.replacesOperationID = review.isLocal ? review.operation.id : nil
    plan.retainedFiles = prepared.retainedFiles
    plan.reviewedExistingDestinations = prepared.reviewedExistingDestinations
    _ = try await commit(.init(base: review.base, changes: []), review: true, exact: true, bindings: bindings,
      preparedFileOperation: plan, additionalValidation: validate)
    try Task.checkCancellation()
    return try await resumeRecordingOperation(id: review.id, expectedCohort: review.cohort)
  }

  public func resumeReviewedRecordingOperation(_ review: SharedRecordingOperationReview) async throws -> SharedRecordingFileOutcome {
    try await validateFileReview(review)
    guard review.canResume, review.isLocal else { throw SharedLibraryOperationError.invalidOperation }
    let reader = try await makeMaterializer(entity: review.operation.entity, paths: [], receipts: operationReceipts(library: review.base.libraryID))
    guard try await reader.progress(entity: review.operation.entity, libraryID: review.base.libraryID)?.operation == review.operation else { throw SharedLibraryCoordinatorError.staleReview }
    return try await resumeRecordingOperation(id: review.id, expectedCohort: review.cohort)
  }
  public func acknowledgeReviewedRecordingOperation(_ review: SharedRecordingOperationReview) async throws {
    try await validateFileReview(review)
    guard review.canAcknowledge, let purpose = review.purpose else { throw SharedLibraryOperationError.invalidOperation }
    try await acknowledgeOperation(entity: review.operation.entity, purpose: purpose,
      expectedRevision: SharedLibraryOperation.revision(for: review.base.state), expectedCohort: review.cohort)
  }

  /// Resume the exact locally recorded physical plan; never infer completion
  /// from a new filename or recreate an audio original after an interruption.
  public func resumeRecordingOperation(id: UUID, expectedCohort: String? = nil, reviewedFolder: SharedLibraryViewSnapshot? = nil) async throws -> SharedRecordingFileOutcome {
    let entity = SharedEntityIdentity(id: id, kind: .recording)
    var view = try await read(entity)
    let receipts = try operationReceipts(library: view.libraryID)
    let reader = try await makeMaterializer(entity: entity, paths: [], receipts: receipts, expectedCohort: expectedCohort, reviewedFolder: reviewedFolder)
    if try await !recoverFileIntent(view: view, reader: reader) {
      return .init(filename: "", result: .needsReplanning, projectionError: nil, view: view)
    }
    let previous = try await reader.progress(entity: entity, libraryID: view.libraryID)
    if case .document = view.state.value(for: audioIntentField) {
      let intent = try preparedAudioIntent(view: view)
      if previous?.operation.steps != [intent.step] || previous?.operation.inputRevision != intent.inputRevision ||
         previous?.operation.inputAudioFingerprint != intent.inputAudioFingerprint {
        // An older completed receipt is only progress for its old intent.
        // recordIntent still refuses to supersede an unfinished physical plan.
        try await reconstructAudioIntent(view: view, materializer: reader)
      }
    } else if previous == nil {
      if view.state.lifecycle == .alive, case .document(let document)? = view.state.value(for: fileIntentField),
         let intent = try? JSONDecoder().decode(SharedAcceptedFileIntent.self, from: document.json),
         intent.steps.allSatisfy({ if case .trash = $0 { return true }; return false }) {
        return .init(filename: try await currentPath(view), result: .needsReplanning, projectionError: nil, view: view)
      }
      throw SharedLibraryOperationError.invalidOperation
    }
    guard let progress = try await reader.progress(entity: entity, libraryID: view.libraryID),
          let audio = progress.operation.steps.first(where: {
            switch $0 {
            case .move(let path, _, _), .trash(let path, _), .publishAudio(let path, _, _), .replaceAudio(let path, _, _, _, _): return path.hasSuffix(".mp3")
            default: return false
            }
          }) else { throw SharedLibraryOperationError.invalidOperation }
    let source: String, destination: String, selected: String?
    switch audio {
    case .move(let from, let to, _): source = from; destination = to; selected = nil
    case .trash(let path, _): source = path; destination = path; selected = nil
    case .publishAudio(let path, _, let hash), .replaceAudio(let path, _, _, let hash, _): source = path; destination = path; selected = hash
    default: throw SharedLibraryOperationError.invalidOperation
    }
    if try await mirroredRecordingRemovalIsPresent(view: view, progress: progress, expectedCohort: expectedCohort, reviewedFolder: reviewedFolder) {
      return .init(filename: destination, result: .complete, projectionError: nil, view: view)
    }
    var result: SharedMaterializationResult
    if progress.completedSteps == progress.operation.steps.count {
      if try !SharedLibraryOperation.matchesRevision(progress.operation.outputRevision, state: view.state) {
        guard let selected, view.state.lifecycle == .alive, view.state.conflicts.isEmpty,
              view.state.value(for: "audioFingerprint") == .text(selected), view.state.value(for: "audioPublished") == .text(selected) else {
          return .init(filename: destination, result: .needsReplanning, projectionError: nil, view: view)
        }
      }
      if let selected {
        guard let data = try await RecordingFileAccess().readDataIfPresent(at: root.appendingPathComponent(destination), knownToExist: true),
              SharedLibraryOperation.fingerprint(data) == selected else { throw SharedLibraryOperationError.contentChanged(destination) }
      }
      result = .complete
    } else {
      let permission = try await operationAuthority(entity: entity, paths: [], reviewedFolder: reviewedFolder, expectedCohort: expectedCohort)
      if !permission.hasPendingWork && view.state.conflicts.isEmpty {
        switch audio {
        case .trash where view.state.lifecycle == .deleted: try await acknowledgeOperation(entity: entity, purpose: .delete, expectedRevision: progress.operation.outputRevision, expectedCohort: expectedCohort, reviewedFolder: reviewedFolder)
        case .replaceAudio(_, _, _, _, false) where view.state.lifecycle == .alive: try await acknowledgeOperation(entity: entity, purpose: .replaceAudio, expectedRevision: progress.operation.outputRevision, expectedCohort: expectedCohort, reviewedFolder: reviewedFolder)
        default: break
        }
      }
      let materializer = try await makeMaterializer(entity: entity, paths: Array(progress.operation.canonicalPaths), receipts: receipts, expectedCohort: expectedCohort, reviewedFolder: reviewedFolder)
      result = try await materializer.replay(progress.operation)
    }
    var projectionError: String?
    if result == .complete {
      if let selected, view.state.value(for: "audioPublished") != .text(selected) {
        view = try await markAudioPublished(entity: entity, selected: selected)
      }
      do { _ = try await projectOutputs() } catch { projectionError = error.localizedDescription }
    }
    return .init(filename: result == .complete ? destination : source, result: result, projectionError: projectionError, view: view)
  }

  /// Ordinary publication can rebuild a stale proof after a brief refresh.
  /// Explicit preparation/mutation hooks retain one-shot rejection semantics.
  private static var projectionRetryDelays: [Duration] { [.milliseconds(25), .milliseconds(100), .milliseconds(400), .milliseconds(800)] }
  public func projectOutputs() async throws -> SharedProjectionWriteResult {
    let delays = Self.projectionRetryDelays
    for attempt in 0...delays.count {
      do { return try await projectOutputs(beforeWrite: {}, afterOutput: { _ in }) }
      catch SharedProjectionWriteError.stale {
        guard attempt < delays.count else { throw SharedProjectionWriteError.stale }
        try await Task.sleep(for: delays[attempt])
      }
    }
    throw SharedProjectionWriteError.stale
  }
  public func projectOutputs(beforeWrite: @escaping @Sendable () async -> Void = {},
                             beforeOutput: @escaping @Sendable (Int) throws -> Void = { _ in },
                             afterOutput: @escaping @Sendable (Int) throws -> Void = { _ in }) async throws -> SharedProjectionWriteResult {
    let context = try await projectionContext()
    return try await SharedLibraryProjectionWriter.project(context, writer: writerID, beforeWrite: beforeWrite, beforeOutput: beforeOutput, afterOutput: afterOutput)
  }
  /// Publish one content component and its readable exports. Authority and
  /// namespace proofs remain library-wide; unrelated canonical output bytes
  /// are neither hydrated nor included in this physical access request.
  public func projectOutputs(for entity: SharedEntityIdentity, component: SharedComponent) async throws -> SharedProjectionWriteResult {
    let delays = Self.projectionRetryDelays
    for attempt in 0...delays.count {
      do {
        let context = try await projectionContext(for: entity)
        guard entity.kind == .recording, context.views.contains(where: { $0.state.id == entity.id && $0.state.kind == entity.kind && $0.state.lifecycle == .alive }) else { throw SharedSidecarError.conflictedContent }
        let outputs = try SharedLibraryProjectionWriter.render(context)
        let json = try outputs.compactMap { path, bytes -> String? in
          guard path.hasSuffix("." + component.rawValue + ".json"),
            let marker = try SharedProjectionDocument.marker(in: bytes),
            marker.libraryID == context.manifest.libraryID, marker.entities == [entity.id], marker.kind == component.rawValue else { return nil }
          return path
        }
        guard json.count == 1, let path = json.first else { throw SharedSidecarError.invalidContent }
        let stem = String(path.dropLast(("." + component.rawValue + ".json").count))
        var paths: Set<String> = [path, stem + "." + component.rawValue + ".md"]
        if component == .transcript { paths.insert(stem + ".txt") }
        return try await SharedLibraryProjectionWriter.project(context, writer: writerID, only: paths)
      } catch SharedProjectionWriteError.stale {
        guard attempt < delays.count else { throw SharedProjectionWriteError.stale }
        try await Task.sleep(for: delays[attempt])
      }
    }
    throw SharedProjectionWriteError.stale
  }
  public func reviewBootstrapProjections() async throws -> [SharedBootstrapProjectionReview] {
    let manifest = try await bind(force: true)
    let inputs = try JSONDecoder().decode(SharedProjectionInputs.self,
      from: await CoordinatedFileAccess().read(at: SharedProjectionInputs.file(in: root)))
    try inputs.validate(manifest: manifest)
    var candidates: [String: Data] = [:]
    for path in [".templates.json", "library.json"] {
      if let bytes = try await RecordingFileAccess().readDataIfPresent(at: root.appendingPathComponent(path)),
        inputs.files[path] == SharedLibraryOperation.fingerprint(bytes) { candidates[path] = bytes }
    }
    // Ordinary marked outputs cannot be bootstrap recovery candidates. Reading
    // them must not acquire mutation authority or fail during another edit.
    guard !candidates.isEmpty else {
      try Task.checkCancellation(); bootstrapReviewTickets.removeAll(); return []
    }
    let context = try await projectionContext()
    let outputs = try SharedLibraryProjectionWriter.render(context)
    let directory = root.appendingPathComponent(".docktape/projections")
    var consumed: Set<String> = []
    for file in LibraryFileDiscovery.files(in: directory, suffix: ".json") {
      let registry = try JSONDecoder().decode(SharedProjectionRegistry.self,
        from: await CoordinatedFileAccess().read(at: directory.appendingPathComponent(file.relativePath)))
      try registry.validate(library: context.manifest.libraryID, writers: context.membership.cohort)
      consumed.formUnion(registry.files.keys); consumed.formUnion((registry.attempted ?? [:]).keys)
    }
    var result: [SharedBootstrapProjectionReview] = []
    for path in [".templates.json", "library.json"] where consumed.contains(path) {
      guard let output = outputs[path],
        let bytes = candidates[path], bytes != output else { continue }
      result.append(.init(id: UUID().uuidString, filename: path, currentText: String(decoding: output, as: UTF8.self),
        changedText: String(decoding: bytes, as: UTF8.self), root: root, libraryID: context.manifest.libraryID,
        fingerprint: SharedLibraryOperation.fingerprint(bytes), outputFingerprint: SharedLibraryOperation.fingerprint(output)))
    }
    try Task.checkCancellation()
    bootstrapReviewTickets = Set(result.map(\.id))
    return result
  }
  public func restoreBootstrapProjection(_ review: SharedBootstrapProjectionReview) async throws -> SharedProjectionWriteResult {
    guard review.root == root else { throw SharedLibraryCoordinatorError.differentBinding }
    guard bootstrapReviewTickets.remove(review.id) != nil else { throw SharedLibraryCoordinatorError.staleReview }
    var context = try await projectionContext()
    guard context.manifest.libraryID == review.libraryID,
      let output = try SharedLibraryProjectionWriter.render(context)[review.filename],
      SharedLibraryOperation.fingerprint(output) == review.outputFingerprint,
      let bytes = try await RecordingFileAccess().readDataIfPresent(at: root.appendingPathComponent(review.filename)),
      SharedLibraryOperation.fingerprint(bytes) == review.fingerprint else { throw SharedLibraryCoordinatorError.externalChanged }
    // This permission exists only for this call. The writer rechecks the actual
    // input immediately before replacement and persists an attempt first.
    context.reviewedBootstrap[review.filename] = review.fingerprint
    return try await SharedLibraryProjectionWriter.project(context, writer: writerID, only: [review.filename])
  }
  private func projectionContext(for selected: SharedEntityIdentity? = nil) async throws -> SharedLibraryProjectionContext {
    guard transitions == 0 else { throw SharedProjectionWriteError.stale }
    let manifest = try await bind(force: true)
    guard try await mayEdit(), let gate, let directory = witnessDirectory else { throw SharedLibraryCoordinatorError.enrollmentPending }
    let epoch = authorityEpoch
    let witness = SharedOwnerWitness(directory: directory, libraryID: manifest.libraryID, writerID: writerID)
    let checkpoint = try witness.checkpointFingerprint()
    let before = try await SharedLibraryProjectionWriter.authoritySources(root: root)
    let views = try await snapshots(kinds: [.recording, .folder, .template])
    let after = try await SharedLibraryProjectionWriter.authoritySources(root: root)
    let membership = try await memberRepository().load().membership
    let published = try await SharedPublishedLocations.load(root: root, manifest: manifest, membership: membership, afterLibraryRead: afterPublishedLibraryRead)
    let pathStates = views.map { view -> SharedEntityState in
      let fields = view.state.kind == .folder ? ["name", "parent"] : ["title", "folder"]
      return fields.contains(where: { view.state.fields[$0]?.isConflicted == true }) ? (view.confirmedState ?? view.state) : view.state
    }
    let reservations = try published.reservations(states: pathStates, library: manifest.libraryID)
    let index = try SharedLibraryPathIndex(states: pathStates, caseSensitive: false, retainedLocations: reservations)
    // Selected content keeps the complete namespace and authority proof, but
    // needs physical readiness only for its recording and ancestor folders.
    // A retained original elsewhere must not prevent publishing these bytes.
    let selectedPath = selected.flatMap { index.resolvedPaths[$0.id] }
    func requiresPhysicalProof(_ view: SharedLibraryViewSnapshot) -> Bool {
      guard let selected else { return true }
      if view.state.kind == .recording { return view.state.id == selected.id }
      guard view.state.kind == .folder, let selectedPath,
            let folderPath = index.resolvedPaths[view.state.id] else { return false }
      return selectedPath.hasPrefix(folderPath + "/")
    }
    var absentPaths: [String] = []
    var physicalInputs: [URL: String] = [:]
    var completedIntents = published.completedFileIntents
    for view in views where view.state.kind == .folder && view.state.lifecycle == .alive && requiresPhysicalProof(view) {
      if let physical = view.state.fields["physicalPath"],
         physical.isConflicted || physical.resolvedValue != index.resolvedPaths[view.state.id].map(SharedFieldValue.text) { throw SharedLibraryOperationError.unfinishedOperation }
    }
    for view in views where view.state.kind == .recording && view.state.lifecycle == .alive && requiresPhysicalProof(view) {
      if let published = view.state.fields["audioPublished"],
         published.isConflicted || published.resolvedValue != view.state.value(for: "audioFingerprint") { throw SharedLibraryOperationError.unfinishedOperation }
      guard let destination = index.resolvedPaths[view.state.id] else { continue }
      for source in reservations[view.state.id] ?? [] where source != destination {
        let stem = (source as NSString).deletingPathExtension
        for suffix in [".mp3", ".transcript.json", ".summary.json", ".txt", ".transcript.md", ".summary.md"] {
          let url = root.appendingPathComponent(stem + suffix)
          absentPaths.append(stem + suffix)
          let placeholder = url.deletingLastPathComponent().appendingPathComponent("." + url.lastPathComponent + ".icloud")
          guard !FileManager.default.fileExists(atPath: url.path), !FileManager.default.fileExists(atPath: placeholder.path) else {
            throw SharedLibraryOperationError.unfinishedOperation
          }
        }
      }
    }
    for view in views where view.state.kind == .recording && view.state.lifecycle == .alive && view.state.conflicts.isEmpty && requiresPhysicalProof(view) {
      let intents = try SharedPublishedLocations.fileIntents(state: view.state, library: manifest.libraryID).filter { owner, document, _ in
        owner == writerID.uuidString.lowercased() && completedIntents[view.state.id]?[owner] != SharedLibraryOperation.fingerprint(document.json)
      }
      guard !intents.isEmpty else { continue }
      let entity = SharedEntityIdentity(id: view.state.id, kind: .recording)
      let reader = try await makeMaterializer(entity: entity, paths: [], receipts: operationReceipts(library: manifest.libraryID))
      guard let progress = try await reader.progress(entity: entity, libraryID: manifest.libraryID), progress.completedSteps == progress.operation.steps.count else { continue }
      for (owner, document, intent) in intents {
        guard progress.operation.steps == intent.steps, progress.operation.inputRevision == intent.inputRevision,
              let destination = index.resolvedPaths[view.state.id],
              let audio = intent.steps.first(where: { if case .move(_, let path, _) = $0 { return path.hasSuffix(".mp3") }; return false }),
              case .move(_, let path, let hash) = audio, path == destination else { continue }
        let file = root.appendingPathComponent(path)
        guard let bytes = try await RecordingFileAccess().readDataIfPresent(at: file, knownToExist: true), SharedLibraryOperation.fingerprint(bytes) == hash else { throw SharedLibraryOperationError.contentChanged(path) }
        physicalInputs[file] = hash
        completedIntents[view.state.id, default: [:]][owner] = SharedLibraryOperation.fingerprint(document.json)
      }
    }
    guard transitions == 0, authorityEpoch == epoch, before == after,
          try witness.checkpointFingerprint() == checkpoint,
          membership.pendingWriters.isEmpty, !membership.hasConcurrentEnrollment,
          views.allSatisfy({ $0.repository.writers.isSubset(of: membership.cohort) }) else { throw SharedProjectionWriteError.stale }
    let lease = authorityLease ?? SharedMaterializationLease()
    authorityLease = lease
    leasedRevisions = Dictionary(uniqueKeysWithValues: views.map { (SharedEntityIdentity(id: $0.state.id, kind: $0.state.kind), $0.fingerprint) })
    return .init(root: root, manifest: manifest, views: views, sources: after, gate: gate, lease: lease,
                 validate: { try witness.checkpointFingerprint() == checkpoint }, membership: membership,
                 reservations: reservations, completedFileIntents: completedIntents,
                 absentPaths: Array(Set(absentPaths)).sorted(), physicalInputs: physicalInputs)
  }

  public func makeMaterializer(
    entity: SharedEntityIdentity, paths: [String], receipts: URL,
    afterMutation: @escaping @Sendable (Int) throws -> Void = { _ in }, expectedCohort: String? = nil,
    reviewedFolder: SharedLibraryViewSnapshot? = nil
  ) async throws -> SharedLibraryMaterializer {
    _ = try await bind(force: true)
    guard let gate else { throw SharedLibraryOperationError.invalidOperation }
    return SharedLibraryMaterializer(root: root, receipts: receipts,
      authority: {
        try await self.operationAuthority(entity: entity, paths: paths, reviewedFolder: reviewedFolder, expectedCohort: expectedCohort)
      },
      trash: trash, afterMutation: afterMutation, gate: gate)
  }

  /// Input staging can precede creation of the recording. This authority is
  /// private and grants no canonical paths; ordinary physical permission still
  /// requires an existing entity in the shared graph.
  private func makeInputStager(entity: SharedEntityIdentity, library: UUID) async throws -> SharedLibraryMaterializer {
    _ = try await bind(force: true)
    guard let gate else { throw SharedLibraryOperationError.invalidOperation }
    return SharedLibraryMaterializer(root: root, receipts: try operationReceipts(library: library),
      authority: { try await self.protectedOperationAuthority(entity: entity, paths: [], includeUninitialized: true) },
      trash: trash, gate: gate)
  }
  /// Build physical permission from the whole current identity graph, not an
  /// entity's cached filename. Aggregate projections require a separate all-
  /// entity contract and cannot use this single-entity authority.
  public func operationAuthority(entity: SharedEntityIdentity, paths: [String],
                                 reviewedFolder: SharedLibraryViewSnapshot? = nil, expectedCohort: String? = nil) async throws
    -> SharedMaterializationAuthority
  {
    let permission = try await protectedOperationAuthority(entity: entity, paths: paths, includeUninitialized: false, reviewedFolder: reviewedFolder)
    if let expectedCohort, permission.membership.fingerprint != expectedCohort { throw SharedLibraryOperationError.staleAuthority }
    return permission
  }
  private func protectedOperationAuthority(entity: SharedEntityIdentity, paths: [String], includeUninitialized: Bool,
                                           reviewedFolder: SharedLibraryViewSnapshot? = nil) async throws
    -> SharedMaterializationAuthority
  {
    guard transitions == 0 else { throw SharedLibraryOperationError.staleAuthority }
    let epoch = authorityEpoch
    let manifest = try await bind(force: true)
    guard try await mayEdit() else { throw SharedLibraryCoordinatorError.enrollmentPending }
    let members = try memberRepository()
    let membership = try await members.load().membership
    guard let directory = witnessDirectory else { throw SharedLibraryOperationError.invalidOperation }
    let witness = SharedOwnerWitness(directory: directory, libraryID: manifest.libraryID, writerID: writerID)
    let localCheckpoint = try witness.checkpointFingerprint()
    let authoritySources = try await SharedLibraryProjectionWriter.authoritySources(root: root)
    let identities = try await repository.scan()
    let repository = self.repository
    let snapshots = try await withThrowingTaskGroup(of: SharedLibrarySnapshot.self) { group in
      for identity in identities { group.addTask { try await repository.load(entity: identity) } }
      var result: [SharedLibrarySnapshot] = []
      for try await snapshot in group { result.append(snapshot) }
      return result
    }
    let latest = try await members.load().membership
    let finalSources = try await SharedLibraryProjectionWriter.authoritySources(root: root)
    guard transitions == 0, authorityEpoch == epoch, finalSources == authoritySources,
          latest.fingerprint == membership.fingerprint else { throw SharedLibraryOperationError.staleAuthority }
    guard snapshots.allSatisfy({ $0.writers.isSubset(of: membership.cohort) }) else {
      throw SharedLibraryCoordinatorError.unrecognizedWriter
    }
    if let reviewedFolder {
      guard reviewedFolder.state.kind == .folder, reviewedFolder.libraryID == manifest.libraryID,
            repository.accepts(reviewedFolder.repository) else { throw SharedLibraryCoordinatorError.differentBinding }
      guard snapshots.contains(where: { $0.state.id == reviewedFolder.state.id && $0.state.kind == .folder && $0.state == reviewedFolder.state }) else { throw SharedLibraryCoordinatorError.staleReview }
    }
    let selected: SharedLibrarySnapshot
    if let existing = snapshots.first(where: { $0.state.id == entity.id && $0.state.kind == entity.kind }) { selected = existing }
    else {
      guard includeUninitialized, paths.isEmpty, entity.kind == .recording else { throw SharedSidecarError.unknownRecording }
      selected = try await repository.load(entity: entity)
      guard selected.state.lifecycle == .uninitialized, selected.writers.isEmpty else { throw SharedLibraryOperationError.invalidOperation }
    }
    let sensitivity = (try? root.resourceValues(forKeys: [.volumeSupportsCaseSensitiveNamesKey]))?.volumeSupportsCaseSensitiveNames ?? false
    let locations = try await SharedPublishedLocations.load(root: root, manifest: manifest, membership: membership, afterLibraryRead: afterPublishedLibraryRead)
    let knownIDs = Set(snapshots.filter { $0.state.kind == .recording }.map { $0.state.id })
    guard Set(locations.recordings.keys).isSubset(of: knownIDs) else { throw SharedProjectionWriteError.untracked("library.json") }
    let index = try SharedLibraryPathIndex(states: snapshots.map(\.state), caseSensitive: sensitivity, retainedLocations: locations.reservations(states: snapshots.map(\.state), library: manifest.libraryID))
    var owners = index.operationOwners(for: paths)
    let acknowledgments = try await SharedOperationAcknowledgmentStore(
      root: root, libraryID: manifest.libraryID, writer: writerID, witness: witness, gate: gate).load(entity: entity.id)
    guard transitions == 0, authorityEpoch == epoch,
          try witness.checkpointFingerprint() == localCheckpoint else { throw SharedLibraryOperationError.staleAuthority }
    struct Revision: Encodable {
      struct Entry: Encodable { let id: UUID; let kind: SharedEntityKind; let revision: String }
      let membership: String
      let entities: [Entry]
      let jobs: [UUID]
    }
    let revision = try SharedStateFingerprint.of(Revision(
      membership: membership.fingerprint,
      entities: snapshots.map { .init(id: $0.state.id, kind: $0.state.kind, revision: $0.fingerprint) }
        .sorted { ($0.kind.rawValue, $0.id.uuidString) < ($1.kind.rawValue, $1.id.uuidString) },
      jobs: jobs.keys.sorted { $0.uuidString < $1.uuidString }))
    if authorityRevision != revision || authorityLease?.isRevoked != false {
      revokeAuthority()
      authorityLease = .init()
      authorityRevision = revision
      leasedRevisions = Dictionary(uniqueKeysWithValues: snapshots.map {
        (SharedEntityIdentity(id: $0.state.id, kind: $0.state.kind), $0.fingerprint)
      })
    }
    var affected: Set<UUID> = [entity.id]
    if entity.kind == .folder {
      for snapshot in snapshots where snapshot.state.kind != .template {
        var parents = snapshot.state.fields[snapshot.state.kind == .folder ? "parent" : "folder"]?.values ?? []
        var visited: Set<UUID> = []
        while let value = parents.popFirst() {
          guard case .text(let text) = value, let id = UUID(uuidString: text), visited.insert(id).inserted else { continue }
          if id == entity.id { affected.insert(snapshot.state.id); break }
          if let parent = snapshots.first(where: { $0.state.kind == .folder && $0.state.id == id }) { parents.formUnion(parent.state.fields["parent"]?.values ?? []) }
        }
      }
    }
    var jobGates: [SharedLibraryJobGate] = []
    var localPending = false
    for id in affected.sorted(by: { $0.uuidString < $1.uuidString }) {
      if let jobGate = try localJobGate(library: manifest.libraryID, entity: id) {
        jobGates.append(jobGate)
        if try jobGate.hasActiveWork() { localPending = true }
      }
    }
    var result = SharedMaterializationAuthority(
      libraryID: manifest.libraryID, state: selected.state, membership: membership,
      acknowledgments: acknowledgments, hasPendingWork: localPending || jobs.values.contains { affected.contains($0.entity.id) }, pathOwners: owners)
    result.jobGates = jobGates
    result.hasLiveDescendants = entity.kind == .folder && snapshots.contains {
      $0.state.id != entity.id && affected.contains($0.state.id) && ($0.state.lifecycle != .deleted || !$0.state.conflicts.isEmpty)
    }
    let validFolderMoves = try selected.state.fields.keys.sorted().compactMap { field -> SharedAcceptedFileIntent? in
      guard entity.kind == .folder, field.hasPrefix("materialization.files."),
            let owner = UUID(uuidString: String(field.dropFirst("materialization.files.".count))),
            case .document(let document)? = selected.state.value(for: field) else { return nil }
      let intent = try JSONDecoder().decode(SharedAcceptedFileIntent.self, from: document.json)
      guard intent.schema == 1, intent.libraryID == manifest.libraryID, intent.entity == entity,
            intent.steps.count == 1, case .moveDirectory = intent.steps[0],
            try selected.state.fileIntentGuardRevision(writer: owner) == intent.guardRevision else { return nil }
      return intent
    }
    if entity.kind == .folder, selected.state.value(for: "physicalPath") != selected.state.value(for: "name") || !validFolderMoves.isEmpty {
      result.directoryScopeMatches = false
      if case .document(let document)? = selected.state.value(for: "moveScope"),
         let scope = try? JSONDecoder().decode(FolderMoveScope.self, from: document.json),
         scope.library == manifest.libraryID, scope.folder == entity.id,
         selected.state.value(for: "name") == .text(scope.destination),
         Set(scope.members.map(\.id)).count == scope.members.count,
         Set(scope.members.map(\.id)) == affected.subtracting([entity.id]),
         scope.members.allSatisfy({ member in
           member.path.hasPrefix(scope.destination + "/") && snapshots.contains {
             $0.state.id == member.id && $0.state.kind == member.kind && $0.state.lifecycle == .alive &&
             $0.state.conflicts.isEmpty && index.resolvedPaths[member.id] == member.path
           }
         }) {
        result.directoryScopeMatches = true
      }
    }
    // Final metadata may precede a provider's directory move. Only an exact
    // still-bound accepted plan may claim its otherwise unowned source alias;
    // another entity's ownership always wins and stops replay.
    if result.directoryScopeMatches, selected.state.lifecycle == .alive, selected.state.conflicts.isEmpty {
      for intent in validFolderMoves {
        guard case .moveDirectory(let source, let destination, _) = intent.steps[0],
              selected.state.value(for: "name") == .text(destination),
              selected.state.value(for: "physicalPath") == .text(destination),
              index.owners(of: destination) == [entity.id], index.owners(of: source).isEmpty else { continue }
        if paths.contains(source) { owners[source] = [entity.id] }
      }
    }
    for path in paths {
      _ = try SharedLibraryIdentity.normalized(path)
      guard path != "library.json", owners[path] == [entity.id] else { throw SharedLibraryOperationError.pathConflict(path) }
    }
    result.pathOwners = owners
    let formatURL = root.appendingPathComponent(".docktape/format.json")
    result.additionalBindings = authoritySources.filter { $0.key != formatURL }.map { url, expected in
      SharedMaterializationBinding(file: url) { SharedLibraryOperation.fingerprint($0) == expected }
    } + locations.proofs.filter { authoritySources[$0.key] == nil }.map { url, expected in
      SharedMaterializationBinding(file: url) { SharedLibraryOperation.fingerprint($0) == expected }
    }.sorted { $0.file.path < $1.file.path }
    result.allowedPaths = Set(paths)
    result.revisionLease = authorityLease!
    let expectedSources = Set(authoritySources.keys)
    let authorityRoot = root
    result.validateLocalCommit = {
      let actualSources = Set(LibraryFileDiscovery.files(in: authorityRoot.appendingPathComponent(".docktape"), suffix: ".json")
        .filter { !$0.relativePath.hasPrefix("projections/") }.map { authorityRoot.appendingPathComponent(".docktape/" + $0.relativePath) })
      return try witness.checkpointFingerprint() == localCheckpoint && actualSources == expectedSources
    }
    result.binding = .init(file: root.appendingPathComponent(".docktape/format.json")) { bytes in
      let actualSources = Set(LibraryFileDiscovery.files(in: self.root.appendingPathComponent(".docktape"), suffix: ".json")
        .filter { !$0.relativePath.hasPrefix("projections/") }.map { self.root.appendingPathComponent(".docktape/" + $0.relativePath) })
      guard actualSources == expectedSources, SharedLibraryOperation.fingerprint(bytes) == authoritySources[formatURL] else { return false }
      guard let current = try? JSONDecoder().decode(SharedBootstrapManifest.self, from: bytes) else { return false }
      return current.schemaVersion == manifest.schemaVersion && current.complete
        && current.libraryID == manifest.libraryID && current.fingerprint == manifest.fingerprint
    }
    return result
  }

  public func edit(_ edit: SharedCoordinatorEdit) async throws -> SharedLibraryViewSnapshot {
    try await commit(edit, review: false)
  }
  public func resolve(_ edit: SharedCoordinatorEdit) async throws -> SharedLibraryViewSnapshot {
    try await commit(edit, review: true)
  }
  private func commit(_ edit: SharedCoordinatorEdit, review: Bool, exact: Bool = false,
                      bindings: [SharedMaterializationBinding] = [], preparedFileOperation: SharedPreparedFileOperation? = nil,
                      additionalValidation: (@Sendable () throws -> Void)? = nil) async throws
    -> SharedLibraryViewSnapshot
  {
    beginTransition(); defer { endTransition() }
    let manifest = try await bind(force: true)
    guard manifest.libraryID == edit.base.libraryID, repository.accepts(edit.base.repository) else {
      throw SharedLibraryCoordinatorError.differentBinding
    }
    guard try await mayEdit() else { throw SharedLibraryCoordinatorError.enrollmentPending }
    let membership = try await memberRepository().load().membership
    let entity = SharedEntityIdentity(id: edit.base.state.id, kind: edit.base.state.kind)
    let fresh = try await repository.load(entity: entity)
    guard fresh.writers.isSubset(of: membership.cohort) else {
      throw SharedLibraryCoordinatorError.unrecognizedWriter
    }
    for change in edit.changes {
      if !Self.reviewMatches(edit.base.state, fresh.state, change: change, review: review) {
        throw SharedLibraryCoordinatorError.staleReview
      }
    }
    if exact, fresh.fingerprint != edit.base.fingerprint { throw SharedLibraryCoordinatorError.staleReview }
    let expected = try SharedStateFingerprint.of(fresh.state)
    let validation: (@Sendable (SharedEntityState) throws -> Void)?
    if exact {
      validation = { state in
        guard try SharedStateFingerprint.of(state) == expected else { throw SharedLibraryCoordinatorError.staleReview }
        try additionalValidation?()
      }
    } else { validation = additionalValidation.map { extra in { _ in try extra() } } }
    var transaction = SharedLibraryEdit(base: fresh, changes: edit.changes, validation: validation, bindings: bindings)
    transaction.preparedFileOperation = preparedFileOperation
    let accepted = try await repository.commit(transaction)
    let view = SharedLibraryViewSnapshot(libraryID: manifest.libraryID, repository: accepted)
    publish(view, entity: entity, request: beginRead(entity))
    await afterCommit()
    // Return the accepted write even if cancellation or a later read failure
    // crosses this boundary. Refresh joins any subsequently arriving peer dots;
    // a failed read cannot retroactively turn this commit into a rollback.
    return view
  }
  private static func reviewMatches(
    _ before: SharedEntityState, _ after: SharedEntityState, change: SharedLibraryMutation,
    review: Bool
  ) -> Bool {
    let fields: Set<String>
    switch change {
    case .assign(let field, _): fields = [field]
    case .generation(_, let component):
      fields = Set(before.fields.keys.filter { $0.hasPrefix(component.rawValue + ".") }).union(
        after.fields.keys.filter { $0.hasPrefix(component.rawValue + ".") })
    case .generationEdit(let component, let generation, let key, _):
      fields = [
        component.rawValue + ".content",
        "\(component.rawValue).edits.\(generation.uuidString.lowercased()).\(key)",
      ]
    case .delete, .restore: return before == after
    }
    return fields.allSatisfy {
      review
        ? before.fields[$0] == after.fields[$0]
        : (before.fields[$0]?.values ?? []) == (after.fields[$0]?.values ?? [])
    }
  }

  private func localJobGate(library: UUID, entity: UUID) throws -> SharedLibraryJobGate? {
    guard let directory = witnessDirectory else { return nil }
    let gate = SharedLibraryJobGate(file: directory.appendingPathComponent("Jobs").appendingPathComponent(library.uuidString)
      .appendingPathComponent(writerID.uuidString).appendingPathComponent(entity.uuidString + ".lock"))
    try gate.prepare(outside: root)
    return gate
  }

  public func pinJob(_ entity: SharedEntityIdentity, input: SharedComponent? = nil, output: SharedComponent? = nil,
                     audioURL: URL? = nil) async throws
    -> SharedLibraryJobToken
  {
    try await pinJob(entity, input: input, output: output, audioURL: audioURL, beforeLease: {})
  }
  func pinJob(_ entity: SharedEntityIdentity, input: SharedComponent? = nil, output: SharedComponent? = nil,
              audioURL: URL? = nil, afterPathValidation: @escaping @Sendable () async throws -> Void = {},
              beforeLease: @escaping @Sendable () async throws -> Void) async throws -> SharedLibraryJobToken {
    beginTransition(); defer { endTransition() }
    let snapshot = try await read(entity)
    guard snapshot.state.lifecycle == .alive else { throw SharedLibraryCoordinatorError.staleJob }
    if output != nil, !(try await mayEdit()) { throw SharedLibraryCoordinatorError.enrollmentPending }
    try Self.validateProcessingState(snapshot.state, input: input, output: output)
    // Input bytes and prompt context belong to the first selected snapshot.
    // Rebuilding a lease proof must never select different physical audio.
    let metadata = try SharedRecordingMetadataAdapter.render(snapshot)
    var inputFile: SharedMaterializationBinding?
    if let audioURL {
      let expected = root.appendingPathComponent(try await currentPath(snapshot)).standardizedFileURL.resolvingSymlinksInPath()
      guard SharedLibraryMaterializer.contained(audioURL, in: root), audioURL.standardizedFileURL.resolvingSymlinksInPath() == expected else { throw SharedLibraryRepositoryError.invalidPath }
      guard let bytes = try await RecordingFileAccess().readDataIfPresent(at: audioURL, knownToExist: true) else { throw CocoaError(.fileReadNoSuchFile) }
      let fingerprint = SharedLibraryOperation.fingerprint(bytes)
      let selected: String?
      if case .text(let value)? = snapshot.state.value(for: "audioFingerprint") { selected = value } else { selected = metadata.audioSHA256 }
      if let selected, selected != fingerprint { throw SharedLibraryOperationError.contentChanged(audioURL.lastPathComponent) }
      inputFile = .init(file: audioURL) { SharedLibraryOperation.fingerprint($0) == fingerprint }
    }
    let title: String
    if case .text(let value)? = snapshot.state.value(for: "title") { title = value } else { title = "" }
    let parsed = FilenameParsing.parse(title + ".mp3").mode
    let mode = metadata.mode ?? (parsed == .unknown ? "" : parsed.rawValue)
    let delays: [Duration] = [.milliseconds(25), .milliseconds(100)]
    for attempt in 0...delays.count {
      do { return try await prepareJob(entity, snapshot: snapshot, input: input, output: output, inputFile: inputFile, recordingMode: mode, afterPathValidation: afterPathValidation, beforeLease: beforeLease) }
      catch JobPreparationError.changedProof {
        guard attempt < delays.count else { throw SharedLibraryCoordinatorError.staleJob }
        try await Task.sleep(for: delays[attempt])
      }
    }
    throw SharedLibraryCoordinatorError.staleJob
  }
  private enum JobPreparationError: Error { case changedProof }
  private func prepareJob(_ entity: SharedEntityIdentity, snapshot: SharedLibraryViewSnapshot,
                          input: SharedComponent?, output: SharedComponent?, inputFile: SharedMaterializationBinding?, recordingMode: String,
                          afterPathValidation: @escaping @Sendable () async throws -> Void,
                          beforeLease: @escaping @Sendable () async throws -> Void) async throws -> SharedLibraryJobToken {
    try Task.checkCancellation()
    if output != nil, !(try await mayEdit()) { throw SharedLibraryCoordinatorError.enrollmentPending }
    let current = try await read(entity)
    guard current.libraryID == snapshot.libraryID, current.state.lifecycle == .alive,
          try Self.lifecycleRevision(current.state) == Self.lifecycleRevision(snapshot.state),
          try Self.inputRevision(current.state, component: input) == Self.inputRevision(snapshot.state, component: input) else { throw SharedLibraryCoordinatorError.staleJob }
    var pathSnapshots = [current.repository]
    if let inputFile {
      let pathProof = try await currentPathProof(current)
      pathSnapshots += pathProof.ancestors
      let expected = root.appendingPathComponent(pathProof.path).standardizedFileURL.resolvingSymlinksInPath()
      guard inputFile.file.standardizedFileURL.resolvingSymlinksInPath() == expected else { throw SharedLibraryCoordinatorError.staleJob }
    }
    try await afterPathValidation()
    try Task.checkCancellation()
    let token = SharedLibraryJobToken(
      id: UUID(), library: snapshot.libraryID, entity: entity,
      lifecycle: try Self.lifecycleRevision(snapshot.state),
      component: input, input: try Self.inputRevision(snapshot.state, component: input), output: output,
      snapshot: snapshot, inputFile: inputFile, recordingMode: recordingMode)
    if let jobGate = try localJobGate(library: snapshot.libraryID, entity: entity.id) {
      guard let gate, let directory = witnessDirectory else { throw SharedLibraryOperationError.invalidOperation }
      let witness = SharedOwnerWitness(directory: directory, libraryID: snapshot.libraryID, writerID: writerID)
      let checkpoint = try witness.checkpointFingerprint()
      let manifest = try await bind(force: true)
      var bindings = try pathSnapshots.flatMap { try repository.readBindings($0, validateSourceSet: true) }
      bindings.append(SharedMaterializationBinding(file: root.appendingPathComponent(".docktape/format.json")) { bytes in
        guard let value = try? JSONDecoder().decode(SharedBootstrapManifest.self, from: bytes) else { return false }
        return value.complete && value.libraryID == manifest.libraryID && value.fingerprint == manifest.fingerprint
      })
      // Ancestors share the format anchor for their source-set checks.
      // Coordinate it once while retaining every independent predicate.
      let proofs = Dictionary(grouping: bindings, by: \.file).map { file, predicates in
        SharedMaterializationBinding(file: file) { data in
          for predicate in predicates where try !predicate.validate(data) { return false }
          return true
        }
      }.sorted { $0.file.path < $1.file.path }
      let items = try gate.items(outside: root)
      let root = self.root
      try await beforeLease()
      let descriptor = try await CoordinatedFileAccess().withWrites(items, reading: proofs.map(\.file)) { scopes in
        try gate.validate(scopes[0], outside: root)
        guard try witness.checkpointFingerprint() == checkpoint else { throw JobPreparationError.changedProof }
        for (binding, scope) in zip(proofs, scopes.dropFirst(items.count)) {
          guard scope.url.standardizedFileURL.resolvingSymlinksInPath() == binding.file.standardizedFileURL.resolvingSymlinksInPath(),
                try binding.validate(Data(contentsOf: scope.url)) else { throw JobPreparationError.changedProof }
          try scope.checkCancellation()
        }
        try scopes[0].checkCancellation()
        return try jobGate.acquireShared()
      }
      if Task.isCancelled { Darwin.close(descriptor); throw CancellationError() }
      jobLeases[token.id] = SharedLocalJobLease(descriptor: descriptor)
    }
    jobs[token.id] = token
    return token
  }
  public func commitJob(_ token: SharedLibraryJobToken, document: SharedDocument, component: SharedComponent,
                        beforeCommit: @escaping @Sendable () async throws -> Void = {}) async throws -> SharedLibraryViewSnapshot {
    beginTransition(); defer { endTransition() }
    guard let owned = jobs[token.id], owned.library == token.library, owned.entity == token.entity,
          owned.lifecycle == token.lifecycle, owned.input == token.input, !owned.lease.isRevoked else { throw SharedLibraryCoordinatorError.staleJob }
    if let output = owned.output, output != component { throw SharedLibraryCoordinatorError.staleJob }
    let manifest = try await bind(force: true)
    guard manifest.libraryID == token.library else { throw SharedLibraryCoordinatorError.differentBinding }
    guard try await mayEdit() else { throw SharedLibraryCoordinatorError.enrollmentPending }
    let membership = try await memberRepository().load().membership
    let fresh = try await repository.load(entity: token.entity)
    guard fresh.writers.isSubset(of: membership.cohort) else { throw SharedLibraryCoordinatorError.unrecognizedWriter }
    let validate: @Sendable (SharedEntityState) throws -> Void = { state in
      try Self.validateProcessingState(state, input: token.component, output: component)
      guard !owned.lease.isRevoked, state.lifecycle == .alive,
            try Self.lifecycleRevision(state) == token.lifecycle,
            try Self.inputRevision(state, component: token.component) == token.input else { throw SharedLibraryCoordinatorError.staleJob }
    }
    try validate(fresh.state)
    try await beforeCommit()
    let format = SharedMaterializationBinding(file: root.appendingPathComponent(".docktape/format.json")) { bytes in
      guard let current = try? JSONDecoder().decode(SharedBootstrapManifest.self, from: bytes) else { return false }
      return current.complete && current.libraryID == manifest.libraryID && current.fingerprint == manifest.fingerprint
    }
    let accepted: SharedLibrarySnapshot
    do {
      accepted = try await repository.commit(.init(base: fresh, changes: [.generation(document, component: component)], validation: validate, bindings: [format] + (owned.inputFile.map { [$0] } ?? [])))
    } catch SharedLibraryRepositoryError.staleRevision { throw SharedLibraryCoordinatorError.staleJob }
    let view = SharedLibraryViewSnapshot(libraryID: manifest.libraryID, repository: accepted)
    publish(view, entity: token.entity, request: beginRead(token.entity))
    await afterCommit()
    return view
  }
  public func finishJob(_ token: SharedLibraryJobToken) async {
    guard let existing = jobs[token.id], existing.library == token.library, existing.entity == token.entity else { return }
    existing.lease.revoke()
    revokeAuthority()
    jobs.removeValue(forKey: token.id)
    if let lease = jobLeases.removeValue(forKey: token.id) { await lease.release() }
  }
  public func validateJob(_ token: SharedLibraryJobToken) async throws {
    guard jobs[token.id] != nil else { throw SharedLibraryCoordinatorError.staleJob }
    let snapshot = try await read(token.entity)
    guard snapshot.libraryID == token.library, snapshot.state.lifecycle == .alive,
      try Self.lifecycleRevision(snapshot.state) == token.lifecycle,
      try Self.inputRevision(snapshot.state, component: token.component) == token.input
    else { throw SharedLibraryCoordinatorError.staleJob }
  }
  public func transcriptForJob(_ token: SharedLibraryJobToken, filename: String) async throws -> Transcript? {
    try await validateJob(token)
    guard let owned = jobs[token.id], owned.component == .transcript else { throw SharedLibraryCoordinatorError.staleJob }
    return try SharedSidecarAdapter.transcript(owned.snapshot, filename: filename)
  }
  private static func validateProcessingState(_ state: SharedEntityState, input: SharedComponent?, output: SharedComponent?) throws {
    if state.fields["audioFingerprint"]?.isConflicted == true { throw SharedLibraryCoordinatorError.staleJob }
    for component in [input, output].compactMap({ $0 }) {
      if state.fields.contains(where: { $0.key.hasPrefix(component.rawValue + ".") && $0.value.isConflicted }) { throw SharedLibraryCoordinatorError.staleJob }
    }
    if let input, state.currentDocument(for: input) == nil { throw SharedLibraryCoordinatorError.staleJob }
  }
  private static func lifecycleRevision(_ state: SharedEntityState) throws -> String {
    try SharedStateFingerprint.of(state.fields["$lifecycle"])
  }
  private static func inputRevision(_ state: SharedEntityState, component: SharedComponent?) throws
    -> String
  {
    if let component {
      struct Input: Encodable {
        let document: SharedDocument?
        let edits: [String: SharedFieldValue]
      }
      return try SharedStateFingerprint.of(
        Input(
          document: state.currentDocument(for: component),
          edits: state.generationEdits(for: component)))
    }
    return try SharedStateFingerprint.of(
      state.value(for: "audioFingerprint") ?? state.value(for: "legacyMetadata"))
  }
  /// Inspect only a recording's current canonical sidecars. A missing or cold
  /// file is not a deletion, and inspection never changes authoritative state.
  public func reviewSidecars(_ entity: SharedEntityIdentity) async throws -> [SharedSidecarReview] {
    let view = try await read(entity)
    guard entity.kind == .recording, view.state.lifecycle == .alive,
      view.state.conflicts.isEmpty else { throw SharedSidecarError.conflictedContent }
    let filename = try await currentPath(view)
    let manifest = try await bind(force: true)
    let membership = try await memberRepository().load().membership
    let published = try await SharedPublishedLocations.load(root: root, manifest: manifest,
      membership: membership, afterLibraryRead: afterPublishedLibraryRead)
    let currentFiles = try SharedLibraryReadableExport.files(view: view, recordingPath: filename)
    var result: [SharedSidecarReview] = []
    for component in [SharedComponent.transcript, .summary] {
      let path = (filename as NSString).deletingPathExtension + "." + component.rawValue + ".json"
      let url = root.appendingPathComponent(path)
      guard FileManager.default.fileExists(atPath: url.path) else { continue }
      guard url.resolvingSymlinksInPath().path == url.path else { throw SharedLibraryRepositoryError.invalidPath }
      let bytes = try await CoordinatedFileAccess().read(at: url)
      if (try? published.validateCompanion(path: path, bytes: bytes, entity: entity.id,
          library: view.libraryID, kind: component.rawValue)) != nil { continue }
      guard let currentBytes = currentFiles[path] else { throw SharedSidecarError.invalidContent }
      let current = try SharedDocument(id: UUID(), json: externalBody(currentBytes, snapshot: view, component: component))
      let changed: SharedDocument?
      if let body = try? externalBody(bytes, snapshot: view, component: component),
         let document = try? SharedDocument(id: UUID(), json: body),
         (try? Self.sidecarText(document, component: component)) != nil { changed = document }
      else { changed = nil }
      result.append(.init(filename: filename, component: component,
        currentText: try Self.sidecarText(current, component: component),
        changedText: try changed.map { try Self.sidecarText($0, component: component) },
        entity: entity, snapshot: view, url: url, fingerprint: try SharedStateFingerprint.of(bytes),
        current: current, changed: changed))
    }
    guard try await read(entity).fingerprint == view.fingerprint,
      try await currentPath(view) == filename else { throw SharedLibraryCoordinatorError.staleReview }
    return result
  }
  public func recoverSidecar(_ review: SharedSidecarReview, useChangedFile: Bool) async throws -> SharedLibraryViewSnapshot {
    let fresh = try await read(review.entity)
    guard fresh.libraryID == review.snapshot.libraryID else { throw SharedLibraryCoordinatorError.differentBinding }
    guard fresh.fingerprint == review.snapshot.fingerprint,
      try await currentPath(fresh) == review.filename else { throw SharedLibraryCoordinatorError.staleReview }
    let bytes = try await CoordinatedFileAccess().read(at: review.url)
    guard try SharedStateFingerprint.of(bytes) == review.fingerprint else { throw SharedLibraryCoordinatorError.externalChanged }
    guard let document = useChangedFile ? review.changed : review.current else { throw SharedSidecarError.invalidContent }
    // The writer checks this exact external hash again before replacing bytes.
    // Effective current content includes speaker/checklist edits; a fresh content
    // generation prevents applying those edits a second time after recovery.
    return try await commit(.init(base: review.snapshot, changes: [
      .generation(document, component: review.component),
      .assign(field: "externalAdoption." + review.component.rawValue, value: .text(review.fingerprint)),
      .assign(field: "externalAdoptionGeneration." + review.component.rawValue, value: .text(document.id.uuidString.lowercased()))
    ]), review: true, exact: true)
  }
  private static func sidecarText(_ document: SharedDocument, component: SharedComponent) throws -> String {
    if component == .transcript {
      let transcript = try document.decode(Transcript.self)
      guard transcript.segments.allSatisfy({ $0.startTime.isFinite && $0.endTime.isFinite && $0.startTime >= 0
        && $0.endTime >= $0.startTime && $0.endTime <= Double(Int32.max) }) else { throw SharedSidecarError.invalidContent }
      return transcript.plainText()
    }
    let summary = try document.decode(Summary.self)
    let ids = summary.sections.flatMap { $0.items ?? [] }.map(\.id)
    guard Set(ids).count == ids.count else { throw SharedSidecarError.invalidContent }
    return summary.sections.map { section in
      ([section.heading, section.content] + (section.items ?? []).map { ($0.isCompleted ? "☑ " : "☐ ") + $0.text }).joined(separator: "\n")
    }.joined(separator: "\n\n")
  }

  /// Explicitly accept the reviewed external document. Materialization and
  /// provider-version cleanup follow a durable operation receipt, not this read.
  public func adoptExternal(_ candidate: SharedExternalContent, review: SharedLibraryViewSnapshot)
    async throws
    -> SharedLibraryViewSnapshot
  {
    let manifest = try await bind(force: true)
    guard candidate.libraryID == manifest.libraryID, review.libraryID == manifest.libraryID,
      candidate.entity.id == review.state.id, candidate.entity.kind == review.state.kind,
      candidate.url.resolvingSymlinksInPath().path.hasPrefix(root.path + "/")
    else {
      throw SharedLibraryCoordinatorError.differentBinding
    }
    let bytes: Data
    if let versionID = candidate.versionID {
      let versions = try await versionAccess.versions(at: candidate.url)
      guard
        let version = versions.first(where: {
          $0.id == versionID && $0.isConflict && !$0.isResolved
            && $0.sourceURL.standardizedFileURL == candidate.url.standardizedFileURL
        })
      else {
        throw SharedLibraryCoordinatorError.externalChanged
      }
      bytes = try await versionAccess.read(version)
    } else {
      bytes = try await CoordinatedFileAccess().read(at: candidate.url)
    }
    guard try SharedStateFingerprint.of(bytes) == candidate.fingerprint else {
      throw SharedLibraryCoordinatorError.externalChanged
    }
    let fresh = try await read(candidate.entity)
    let checked = try SharedDocument(id: candidate.document.id, json: externalBody(bytes, snapshot: fresh, component: candidate.component))
    guard checked.json == candidate.document.json else { throw SharedLibraryCoordinatorError.externalChanged }
    let marker = "externalAdoption." + candidate.component.rawValue
    if fresh.state.value(for: marker) == .text(candidate.fingerprint),
      let selected = fresh.state.currentDocument(for: candidate.component),
      fresh.state.value(for: "externalAdoptionGeneration." + candidate.component.rawValue) == .text(selected.id.uuidString.lowercased()),
      selected.json == candidate.document.json
    {
      return fresh
    }
    // A fresh generation prevents adoption replay from carrying edits from
    // an earlier occurrence of these same bytes into unrelated new content.
    let document = try SharedDocument(id: UUID(), json: candidate.document.json)
    return try await resolve(
      .init(
        base: review,
        changes: [
          .generation(document, component: candidate.component),
          .assign(field: marker, value: .text(candidate.fingerprint)),
          .assign(field: "externalAdoptionGeneration." + candidate.component.rawValue, value: .text(document.id.uuidString.lowercased())),
        ]))
  }

  public func inspectExternalVersions(
    _ entity: SharedEntityIdentity, component: SharedComponent, at url: URL
  )
    async throws -> [SharedExternalContent]
  {
    guard url.resolvingSymlinksInPath().path.hasPrefix(root.path + "/") else {
      throw SharedLibraryRepositoryError.invalidPath
    }
    let snapshot = try await read(entity)
    let versions = try await versionAccess.versions(at: url)
    var result: [SharedExternalContent] = []
    for version in versions where version.isConflict && !version.isResolved {
      guard version.sourceURL.standardizedFileURL == url.standardizedFileURL else {
        throw SharedLibraryRepositoryError.invalidPath
      }
      let bytes = try await versionAccess.read(version)
      let fingerprint = try SharedStateFingerprint.of(bytes)
      let id = try SharedLibraryIdentity.legacy(
        relativePath:
          "version-\(entity.id.uuidString)-\(component.rawValue)-\(version.id)-\(fingerprint).json")
      let document = try SharedDocument(id: id, json: externalBody(bytes, snapshot: snapshot, component: component))
      result.append(
        .init(
          libraryID: snapshot.libraryID, versionID: version.id, id: id, entity: entity,
          component: component, url: url, fingerprint: fingerprint, document: document))
    }
    return result
  }

  public func inspectExternal(
    _ entity: SharedEntityIdentity, component: SharedComponent, at url: URL
  ) async throws
    -> SharedExternalContent?
  {
    guard url.resolvingSymlinksInPath().path.hasPrefix(root.path + "/") else {
      throw SharedLibraryRepositoryError.invalidPath
    }
    let snapshot = try await read(entity)
    let bytes = try await CoordinatedFileAccess().read(at: url)
    let fingerprint = try SharedStateFingerprint.of(bytes)
    let id = try SharedLibraryIdentity.legacy(
      relativePath: "external-\(entity.id.uuidString)-\(component.rawValue)-\(fingerprint).json")
    let document = try SharedDocument(id: id, json: externalBody(bytes, snapshot: snapshot, component: component))
    let manifest = try await bind(force: true)
    let membership = try await memberRepository().load().membership
    let published = try await SharedPublishedLocations.load(root: root, manifest: manifest, membership: membership, afterLibraryRead: afterPublishedLibraryRead)
    let relative = String(url.standardizedFileURL.resolvingSymlinksInPath().path.dropFirst(root.path.count + 1))
    if (try? published.validateCompanion(path: relative, bytes: bytes, entity: entity.id,
         library: snapshot.libraryID, kind: component.rawValue)) != nil { return nil }
    if snapshot.state.currentDocument(for: component)?.json == document.json { return nil }
    return .init(
      libraryID: snapshot.libraryID, versionID: nil, id: id, entity: entity, component: component,
      url: url,
      fingerprint: fingerprint, document: document)
  }
  private func externalBody(_ bytes: Data, snapshot: SharedLibraryViewSnapshot, component: SharedComponent) throws -> Data {
    guard let marker = try SharedProjectionDocument.declaredMarker(in: bytes) else { return bytes }
    guard marker.libraryID == snapshot.libraryID, marker.entities == [snapshot.state.id], marker.kind == component.rawValue else {
      throw SharedLibraryCoordinatorError.differentBinding
    }
    guard var object = try JSONSerialization.jsonObject(with: bytes) as? [String: Any] else { throw SharedSidecarError.invalidContent }
    object.removeValue(forKey: SharedProjectionDocument.key)
    return try SharedProjectionDocument.canonical(object)
  }

}
