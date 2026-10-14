// © 2026 High Gain Design. All rights reserved.
import Foundation

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
public enum SharedLibraryChange: Sendable {
  case loading(UUID, SharedEntityIdentity)
  case entity(UUID, SharedEntityIdentity, String)
  case failure(String)
}

/// Identity/revision-bound reads and semantic mutations. Reads don't wait for
/// unrelated entity hydration or writer enrollment. Edits require admitted
/// membership; refresh publishes observations, never an alive lifecycle write.
public actor SharedLibraryCoordinator {
  public nonisolated let root: URL
  public nonisolated let writerID: UUID
  private let bootstrap: LegacyLibraryBootstrap
  private let versionAccess: RecordingFileVersionAccess
  private let repository: SharedLibraryRepository
  private let witnessDirectory: URL?
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
    witnessDirectory: URL? = nil
  ) {
    self.root = root.standardizedFileURL.resolvingSymlinksInPath()
    self.writerID = writerID
    self.versionAccess = versionAccess
    self.witnessDirectory = witnessDirectory
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
      do { try await self.refresh() } catch {
        guard !Task.isCancelled else { return }
        await self.reportRefreshError(error.localizedDescription)
      }
    }
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

  /// Resolve an existing identity, never derive a new ID from an unfamiliar
  /// filename. Initial-path hits read only that recording and its ancestors,
  /// so a cold unrelated recording cannot block a resident one.
  public func recording(at relativePath: String) async throws -> SharedLibraryViewSnapshot {
    let path = try SharedLibraryIdentity.normalized(relativePath)
    let manifest = try await bind()
    if let reference = manifest.references.first(where: { $0.entity.kind == .recording && $0.initialPath == path }) {
      let view = try await read(reference.entity)
      guard try await currentPath(view) == path else { throw SharedSidecarError.unknownRecording }
      return view
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
  private func currentPath(_ view: SharedLibraryViewSnapshot) async throws -> String {
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
      let folder = try await read(.init(id: id, kind: .folder)).state
      guard folder.lifecycle == .alive, case .text(let name)? = folder.value(for: "name"), !name.contains("/") else {
        throw SharedSidecarError.ambiguousPath
      }
      parts.insert(name, at: 0)
      parent = folder.value(for: "parent")
    }
    return try SharedLibraryIdentity.normalized(parts.joined(separator: "/"))
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

  public func makeMaterializer(
    entity: SharedEntityIdentity, paths: [String], receipts: URL,
    afterMutation: @escaping @Sendable (Int) throws -> Void = { _ in }
  ) async throws -> SharedLibraryMaterializer {
    _ = try await bind(force: true)
    guard let gate else { throw SharedLibraryOperationError.invalidOperation }
    return SharedLibraryMaterializer(root: root, receipts: receipts,
      authority: { try await self.operationAuthority(entity: entity, paths: paths) },
      afterMutation: afterMutation, gate: gate)
  }

  /// Build physical permission from the whole current identity graph, not an
  /// entity's cached filename. Aggregate projections require a separate all-
  /// entity contract and cannot use this single-entity authority.
  public func operationAuthority(entity: SharedEntityIdentity, paths: [String]) async throws
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
    let identities = try await repository.scan()
    let repository = self.repository
    let snapshots = try await withThrowingTaskGroup(of: SharedLibrarySnapshot.self) { group in
      for identity in identities { group.addTask { try await repository.load(entity: identity) } }
      var result: [SharedLibrarySnapshot] = []
      for try await snapshot in group { result.append(snapshot) }
      return result
    }
    let latest = try await members.load().membership
    guard transitions == 0, authorityEpoch == epoch,
          latest.fingerprint == membership.fingerprint else { throw SharedLibraryOperationError.staleAuthority }
    guard snapshots.allSatisfy({ $0.writers.isSubset(of: membership.cohort) }) else {
      throw SharedLibraryCoordinatorError.unrecognizedWriter
    }
    guard let selected = snapshots.first(where: { $0.state.id == entity.id && $0.state.kind == entity.kind }) else {
      throw SharedSidecarError.unknownRecording
    }
    let sensitivity = (try? root.resourceValues(forKeys: [.volumeSupportsCaseSensitiveNamesKey]))?.volumeSupportsCaseSensitiveNames ?? false
    let index = try SharedLibraryPathIndex(states: snapshots.map(\.state), caseSensitive: sensitivity)
    let owners = index.operationOwners(for: paths)
    for path in paths {
      _ = try SharedLibraryIdentity.normalized(path)
      guard path != "library.json", owners[path] == [entity.id] else {
        throw SharedLibraryOperationError.pathConflict(path)
      }
    }
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
    var result = SharedMaterializationAuthority(
      libraryID: manifest.libraryID, state: selected.state, membership: membership,
      acknowledgments: acknowledgments, hasPendingWork: jobs.values.contains { $0.entity == entity }, pathOwners: owners)
    result.allowedPaths = Set(paths)
    result.revisionLease = authorityLease!
    result.validateLocalCommit = { try witness.checkpointFingerprint() == localCheckpoint }
    result.binding = .init(file: root.appendingPathComponent(".docktape/format.json")) { bytes in
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
  private func commit(_ edit: SharedCoordinatorEdit, review: Bool) async throws
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
    _ = try await repository.commit(.init(base: fresh, changes: edit.changes))
    // A remote write can arrive after preflight. Its unseen dot survives the
    // commit and appears here as a conflict; no distributed lock is claimed.
    return try await read(entity)
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

  public func pinJob(_ entity: SharedEntityIdentity, input: SharedComponent? = nil) async throws
    -> SharedLibraryJobToken
  {
    beginTransition(); defer { endTransition() }
    let snapshot = try await read(entity)
    guard snapshot.state.lifecycle == .alive else { throw SharedLibraryCoordinatorError.staleJob }
    let token = SharedLibraryJobToken(
      id: UUID(), library: snapshot.libraryID, entity: entity,
      lifecycle: try Self.lifecycleRevision(snapshot.state),
      component: input, input: try Self.inputRevision(snapshot.state, component: input))
    jobs[token.id] = token
    return token
  }
  public func finishJob(_ token: SharedLibraryJobToken) {
    guard let existing = jobs[token.id], existing.library == token.library, existing.entity == token.entity else { return }
    revokeAuthority()
    jobs.removeValue(forKey: token.id)
  }
  public func validateJob(_ token: SharedLibraryJobToken) async throws {
    guard jobs[token.id] != nil else { throw SharedLibraryCoordinatorError.staleJob }
    let snapshot = try await read(token.entity)
    guard snapshot.libraryID == token.library, snapshot.state.lifecycle == .alive,
      try Self.lifecycleRevision(snapshot.state) == token.lifecycle,
      try Self.inputRevision(snapshot.state, component: token.component) == token.input
    else { throw SharedLibraryCoordinatorError.staleJob }
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
    let marker = "externalAdoption." + candidate.component.rawValue
    if fresh.state.value(for: marker) == .text(candidate.fingerprint),
      fresh.state.currentDocument(for: candidate.component)?.json == candidate.document.json
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
      let document = try SharedDocument(id: id, json: bytes)
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
    let document = try SharedDocument(id: id, json: bytes)
    if snapshot.state.currentDocument(for: component)?.json == document.json { return nil }
    return .init(
      libraryID: snapshot.libraryID, versionID: nil, id: id, entity: entity, component: component,
      url: url,
      fingerprint: fingerprint, document: document)
  }
}
