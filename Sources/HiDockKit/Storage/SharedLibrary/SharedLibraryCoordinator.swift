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
public struct SharedRecordingReference: Hashable, Sendable {
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
  private let afterCommit: @Sendable () async -> Void
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
    trash: @escaping @Sendable (URL) throws -> Void = { try SharedLibraryMaterializer.moveToTrash($0) }
  ) {
    self.root = root.standardizedFileURL.resolvingSymlinksInPath()
    self.writerID = writerID
    self.versionAccess = versionAccess
    self.witnessDirectory = witnessDirectory
    self.afterCommit = afterCommit
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
  public func reference(to filename: String) async throws -> SharedRecordingReference {
    let view = try await recording(at: filename)
    return .init(libraryID: view.libraryID, entityID: view.state.id)
  }
  public func resolve(_ reference: SharedRecordingReference) async throws -> String {
    let manifest = try await bind(force: true)
    guard manifest.libraryID == reference.libraryID else { throw SharedLibraryCoordinatorError.differentBinding }
    let view = try await read(.init(id: reference.entityID, kind: .recording))
    guard view.libraryID == reference.libraryID, view.state.lifecycle == .alive else { throw SharedLibraryCoordinatorError.staleJob }
    let path = try await currentPath(view)
    let membership = try await memberRepository().load().membership
    let published = try await SharedPublishedLocations.load(root: root, manifest: manifest, membership: membership)
    guard published.recordings[reference.entityID]?.contains(path) == true else { throw SharedLibraryOperationError.unfinishedOperation }
    for original in published.recordings[reference.entityID] ?? [] where original != path {
      let stem = (original as NSString).deletingPathExtension
      for suffix in [".mp3", ".transcript.json", ".summary.json", ".txt", ".transcript.md", ".summary.md"] {
        let url = root.appendingPathComponent(stem + suffix)
        let placeholder = url.deletingLastPathComponent().appendingPathComponent("." + url.lastPathComponent + ".icloud")
        if FileManager.default.fileExists(atPath: url.path) || FileManager.default.fileExists(atPath: placeholder.path) { throw SharedLibraryOperationError.unfinishedOperation }
      }
    }
    let latest = try await read(.init(id: reference.entityID, kind: .recording))
    guard latest.libraryID == reference.libraryID, latest.fingerprint == view.fingerprint else { throw SharedLibraryCoordinatorError.staleJob }
    return path
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

  private func operationReceipts(library: UUID) throws -> URL {
    guard let directory = witnessDirectory else { throw SharedLibraryOperationError.invalidOperation }
    return directory.appendingPathComponent("Operations").appendingPathComponent(library.uuidString).appendingPathComponent(writerID.uuidString)
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
    let index = try SharedLibraryPathIndex(states: views.map(\.state), caseSensitive: false)
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
      let locations = try await SharedPublishedLocations.load(root: root, manifest: manifest, membership: membership)
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
    let accepted = changes.isEmpty ? base : try await commit(.init(base: base, changes: changes), review: false, exact: true)
    if actualHash == selected {
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
    let staged: String
    if let reusable { staged = reusable }
    else { staged = try await materializer.stageNewAudio(bytes, entity: entity) }
    let repair = priorHash == selected
    let step: SharedLibraryOperation.Step = !hasPublishedAudio
      ? .publishAudio(path: filename, staged: staged, selectedFingerprint: selected)
      : .replaceAudio(path: filename, staged: staged, expectedFingerprint: actualHash, selectedFingerprint: selected, repair: repair)
    let operation = try SharedLibraryOperation(libraryID: accepted.libraryID, entity: entity,
      inputRevision: base.fingerprint, outputRevision: SharedStateFingerprint.of(accepted.state), steps: [step], inputAudioFingerprint: priorHash)
    if !repair && hasPublishedAudio {
      let permission = try await operationAuthority(entity: entity, paths: [])
      if !permission.hasPendingWork { try await acknowledgeOperation(entity: entity, purpose: .replaceAudio) }
    }
    try beforeReplay()
    let result = try await materializer.replay(operation)
    var completed = accepted, projectionError: String?
    if result == .complete {
      completed = try await edit(.init(base: try await read(entity), changes: [.assign(field: "audioPublished", value: .text(selected))]))
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
    let index = try SharedLibraryPathIndex(states: views.map(\.state), caseSensitive: false)
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
    let changes: [SharedLibraryMutation] = [
      .assign(field: "initialPath", value: .text(filename)), .assign(field: "title", value: .text(stem)),
      .assign(field: "folder", value: .unset), .assign(field: "audioFingerprint", value: .text(selected)),
      .assign(field: "audioPublished", value: .unset),
      .assign(field: "legacyMetadata", value: .document(try SharedDocument(id: UUID(), json: JSONEncoder().encode(metadata)))),
      .assign(field: "mergeSources", value: .document(try SharedDocument(id: UUID(), json: JSONSerialization.data(withJSONObject: provenance, options: .sortedKeys))))]
    try await beforeCommit()
    try Task.checkCancellation()
    let leases = tokens.map(\.lease)
    let validate: @Sendable (SharedEntityState) throws -> Void = { state in
      guard state.lifecycle == .uninitialized, leases.allSatisfy({ !$0.isRevoked }) else { throw SharedLibraryCoordinatorError.staleJob }
    }
    let accepted: SharedLibrarySnapshot
    beginTransition()
    do {
      accepted = try await repository.commit(.init(base: base, changes: changes, validation: validate, bindings: proofs))
      endTransition()
    } catch { endTransition(); throw error }
    var view = SharedLibraryViewSnapshot(libraryID: manifest.libraryID, repository: accepted)
    publish(view, entity: entity, request: beginRead(entity))
    await afterCommit()
    let materializer = try await makeMaterializer(entity: entity, paths: [filename], receipts: operationReceipts(library: manifest.libraryID))
    let staged = try await materializer.stageNewAudio(bytes, entity: entity)
    let operation = try SharedLibraryOperation(libraryID: manifest.libraryID, entity: entity,
      inputRevision: base.fingerprint, outputRevision: SharedStateFingerprint.of(view.state),
      steps: [.publishAudio(path: filename, staged: staged, selectedFingerprint: selected)])
    let result = try await materializer.replay(operation)
    var projectionError: String?
    if result == .complete {
      view = try await edit(.init(base: try await read(entity), changes: [.assign(field: "audioPublished", value: .text(selected))]))
      do { _ = try await projectOutputs() } catch { projectionError = error.localizedDescription }
    }
    return .init(filename: filename, result: result, projectionError: projectionError, view: view)
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

  public func renameFolder(from source: String, to destination: String,
                           afterMutation: @escaping @Sendable (Int) throws -> Void = { _ in }) async throws -> SharedFolderFileOutcome {
    _ = try SharedLibraryIdentity.normalized(source); _ = try SharedLibraryIdentity.normalized(destination)
    guard !source.contains("/"), !destination.contains("/") else { throw SharedLibraryIdentityError.invalidRelativePath }
    let views = try await snapshots(kinds: [.recording, .folder])
    let index = try SharedLibraryPathIndex(states: views.map(\.state), caseSensitive: false)
    let matches = views.filter { view in
      view.state.kind == .folder && (index.resolvedPaths[view.state.id] == source || view.state.value(for: "physicalPath") == .text(source))
    }
    guard matches.count == 1, let base = matches.first else { throw SharedLibraryPathError.ambiguousPath }
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
    let published = try await SharedPublishedLocations.load(root: root, manifest: manifest, membership: membership)
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
      .assign(field: "physicalPath", value: .text(source)), .assign(field: "moveScope", value: .document(document))]), review: false, exact: true)
    let operation = try SharedLibraryOperation(libraryID: base.libraryID, entity: entity,
      inputRevision: base.fingerprint, outputRevision: SharedStateFingerprint.of(accepted.state),
      steps: [.moveDirectory(source: source, destination: destination, inventory: inventory)])
    // The semantic commit has happened. Save its recovery plan even if
    // cancellation arrived in the post-commit callback; never claim rollback.
    try await Task.detached { try await materializer.recordIntent(operation) }.value
    try Task.checkCancellation()
    let result = try await materializer.replay(operation)
    return try await completeFolderMove(view: accepted, destination: destination, result: result)
  }
  public func resumeFolderOperation(id: UUID, afterMutation: @escaping @Sendable (Int) throws -> Void = { _ in }) async throws -> SharedFolderFileOutcome {
    let entity = SharedEntityIdentity(id: id, kind: .folder)
    let view = try await read(entity)
    let receipts = try operationReceipts(library: view.libraryID)
    let reader = try await makeMaterializer(entity: entity, paths: [], receipts: receipts)
    guard let progress = try await reader.progress(entity: entity, libraryID: view.libraryID),
          case .moveDirectory(let source, let destination, _) = progress.operation.steps.first else { throw SharedLibraryOperationError.invalidOperation }
    if progress.completedSteps == progress.operation.steps.count,
       view.state.lifecycle == .alive, view.state.conflicts.isEmpty,
       view.state.value(for: "physicalPath") == .text(destination),
       view.state.value(for: "name") == .text(destination) {
      var projectionError: String?
      do { _ = try await projectOutputs() } catch { projectionError = error.localizedDescription }
      return .init(id: id, name: destination, result: .complete, projectionError: projectionError)
    }
    let materializer = try await makeMaterializer(entity: entity, paths: [source, destination], receipts: receipts, afterMutation: afterMutation)
    let result = try await materializer.replay(progress.operation)
    return try await completeFolderMove(view: view, destination: destination, result: result)
  }
  private func completeFolderMove(view: SharedLibraryViewSnapshot, destination: String, result: SharedMaterializationResult) async throws -> SharedFolderFileOutcome {
    var projectionError: String?
    if result == .complete {
      _ = try await edit(.init(base: view, changes: [.assign(field: "physicalPath", value: .text(destination))]))
      do { _ = try await projectOutputs() } catch { projectionError = error.localizedDescription }
    }
    return .init(id: view.state.id, name: destination, result: result, projectionError: projectionError)
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
  public func deleteFolder(named name: String, beforeFinalRemoval: @escaping @Sendable () async throws -> Void = {}) async throws -> SharedFolderFileOutcome {
    _ = try SharedLibraryIdentity.normalized(name)
    guard !name.contains("/") else { throw SharedLibraryIdentityError.invalidRelativePath }
    let views = try await snapshots(kinds: [.recording, .folder])
    let index = try SharedLibraryPathIndex(states: views.map(\.state), caseSensitive: false)
    let matches = views.filter { $0.state.kind == .folder && index.resolvedPaths[$0.state.id] == name }
    guard matches.count == 1, let base = matches.first else { throw SharedLibraryPathError.ambiguousPath }
    if case .document = base.state.value(for: "deletionRequest") {
      return try await resumeFolderDeletion(id: base.state.id, beforeFinalRemoval: beforeFinalRemoval)
    }
    guard base.state.lifecycle == .alive, base.state.conflicts.isEmpty else { throw SharedSidecarError.conflictedContent }
    let members = views.filter { $0.state.id != base.state.id && (index.resolvedPaths[$0.state.id]?.hasPrefix(name + "/") == true) }
    guard members.allSatisfy({ $0.state.lifecycle == .alive && $0.state.conflicts.isEmpty }) else { throw SharedSidecarError.conflictedContent }
    let request = FolderDeletionRequest(library: base.libraryID, folder: base.state.id, path: name,
      members: members.map { .init(id: $0.state.id, kind: $0.state.kind, path: index.resolvedPaths[$0.state.id]!, revision: $0.fingerprint) }.sorted { $0.path < $1.path })
    _ = try await commit(.init(base: base, changes: [.assign(field: "deletionRequest", value: .document(try SharedDocument(id: UUID(), json: JSONEncoder().encode(request))))]), review: false, exact: true)
    return try await resumeFolderDeletion(id: base.state.id, beforeFinalRemoval: beforeFinalRemoval)
  }
  public func resumeFolderDeletion(id: UUID, beforeFinalRemoval: @escaping @Sendable () async throws -> Void = {}) async throws -> SharedFolderFileOutcome {
    let rootEntity = SharedEntityIdentity(id: id, kind: .folder)
    let view = try await read(rootEntity)
    guard view.state.conflicts.isEmpty, case .document(let document)? = view.state.value(for: "deletionRequest") else { throw SharedSidecarError.conflictedContent }
    let request = try JSONDecoder().decode(FolderDeletionRequest.self, from: document.json)
    guard request.library == view.libraryID, request.folder == id, !request.path.contains("/"),
          Set(request.members.map(\.id)).count == request.members.count,
          request.members.allSatisfy({ $0.path.hasPrefix(request.path + "/") }) else { throw SharedLibraryOperationError.differentBinding }
    let views = try await snapshots(kinds: [.recording, .folder])
    let index = try SharedLibraryPathIndex(states: views.map(\.state), caseSensitive: false)
    let expected = Set(request.members.map(\.id))
    let actual = Set(views.filter { $0.state.id != id && index.resolvedPaths[$0.state.id]?.hasPrefix(request.path + "/") == true }.map { $0.state.id })
    guard actual == expected, index.resolvedPaths[id] == request.path else { return .init(id: id, name: request.path, result: .needsReplanning, projectionError: nil) }
    if view.state.lifecycle == .deleted {
      let permission = try await operationAuthority(entity: rootEntity, paths: [request.path])
      if try await acknowledgedRemovalIsPresent(paths: [request.path], permission: permission) {
        return .init(id: id, name: request.path, result: .complete, projectionError: nil)
      }
    }
    for member in request.members {
      guard let current = views.first(where: { $0.state.id == member.id && $0.state.kind == member.kind }),
            current.state.conflicts.isEmpty,
            current.state.lifecycle == .deleted || current.fingerprint == member.revision else { return .init(id: id, name: request.path, result: .needsReplanning, projectionError: nil) }
    }
    let permission = try await operationAuthority(entity: rootEntity, paths: [])
    if permission.hasPendingWork { return .init(id: id, name: request.path, result: .waitingForActiveWork, projectionError: nil) }
    for member in request.members where member.kind == .recording {
      let entity = SharedEntityIdentity(id: member.id, kind: .recording)
      let current = try await read(entity)
      let receipts = try operationReceipts(library: view.libraryID)
      let reader = try await makeMaterializer(entity: entity, paths: [], receipts: receipts)
      if let progress = try await reader.progress(entity: entity, libraryID: view.libraryID),
         progress.operation.steps.allSatisfy({ if case .trash = $0 { return true }; return false }) {
        if progress.completedSteps < progress.operation.steps.count {
          let result = try await resumeRecordingOperation(id: member.id)
          if result.result != .complete { return .init(id: id, name: request.path, result: result.result, projectionError: result.projectionError) }
        }
      } else {
        if current.state.lifecycle == .deleted && !FileManager.default.fileExists(atPath: root.appendingPathComponent(member.path).path) {
          let stem = String(member.path.dropLast(4))
          let paths = [".mp3", ".transcript.json", ".summary.json", ".txt", ".transcript.md", ".summary.md"].map { stem + $0 }
          let permission = try await operationAuthority(entity: entity, paths: paths)
          if try await acknowledgedRemovalIsPresent(paths: paths, permission: permission) { continue }
          return .init(id: id, name: request.path, result: .waitingForFile(member.path), projectionError: nil)
        }
        let result = try await deleteSharedRecording(filename: member.path)
        if result.result != .complete { return .init(id: id, name: request.path, result: result.result, projectionError: result.projectionError) }
      }
    }
    let folders = request.members.filter { $0.kind == .folder }.sorted { $0.path.count > $1.path.count }
    for member in folders {
      let outcome = try await removeDeletedEmptyFolder(id: member.id, path: member.path)
      if outcome.result != .complete { return .init(id: id, name: request.path, result: outcome.result, projectionError: outcome.projectionError) }
    }
    try await beforeFinalRemoval()
    return try await removeDeletedEmptyFolder(id: id, path: request.path)
  }
  /// A mirrored deletion is complete only with exact cohort permission and
  /// coordinated absence of every owned path and any iCloud placeholders.
  /// This does not claim that this Mac moved the original files to Trash.
  private func acknowledgedRemovalIsPresent(paths: [String], permission: SharedMaterializationAuthority) async throws -> Bool {
    guard permission.mayDestroy(.delete), let gate else { return false }
    let bindings = permission.additionalBindings + (permission.binding.map { [$0] } ?? [])
    for binding in bindings { _ = try await RecordingFileAccess().waitUntilAvailable(at: binding.file, knownToExist: true) }
    let items = try gate.items(outside: root)
    let root = self.root
    return try await CoordinatedFileAccess().withWrites(items, reading: [root] + bindings.map(\.file)) { scopes in
      try gate.validate(scopes[0], outside: root)
      guard !permission.revisionLease.isRevoked, try permission.validateLocalCommit() else { return false }
      let directory = scopes[items.count].url
      try SharedLibraryMaterializer.checkRoot(directory)
      guard directory.standardizedFileURL.resolvingSymlinksInPath() == root.standardizedFileURL.resolvingSymlinksInPath() else { throw SharedLibraryOperationError.unsafePath }
      for (binding, scope) in zip(bindings, scopes.dropFirst(items.count + 1)) {
        guard scope.url.standardizedFileURL.resolvingSymlinksInPath() == binding.file.standardizedFileURL.resolvingSymlinksInPath(),
              try binding.validate(Data(contentsOf: scope.url)) else { return false }
      }
      try scopes[0].checkCancellation()
      return paths.allSatisfy { path in
        let target = directory.appendingPathComponent(path)
        let placeholder = target.deletingLastPathComponent().appendingPathComponent("." + target.lastPathComponent + ".icloud")
        return !FileManager.default.fileExists(atPath: target.path) && !FileManager.default.fileExists(atPath: placeholder.path)
      }
    }
  }

  private func removeDeletedEmptyFolder(id: UUID, path: String) async throws -> SharedFolderFileOutcome {
    let entity = SharedEntityIdentity(id: id, kind: .folder)
    let base = try await read(entity)
    let target = root.appendingPathComponent(path)
    if FileManager.default.fileExists(atPath: target.path), !(try FileManager.default.contentsOfDirectory(atPath: target.path)).isEmpty {
      return .init(id: id, name: path, result: .directoryNotEmpty(path), projectionError: nil)
    }
    let before = try await operationAuthority(entity: entity, paths: [path])
    if before.hasLiveDescendants { return .init(id: id, name: path, result: .needsReplanning, projectionError: nil) }
    let accepted = base.state.lifecycle == .deleted ? base : try await commit(.init(base: base, changes: [.delete]), review: false, exact: true)
    let materializer = try await makeMaterializer(entity: entity, paths: [path], receipts: operationReceipts(library: base.libraryID))
    let progress = try await materializer.progress(entity: entity, libraryID: base.libraryID)
    let operation: SharedLibraryOperation
    if let progress, progress.operation.steps == [.removeEmptyDirectory(path: path)] { operation = progress.operation }
    else {
      operation = try SharedLibraryOperation(libraryID: accepted.libraryID, entity: entity,
        inputRevision: base.fingerprint, outputRevision: SharedStateFingerprint.of(accepted.state), steps: [.removeEmptyDirectory(path: path)])
      try await Task.detached { try await materializer.recordIntent(operation) }.value
    }
    let permission = try await operationAuthority(entity: entity, paths: [path])
    if !permission.hasPendingWork && !permission.hasLiveDescendants { try await acknowledgeOperation(entity: entity, purpose: .delete) }
    let result = try await materializer.replay(operation)
    var projectionError: String?
    if result == .complete { do { _ = try await projectOutputs() } catch { projectionError = error.localizedDescription } }
    return .init(id: id, name: path, result: result, projectionError: projectionError)
  }

  public func createSharedFolder(named name: String) async throws {
    _ = try SharedLibraryIdentity.normalized(name)
    guard !name.contains("/") else { throw SharedLibraryIdentityError.invalidRelativePath }
    let views = try await snapshots(kinds: [.recording, .folder])
    let index = try SharedLibraryPathIndex(states: views.map(\.state), caseSensitive: false)
    guard index.owners(of: name).isEmpty, !FileManager.default.fileExists(atPath: root.appendingPathComponent(name).path) else {
      throw SharedLibraryOperationError.pathConflict(name)
    }
    let entity = SharedEntityIdentity(id: UUID(), kind: .folder)
    let base = try await read(entity)
    let accepted = try await edit(.init(base: base, changes: [
      .assign(field: "initialPath", value: .text(name)), .assign(field: "name", value: .text(name)), .assign(field: "parent", value: .unset)]))
    let operation = try SharedLibraryOperation(libraryID: accepted.libraryID, entity: entity,
      inputRevision: base.fingerprint, outputRevision: SharedStateFingerprint.of(accepted.state), steps: [.createDirectory(path: name)])
    let materializer = try await makeMaterializer(entity: entity, paths: [name], receipts: operationReceipts(library: accepted.libraryID))
    guard try await materializer.replay(operation) == .complete else { throw SharedLibraryOperationError.unfinishedOperation }
  }
  public func relocateRecording(filename: String, title: String? = nil, toFolder: String? = nil,
                                changeFolder: Bool = false,
                                afterMutation: @escaping @Sendable (Int) throws -> Void = { _ in }) async throws -> SharedRecordingFileOutcome {
    let source = try SharedLibraryIdentity.normalized(filename)
    let base = try await recording(at: source)
    let entity = SharedEntityIdentity(id: base.state.id, kind: .recording)
    guard base.state.lifecycle == .alive, base.state.conflicts.isEmpty else { throw SharedSidecarError.conflictedContent }
    let receipts = try operationReceipts(library: base.libraryID)
    let reader = try await makeMaterializer(entity: entity, paths: [], receipts: receipts)
    if let progress = try await reader.progress(entity: entity, libraryID: base.libraryID),
       progress.completedSteps < progress.operation.steps.count { throw SharedLibraryOperationError.unfinishedOperation }
    let basename = title ?? ((source as NSString).lastPathComponent as NSString).deletingPathExtension
    _ = try SharedLibraryIdentity.normalized(basename)
    guard !basename.contains("/") else { throw SharedLibraryIdentityError.invalidRelativePath }
    var folder = (source as NSString).deletingLastPathComponent
    var changes: [SharedLibraryMutation] = []
    if let title { changes.append(.assign(field: "title", value: .text(title))) }
    if changeFolder {
      folder = toFolder ?? ""
      if let toFolder {
        let views = try await snapshots(kinds: [.folder])
        let index = try SharedLibraryPathIndex(states: views.map(\.state), caseSensitive: false)
        guard let id = index.resolvedPaths.first(where: { $0.value == toFolder })?.key else { throw SharedLibraryPathError.unknownPath }
        changes.append(.assign(field: "folder", value: .text(id.uuidString)))
      } else { changes.append(.assign(field: "folder", value: .unset)) }
    }
    let destination = folder.isEmpty ? basename + ".mp3" : folder + "/" + basename + ".mp3"
    if source == destination { return .init(filename: source, result: .complete, projectionError: nil, view: base) }
    let all = try await snapshots(kinds: [.recording, .folder])
    let index = try SharedLibraryPathIndex(states: all.map(\.state), caseSensitive: false)
    guard index.owners(of: destination).isEmpty else { throw SharedLibraryOperationError.pathConflict(destination) }
    let sourceStem = (source as NSString).deletingPathExtension
    let destinationStem = (destination as NSString).deletingPathExtension
    let manifest = try await bind(force: true)
    let membership = try await memberRepository().load().membership
    let published = try await SharedPublishedLocations.load(root: root, manifest: manifest, membership: membership)
    var steps: [SharedLibraryOperation.Step] = []
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
        steps.append(.move(source: from, destination: to, fingerprint: SharedLibraryOperation.fingerprint(bytes)))
      } else if suffix == ".mp3" { throw CocoaError(.fileReadNoSuchFile) }
    }
    // Accept the logical intent before touching any source. Receipt replay,
    // ownership and expected bytes make each related physical phase recoverable.
    let accepted = try await edit(.init(base: base, changes: changes))
    let operation = try SharedLibraryOperation(libraryID: accepted.libraryID, entity: entity,
      inputRevision: base.fingerprint, outputRevision: SharedStateFingerprint.of(accepted.state), steps: steps)
    let materializer = try await makeMaterializer(entity: entity, paths: Array(operation.canonicalPaths),
      receipts: operationReceipts(library: accepted.libraryID), afterMutation: afterMutation)
    let result = try await materializer.replay(operation)
    var projectionError: String?
    if result == .complete {
      do { _ = try await projectOutputs() } catch { projectionError = error.localizedDescription }
    }
    return .init(filename: result == .complete ? destination : source, result: result, projectionError: projectionError, view: accepted)
  }

  public func deleteSharedRecording(filename: String, reference: SharedRecordingReference? = nil) async throws -> SharedRecordingFileOutcome {
    let source: String
    if let reference { source = try await resolve(reference) }
    else { source = try SharedLibraryIdentity.normalized(filename) }
    let base = try await recording(at: source)
    if let reference, reference.libraryID != base.libraryID || reference.entityID != base.state.id { throw SharedLibraryCoordinatorError.differentBinding }
    let entity = SharedEntityIdentity(id: base.state.id, kind: .recording)
    guard base.state.conflicts.isEmpty else { throw SharedSidecarError.conflictedContent }
    let receipts = try operationReceipts(library: base.libraryID)
    let reader = try await makeMaterializer(entity: entity, paths: [], receipts: receipts)
    if let progress = try await reader.progress(entity: entity, libraryID: base.libraryID),
       progress.completedSteps < progress.operation.steps.count {
      if progress.operation.steps.allSatisfy({ if case .trash = $0 { return true }; return false }) {
        return try await resumeRecordingOperation(id: entity.id)
      }
      throw SharedLibraryOperationError.unfinishedOperation
    }
    let manifest = try await bind(force: true)
    let membership = try await memberRepository().load().membership
    let published = try await SharedPublishedLocations.load(root: root, manifest: manifest, membership: membership)
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
    let accepted = base.state.lifecycle == .deleted ? base : try await edit(.init(base: base, changes: [.delete]))
    let operation = try SharedLibraryOperation(libraryID: accepted.libraryID, entity: entity,
      inputRevision: base.fingerprint, outputRevision: SharedStateFingerprint.of(accepted.state), steps: steps)
    let permission = try await operationAuthority(entity: entity, paths: Array(operation.canonicalPaths))
    if !permission.hasPendingWork { try await acknowledgeOperation(entity: entity, purpose: .delete) }
    let materializer = try await makeMaterializer(entity: entity, paths: Array(operation.canonicalPaths), receipts: receipts)
    let result = try await materializer.replay(operation)
    var projectionError: String?
    if result == .complete { do { _ = try await projectOutputs() } catch { projectionError = error.localizedDescription } }
    return .init(filename: source, result: result, projectionError: projectionError, view: accepted)
  }
  public func acknowledgeOperation(entity: SharedEntityIdentity, purpose: SharedDestructivePurpose) async throws {
    let manifest = try await bind(force: true)
    guard let directory = witnessDirectory, let gate else { throw SharedLibraryOperationError.invalidOperation }
    let witness = SharedOwnerWitness(directory: directory, libraryID: manifest.libraryID, writerID: writerID)
    _ = try await SharedOperationAcknowledgmentStore(root: root, libraryID: manifest.libraryID, writer: writerID, witness: witness, gate: gate)
      .acknowledge(purpose: purpose, authority: { try await self.operationAuthority(entity: entity, paths: []) })
    revokeAuthority()
  }

  /// Resume the exact locally recorded physical plan; never infer completion
  /// from a new filename or recreate an audio original after an interruption.
  public func resumeRecordingOperation(id: UUID) async throws -> SharedRecordingFileOutcome {
    let entity = SharedEntityIdentity(id: id, kind: .recording)
    var view = try await read(entity)
    let receipts = try operationReceipts(library: view.libraryID)
    let reader = try await makeMaterializer(entity: entity, paths: [], receipts: receipts)
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
    var result: SharedMaterializationResult
    if progress.completedSteps == progress.operation.steps.count {
      if try SharedStateFingerprint.of(view.state) != progress.operation.outputRevision {
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
      let permission = try await operationAuthority(entity: entity, paths: [])
      if !permission.hasPendingWork && view.state.conflicts.isEmpty {
        switch audio {
        case .trash where view.state.lifecycle == .deleted: try await acknowledgeOperation(entity: entity, purpose: .delete)
        case .replaceAudio(_, _, _, _, false) where view.state.lifecycle == .alive: try await acknowledgeOperation(entity: entity, purpose: .replaceAudio)
        default: break
        }
      }
      let materializer = try await makeMaterializer(entity: entity, paths: Array(progress.operation.canonicalPaths), receipts: receipts)
      result = try await materializer.replay(progress.operation)
    }
    var projectionError: String?
    if result == .complete {
      if let selected, view.state.value(for: "audioPublished") != .text(selected) {
        view = try await edit(.init(base: try await read(entity), changes: [.assign(field: "audioPublished", value: .text(selected))]))
      }
      do { _ = try await projectOutputs() } catch { projectionError = error.localizedDescription }
    }
    return .init(filename: result == .complete ? destination : source, result: result, projectionError: projectionError, view: view)
  }

  public func projectOutputs(beforeWrite: @escaping @Sendable () async -> Void = {},
                             afterOutput: @escaping @Sendable (Int) throws -> Void = { _ in }) async throws -> SharedProjectionWriteResult {
    let context = try await projectionContext()
    return try await SharedLibraryProjectionWriter.project(context, writer: writerID, beforeWrite: beforeWrite, afterOutput: afterOutput)
  }
  private func projectionContext() async throws -> SharedLibraryProjectionContext {
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
    let published = try await SharedPublishedLocations.load(root: root, manifest: manifest, membership: membership)
    let pathStates = views.map { view -> SharedEntityState in
      let fields = view.state.kind == .folder ? ["name", "parent"] : ["title", "folder"]
      return fields.contains(where: { view.state.fields[$0]?.isConflicted == true }) ? (view.confirmedState ?? view.state) : view.state
    }
    let index = try SharedLibraryPathIndex(states: pathStates, caseSensitive: false)
    for view in views where view.state.kind == .folder && view.state.lifecycle == .alive {
      if let physical = view.state.fields["physicalPath"],
         physical.isConflicted || physical.resolvedValue != index.resolvedPaths[view.state.id].map(SharedFieldValue.text) { throw SharedLibraryOperationError.unfinishedOperation }
    }
    for view in views where view.state.kind == .recording && view.state.lifecycle == .alive {
      if let published = view.state.fields["audioPublished"],
         published.isConflicted || published.resolvedValue != view.state.value(for: "audioFingerprint") { throw SharedLibraryOperationError.unfinishedOperation }
      guard let destination = index.resolvedPaths[view.state.id] else { continue }
      for source in published.recordings[view.state.id] ?? [] where source != destination {
        let stem = (source as NSString).deletingPathExtension
        for suffix in [".mp3", ".transcript.json", ".summary.json", ".txt", ".transcript.md", ".summary.md"] {
          let url = root.appendingPathComponent(stem + suffix)
          let placeholder = url.deletingLastPathComponent().appendingPathComponent("." + url.lastPathComponent + ".icloud")
          guard !FileManager.default.fileExists(atPath: url.path), !FileManager.default.fileExists(atPath: placeholder.path) else {
            throw SharedLibraryOperationError.unfinishedOperation
          }
        }
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
                 validate: { try witness.checkpointFingerprint() == checkpoint }, membership: membership)
  }

  public func makeMaterializer(
    entity: SharedEntityIdentity, paths: [String], receipts: URL,
    afterMutation: @escaping @Sendable (Int) throws -> Void = { _ in }
  ) async throws -> SharedLibraryMaterializer {
    _ = try await bind(force: true)
    guard let gate else { throw SharedLibraryOperationError.invalidOperation }
    return SharedLibraryMaterializer(root: root, receipts: receipts,
      authority: { try await self.operationAuthority(entity: entity, paths: paths) },
      trash: trash, afterMutation: afterMutation, gate: gate)
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
    guard let selected = snapshots.first(where: { $0.state.id == entity.id && $0.state.kind == entity.kind }) else {
      throw SharedSidecarError.unknownRecording
    }
    let sensitivity = (try? root.resourceValues(forKeys: [.volumeSupportsCaseSensitiveNamesKey]))?.volumeSupportsCaseSensitiveNames ?? false
    let locations = try await SharedPublishedLocations.load(root: root, manifest: manifest, membership: membership)
    let knownIDs = Set(snapshots.filter { $0.state.kind == .recording }.map { $0.state.id })
    guard Set(locations.recordings.keys).isSubset(of: knownIDs) else { throw SharedProjectionWriteError.untracked("library.json") }
    let index = try SharedLibraryPathIndex(states: snapshots.map(\.state), caseSensitive: sensitivity, retainedLocations: locations.recordings)
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
    if entity.kind == .folder, selected.state.value(for: "physicalPath") != selected.state.value(for: "name") {
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
  private func commit(_ edit: SharedCoordinatorEdit, review: Bool, exact: Bool = false) async throws
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
      }
    } else { validation = nil }
    let accepted = try await repository.commit(.init(base: fresh, changes: edit.changes, validation: validation))
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
    beginTransition(); defer { endTransition() }
    let snapshot = try await read(entity)
    guard snapshot.state.lifecycle == .alive else { throw SharedLibraryCoordinatorError.staleJob }
    if output != nil, !(try await mayEdit()) { throw SharedLibraryCoordinatorError.enrollmentPending }
    try Self.validateProcessingState(snapshot.state, input: input, output: output)
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
    let current = try await read(entity)
    guard current.libraryID == snapshot.libraryID, current.state.lifecycle == .alive,
          try Self.lifecycleRevision(current.state) == Self.lifecycleRevision(snapshot.state),
          try Self.inputRevision(current.state, component: input) == Self.inputRevision(snapshot.state, component: input) else { throw SharedLibraryCoordinatorError.staleJob }
    try Task.checkCancellation()
    let title: String
    if case .text(let value)? = snapshot.state.value(for: "title") { title = value } else { title = "" }
    let parsed = FilenameParsing.parse(title + ".mp3").mode
    let mode = metadata.mode ?? (parsed == .unknown ? "" : parsed.rawValue)
    let token = SharedLibraryJobToken(
      id: UUID(), library: snapshot.libraryID, entity: entity,
      lifecycle: try Self.lifecycleRevision(snapshot.state),
      component: input, input: try Self.inputRevision(snapshot.state, component: input), output: output,
      snapshot: snapshot, inputFile: inputFile, recordingMode: mode)
    if let jobGate = try localJobGate(library: snapshot.libraryID, entity: entity.id) {
      guard let gate, let directory = witnessDirectory else { throw SharedLibraryOperationError.invalidOperation }
      let witness = SharedOwnerWitness(directory: directory, libraryID: snapshot.libraryID, writerID: writerID)
      let checkpoint = try witness.checkpointFingerprint()
      let manifest = try await bind(force: true)
      let bindings = try repository.readBindings(current.repository) + [SharedMaterializationBinding(file: root.appendingPathComponent(".docktape/format.json")) { bytes in
        guard let value = try? JSONDecoder().decode(SharedBootstrapManifest.self, from: bytes) else { return false }
        return value.complete && value.libraryID == manifest.libraryID && value.fingerprint == manifest.fingerprint
      }]
      let items = try gate.items(outside: root)
      let root = self.root
      let descriptor = try await CoordinatedFileAccess().withWrites(items, reading: bindings.map(\.file)) { scopes in
        try gate.validate(scopes[0], outside: root)
        guard try witness.checkpointFingerprint() == checkpoint else { throw SharedLibraryCoordinatorError.staleJob }
        for (binding, scope) in zip(bindings, scopes.dropFirst(items.count)) {
          guard scope.url.standardizedFileURL.resolvingSymlinksInPath() == binding.file.standardizedFileURL.resolvingSymlinksInPath(),
                try binding.validate(Data(contentsOf: scope.url)) else { throw SharedLibraryCoordinatorError.staleJob }
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
    let published = try await SharedPublishedLocations.load(root: root, manifest: manifest, membership: membership)
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
