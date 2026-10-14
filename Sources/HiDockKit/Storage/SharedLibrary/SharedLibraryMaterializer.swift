// © 2026 High Gain Design. All rights reserved.
import CryptoKit
import Foundation
import Darwin

/// Local receipts are outside the provider folder. Accepted user state is always
/// in the shared repository; a receipt only tracks its physical projection.
public actor SharedLibraryMaterializer {
  public typealias Authority = @Sendable () async throws -> SharedMaterializationAuthority
  private let root: URL
  private let receipts: URL
  private let authority: Authority
  private let trash: @Sendable (URL) throws -> Void
  private let afterMutation: @Sendable (Int) throws -> Void
  private let access = CoordinatedFileAccess()
  private let gate: SharedLibraryLocalGate?
  private var active: Set<UUID> = []
  public init(
    root: URL, receipts: URL, authority: @escaping Authority,
    trash: @escaping @Sendable (URL) throws -> Void = {
      try SharedLibraryMaterializer.moveToTrash($0)
    },
    afterMutation: @escaping @Sendable (Int) throws -> Void = { _ in },
    gate: SharedLibraryLocalGate? = nil
  ) {
    self.root = root.standardizedFileURL.resolvingSymlinksInPath()
    self.receipts = receipts.standardizedFileURL.resolvingSymlinksInPath()
    self.authority = authority
    self.trash = trash
    self.afterMutation = afterMutation
    self.gate = gate
  }

  /// Persist an already accepted semantic intent before the next cancellable
  /// provider read. This writes only the bounded local replay plan.
  func recordIntent(_ operation: SharedLibraryOperation) async throws {
    try operation.validate()
    guard !Self.contained(receipts, in: root) else { throw SharedLibraryOperationError.unsafePath }
    try FileManager.default.createDirectory(at: receipts, withIntermediateDirectories: true)
    let file = receipts.appendingPathComponent(operation.entity.id.uuidString + ".json")
    let items = [CoordinatedFileAccess.WriteItem(file)] + (try gate?.items(outside: root) ?? [])
    let receipts = self.receipts, root = self.root, gate = self.gate
    try await access.withWrites(items) { scopes in
      guard Self.contained(scopes[0].url, in: receipts) else { throw SharedLibraryOperationError.unsafePath }
      if let gate { try gate.validate(scopes[1], outside: root) }
      if FileManager.default.fileExists(atPath: scopes[0].url.path) {
        let previous = try SharedOperationReceipt.decode(Data(contentsOf: scopes[0].url))
        guard previous.operation.libraryID == operation.libraryID, previous.operation.entity == operation.entity else { throw SharedLibraryOperationError.differentBinding }
        if previous.operation == operation { return }
        guard previous.completed == previous.operation.steps.count else { throw SharedLibraryOperationError.unfinishedOperation }
      }
      try scopes[0].checkCancellation()
      try SharedOperationReceipt(operation).encoded().write(to: scopes[0].url, options: .atomic)
    }
  }

  private func readAuthority() async throws -> SharedMaterializationAuthority {
    let delays: [Duration] = [.milliseconds(25), .milliseconds(50), .milliseconds(100), .milliseconds(200), .milliseconds(400), .milliseconds(800)]
    for attempt in 0...delays.count {
      do {
        let permission = try await authority()
        guard !permission.revisionLease.isRevoked else { throw SharedLibraryOperationError.staleAuthority }
        return permission
      }
      catch SharedLibraryOperationError.staleAuthority {
        guard attempt < delays.count else { throw SharedLibraryOperationError.staleAuthority }
        try await Task.sleep(for: delays[attempt])
      }
    }
    throw SharedLibraryOperationError.staleAuthority
  }
  private func checkedAuthority(for operation: SharedLibraryOperation) async throws
    -> (permission: SharedMaterializationAuthority, pending: SharedMaterializationResult?)
  {
    for attempt in 0...3 {
      let permission = try await readAuthority()
      let pending = try Self.check(operation, authority: permission)
      // The lease can be revoked after acquisition returns to this actor.
      // Re-read only invalidated proof; actual intent changes stay pending.
      if pending == .needsReplanning, permission.revisionLease.isRevoked, attempt < 3 {
        try await Task.sleep(for: .milliseconds(25))
        continue
      }
      return (permission, pending)
    }
    throw SharedLibraryOperationError.staleAuthority
  }
  public func replay(_ operation: SharedLibraryOperation) async throws
    -> SharedMaterializationResult
  {
    try operation.validate()
    guard active.insert(operation.entity.id).inserted else {
      throw SharedLibraryOperationError.unfinishedOperation
    }
    defer { active.remove(operation.entity.id) }
    try Self.checkRoot(root)
    guard !Self.contained(receipts, in: root) else { throw SharedLibraryOperationError.unsafePath }
    let initial = try await checkedAuthority(for: operation)
    let initialPending = initial.pending
    if let pending = initialPending, pending != .waitingForAcknowledgments && pending != .waitingForActiveWork { return pending }
    // The accepted delete plan must survive an offline cohort or active job.
    // Save its expected hashes before waiting, without touching provider files.
    try FileManager.default.createDirectory(at: receipts, withIntermediateDirectories: true)
    let receiptURL = receipts.appendingPathComponent(operation.entity.id.uuidString + ".json")
    let initialReceipt = try await access.withWrite(at: receiptURL) { scope in
      guard Self.contained(scope.url, in: self.receipts) else {
        throw SharedLibraryOperationError.unsafePath
      }
      if FileManager.default.fileExists(atPath: scope.url.path) {
        let old = try SharedOperationReceipt.decode(Data(contentsOf: scope.url))
        guard old.operation.libraryID == operation.libraryID,
          old.operation.entity == operation.entity
        else {
          throw SharedLibraryOperationError.differentBinding
        }
        if old.operation == operation { return old }
        guard old.completed == old.operation.steps.count else {
          throw SharedLibraryOperationError.unfinishedOperation
        }
      }
      let fresh = SharedOperationReceipt(operation)
      try scope.checkCancellation()
      try fresh.encoded().write(to: scope.url, options: .atomic)
      return fresh
    }
    if let pending = initialPending { return pending }
    var receipt = initialReceipt
    var staleProofRetries = 0
    while receipt.completed < operation.steps.count {
      try Task.checkCancellation()
      try Self.checkRoot(root)
      let checkedCurrent = try await checkedAuthority(for: operation)
      if let pending = checkedCurrent.pending { return pending }
      let current = checkedCurrent.permission
      let step = operation.steps[receipt.completed]
      let items = try Self.items(step, root: root)
      // Preparation stays outside the receipt/source lease. Each File
      // Provider wait is cancellable and unrelated operations remain free.
      for item in items where FileManager.default.fileExists(atPath: item.url.path) {
        _ = try await RecordingFileAccess().waitUntilAvailable(at: item.url, knownToExist: true)
      }
      for binding in current.additionalBindings + (current.binding.map { [$0] } ?? []) {
        guard Self.contained(binding.file, in: root) else { throw SharedLibraryOperationError.unsafePath }
        guard try await RecordingFileAccess().waitUntilAvailable(at: binding.file, knownToExist: true) else {
          return .waitingForFile(binding.file.lastPathComponent)
        }
      }
      let checkedFresh = try await checkedAuthority(for: operation)
      if let pending = checkedFresh.pending { return pending }
      let fresh = checkedFresh.permission
      let index = receipt.completed
      let trash = self.trash
      let afterMutation = self.afterMutation
      let root = self.root
      let receipts = self.receipts
      let gate = self.gate
      let outcome: PhaseOutcome
      do {
        let gateItems = try gate?.items(outside: root) ?? []
        let bindings = fresh.additionalBindings + (fresh.binding.map { [$0] } ?? [])
        let bindingReads = bindings.map(\.file)
        outcome = try await access.withWrites([.init(receiptURL)] + items + gateItems, reading: bindingReads) {
          scopes -> PhaseOutcome in
          if let gate { try gate.validate(scopes[items.count + 1], outside: root) }
          for (index, binding) in bindings.enumerated() {
            let control = scopes[1 + items.count + gateItems.count + index]
            guard Self.contained(control.url, in: root),
                  control.url.standardizedFileURL.resolvingSymlinksInPath() == binding.file.standardizedFileURL.resolvingSymlinksInPath() else {
              throw SharedLibraryOperationError.unsafePath
            }
            guard try binding.validate(Data(contentsOf: control.url)) else { return .pending(.needsReplanning) }
          }
          guard !fresh.revisionLease.isRevoked, try fresh.validateLocalCommit() else { return .pending(.needsReplanning) }
          try Self.checkRoot(root)
          guard Self.contained(scopes[0].url, in: receipts) else {
            throw SharedLibraryOperationError.unsafePath
          }
          for scope in scopes { try scope.checkCancellation() }
          var actual = try SharedOperationReceipt.decode(Data(contentsOf: scopes[0].url))
          guard actual.operation == operation else {
            throw SharedLibraryOperationError.unfinishedOperation
          }
          // Another process may have finished this phase while waiting.
          if actual.completed != index { return .advanced(actual) }
          let files = Array(scopes.dropFirst().prefix(items.count))
          for file in files {
            guard Self.contained(file.url, in: root) else {
              throw SharedLibraryOperationError.unsafePath
            }
          }
          var jobDescriptors: [Int32] = []
          defer { for descriptor in jobDescriptors { Darwin.close(descriptor) } }
          let jobGates = fresh.jobGates.isEmpty ? (fresh.jobGate.map { [$0] } ?? []) : fresh.jobGates
          for jobGate in jobGates {
            guard let acquired = try jobGate.acquireExclusive() else { return .pending(.waitingForActiveWork) }
            jobDescriptors.append(acquired)
          }
          // Persist intent before the physical commit. Recovery still
          // verifies exact bytes/ownership, never merely file existence.
          let replaying = actual.attempting
          var prepared = actual
          prepared.attempting = true
          let preparedBytes = try prepared.encoded()
          let receiptScope = scopes[0]
          let phase = try Self.apply(
            step, files: files, authority: fresh,
            replaying: replaying, trash: trash,
            beforeMutation: {
              guard !fresh.revisionLease.isRevoked, try fresh.validateLocalCommit() else {
                throw SharedLibraryOperationError.staleAuthority
              }
              try receiptScope.checkCancellation()
              try preparedBytes.write(to: receiptScope.url, options: .atomic)
            })
          if let pending = phase.pending { return .pending(pending) }
          if phase.changed { try afterMutation(index) }
          actual.completed += 1
          actual.attempting = false
          // A committed change returns its accepted receipt even if task
          // cancellation raced with the filesystem mutation.
          try actual.encoded().write(to: scopes[0].url, options: .atomic)
          return .advanced(actual)
        }
      } catch SharedLibraryOperationError.staleAuthority {
        // Refresh invalidation must follow the same fresh-proof path as a
        // failed coordinated binding. No mutation occurred under that lease.
        outcome = .pending(.needsReplanning)
      }
      switch outcome {
      case .advanced(let next): receipt = next; staleProofRetries = 0
      case .pending(let result):
        if result == .needsReplanning, staleProofRetries < 3 {
          let current = try await checkedAuthority(for: operation)
          if current.pending == nil {
            staleProofRetries += 1
            try await Task.sleep(for: .milliseconds(25))
            continue
          }
        }
        return result
      }
    }
    return .complete
  }
  public func progress(entity: SharedEntityIdentity, libraryID: UUID) async throws
    -> SharedLibraryOperationProgress?
  {
    let file = receipts.appendingPathComponent(entity.id.uuidString + ".json")
    guard FileManager.default.fileExists(atPath: file.path) else { return nil }
    let receipts = self.receipts
    return try await access.withRead(at: file) { scope in
      guard Self.contained(scope.url, in: receipts) else {
        throw SharedLibraryOperationError.unsafePath
      }
      let value = try SharedOperationReceipt.decode(Data(contentsOf: scope.url))
      guard value.operation.entity == entity, value.operation.libraryID == libraryID else {
        throw SharedLibraryOperationError.differentBinding
      }
      return .init(
        operation: value.operation, completedSteps: value.completed,
        phaseWasAttempted: value.attempting)
    }
  }

  /// Recompute from accepted state plus current physical paths. Replanning
  /// changes metadata only and cannot silently drop a surviving owned file.
  public func replan(_ replacement: SharedLibraryOperation, replacing previousID: UUID) async throws
  {
    try replacement.validate()
    guard active.insert(replacement.entity.id).inserted else {
      throw SharedLibraryOperationError.unfinishedOperation
    }
    defer { active.remove(replacement.entity.id) }
    let current = try await authority()
    guard try Self.check(replacement, authority: current) == nil else {
      throw SharedLibraryOperationError.invalidOperation
    }
    let file = receipts.appendingPathComponent(replacement.entity.id.uuidString + ".json")
    let root = self.root
    let receipts = self.receipts
    let newPaths = Set(try replacement.steps.flatMap { try Self.items($0, root: root).map(\.url) })
    try await access.withWrite(at: file) { scope in
      try Self.checkRoot(root)
      guard Self.contained(scope.url, in: receipts) else {
        throw SharedLibraryOperationError.unsafePath
      }
      guard !current.revisionLease.isRevoked else {
        throw SharedLibraryOperationError.staleAuthority
      }
      let old = try SharedOperationReceipt.decode(Data(contentsOf: scope.url))
      guard old.operation.id == previousID, old.operation.entity == replacement.entity,
        old.operation.libraryID == replacement.libraryID,
        replacement.inputRevision == old.operation.outputRevision
      else { throw SharedLibraryOperationError.unfinishedOperation }
      for item in try old.operation.steps.flatMap({ try Self.items($0, root: root) }) {
        let attributes = try? FileManager.default.attributesOfItem(atPath: item.url.path)
        let placeholder = item.url.deletingLastPathComponent().appendingPathComponent(
          "." + item.url.lastPathComponent + ".icloud")
        let survivingFile =
          attributes?[.type] as? FileAttributeType == .typeRegular
          || FileManager.default.fileExists(atPath: placeholder.path)
        guard !survivingFile || newPaths.contains(item.url) else {
          throw SharedLibraryOperationError.unfinishedOperation
        }
      }
      try scope.checkCancellation()
      try SharedOperationReceipt(replacement).encoded().write(to: scope.url, options: .atomic)
    }
  }

  public func discardStagedAudio(
    _ staged: String, entity: SharedEntityIdentity, fingerprint: String
  ) async throws {
    guard active.insert(entity.id).inserted else {
      throw SharedLibraryOperationError.unfinishedOperation
    }
    defer { active.remove(entity.id) }
    let prefix = ".docktape/staging/" + entity.id.uuidString + "/"
    guard staged.hasPrefix(prefix), staged.hasSuffix(".mp3"),
      UUID(uuidString: String(staged.dropFirst(prefix.count).dropLast(4))) != nil
    else {
      throw SharedLibraryOperationError.unsafePath
    }
    let current = try await authority()
    guard current.state.id == entity.id, current.state.kind == entity.kind,
      current.state.conflicts.isEmpty,
      current.state.value(for: "audioFingerprint") != .text(fingerprint)
    else {
      throw SharedLibraryOperationError.invalidOperation
    }
    let file = root.appendingPathComponent(staged)
    let root = self.root
    try await access.withWrite(at: file) { scope in
      try Self.checkRoot(root)
      guard Self.contained(scope.url, in: root) else {
        throw SharedLibraryOperationError.unsafePath
      }
      guard !current.revisionLease.isRevoked else {
        throw SharedLibraryOperationError.staleAuthority
      }
      guard let actual = try Self.hash(scope) else { return }
      guard actual == fingerprint else {
        throw SharedLibraryOperationError.contentChanged("staged audio")
      }
      try scope.checkCancellation()
      try FileManager.default.removeItem(at: scope.url)
    }
  }

  public func cleanupReviewedVersion(
    _ candidate: SharedExternalContent, operation: SharedLibraryOperation,
    canonicalPath: String, versions: RecordingFileVersionAccess = .init()
  ) async throws {
    guard let id = candidate.versionID, candidate.libraryID == operation.libraryID,
      candidate.entity == operation.entity
    else { throw SharedLibraryOperationError.differentBinding }
    _ = try SharedLibraryIdentity.normalized(canonicalPath)
    let canonical = root.appendingPathComponent(canonicalPath).standardizedFileURL
      .resolvingSymlinksInPath()
    guard Self.contained(canonical, in: root),
      candidate.url.standardizedFileURL.resolvingSymlinksInPath() == canonical
    else {
      throw SharedLibraryOperationError.unsafePath
    }
    let current = try await authority()
    guard try Self.check(operation, authority: current) == nil,
      current.state.value(for: "externalAdoption." + candidate.component.rawValue)
        == .text(candidate.fingerprint),
      current.state.currentDocument(for: candidate.component)?.json == candidate.document.json
    else {
      throw SharedLibraryOperationError.invalidOperation
    }
    try Self.owner(canonicalPath, authority: current, required: true)
    guard
      let bytes = operation.steps.compactMap({ step -> Data? in
        if case .write(let path, _, let bytes) = step, path == canonicalPath { return bytes }
        return nil
      }).last
    else { throw SharedLibraryOperationError.invalidOperation }
    let canonicalFingerprint = SharedLibraryOperation.fingerprint(bytes)
    let receiptURL = receipts.appendingPathComponent(operation.entity.id.uuidString + ".json")
    guard FileManager.default.fileExists(atPath: receiptURL.path) else {
      throw SharedLibraryOperationError.unfinishedOperation
    }
    let root = self.root
    let receipts = self.receipts
    try await access.withWrites([.init(receiptURL), .init(canonical)]) { scopes in
      try Self.checkRoot(root)
      guard Self.contained(scopes[0].url, in: receipts), Self.contained(scopes[1].url, in: root)
      else {
        throw SharedLibraryOperationError.unsafePath
      }
      guard !current.revisionLease.isRevoked else {
        throw SharedLibraryOperationError.staleAuthority
      }
      var receipt = try SharedOperationReceipt.decode(Data(contentsOf: scopes[0].url))
      guard receipt.operation == operation, receipt.completed == operation.steps.count,
        !receipt.attempting
      else {
        throw SharedLibraryOperationError.unfinishedOperation
      }
      guard try Self.hash(scopes[1]) == canonicalFingerprint else {
        throw SharedLibraryOperationError.contentChanged(canonicalPath)
      }
      // This durable post-materialization proof survives a crash between
      // exact-version removal and the caller observing its result.
      receipt.reviewedCleanups[id] = candidate.fingerprint + ":" + canonicalFingerprint
      try scopes[0].checkCancellation()
      try receipt.encoded().write(to: scopes[0].url, options: .atomic)
    }
    try await versions.removeReviewed(
      at: canonical, id: id, sourceFingerprint: candidate.fingerprint,
      canonicalFingerprint: canonicalFingerprint, lease: current.revisionLease)
  }

  /// Stage only a newly supplied input. Its entity-scoped path is consumed by
  /// replacement or explicit cancellation; there is no copy of old audio.
  public func stageNewAudio(_ bytes: Data, entity: SharedEntityIdentity) async throws -> String {
    let current = try await authority()
    guard current.state.id == entity.id, current.state.kind == entity.kind,
      current.state.lifecycle == .alive, current.state.conflicts.isEmpty
    else {
      throw SharedLibraryOperationError.invalidOperation
    }
    try Self.checkRoot(root)
    var directory = root
    for name in [".docktape", "staging", entity.id.uuidString] {
      directory.appendPathComponent(name)
      let path = directory
      let root = self.root
      guard Self.contained(path, in: root) else { throw SharedLibraryOperationError.unsafePath }
      try await access.withWrite(at: path) { scope in
        try Self.checkRoot(root)
        guard Self.contained(scope.url, in: root) else {
          throw SharedLibraryOperationError.unsafePath
        }
        if FileManager.default.fileExists(atPath: scope.url.path) {
          guard
            (try FileManager.default.attributesOfItem(atPath: scope.url.path)[.type]
              as? FileAttributeType) == .typeDirectory
          else {
            throw SharedLibraryOperationError.unsafePath
          }
        } else {
          try scope.checkCancellation()
          try FileManager.default.createDirectory(at: scope.url, withIntermediateDirectories: false)
        }
      }
    }
    let relative = ".docktape/staging/" + entity.id.uuidString + "/" + UUID().uuidString + ".mp3"
    let file = root.appendingPathComponent(relative)
    let root = self.root
    try await access.withWrite(at: file) { scope in
      try Self.checkRoot(root)
      guard Self.contained(scope.url, in: root),
        !FileManager.default.fileExists(atPath: scope.url.path)
      else {
        throw SharedLibraryOperationError.unsafePath
      }
      try scope.checkCancellation()
      try bytes.write(to: scope.url, options: .atomic)
    }
    return relative
  }

  private enum PhaseOutcome: Sendable {
    case advanced(SharedOperationReceipt)
    case pending(SharedMaterializationResult)
  }
  private struct Phase {
    let changed: Bool
    let pending: SharedMaterializationResult?
  }
  private static func check(
    _ operation: SharedLibraryOperation, authority: SharedMaterializationAuthority
  ) throws -> SharedMaterializationResult? {
    guard operation.libraryID == authority.libraryID,
      authority.membership.libraryID == authority.libraryID,
      operation.entity.id == authority.state.id, operation.entity.kind == authority.state.kind
    else {
      throw SharedLibraryOperationError.differentBinding
    }
    if let allowed = authority.allowedPaths, let denied = operation.canonicalPaths.subtracting(allowed).sorted().first {
      throw SharedLibraryOperationError.pathConflict(denied)
    }
    guard !authority.revisionLease.isRevoked, authority.state.conflicts.isEmpty,
      try SharedLibraryOperation.matchesRevision(operation.outputRevision, state: authority.state)
    else { return .needsReplanning }
    for step in operation.steps {
      switch step {
      case .trash:
        guard authority.mayDestroy(.delete) else { return .waitingForAcknowledgments }
      case .removeEmptyDirectory:
        if authority.hasLiveDescendants { return .needsReplanning }
        if authority.state.lifecycle == .deleted {
          guard authority.mayDestroy(.delete) else { return .waitingForAcknowledgments }
        } else if authority.state.lifecycle != .alive {
          return .needsReplanning
        }
      case .publishAudio(_, _, let selected):
        guard authority.state.lifecycle == .alive,
          authority.state.value(for: "audioFingerprint") == .text(selected)
        else {
          return .needsReplanning
        }
      case .replaceAudio(_, _, _, let selected, let repair):
        guard authority.state.lifecycle == .alive,
          authority.state.value(for: "audioFingerprint") == .text(selected)
        else {
          return .needsReplanning
        }
        if !repair && !authority.mayDestroy(.replaceAudio) { return .waitingForAcknowledgments }
      case .moveDirectory:
        guard authority.directoryScopeMatches, authority.state.lifecycle == .alive else { return .needsReplanning }
        if authority.hasPendingWork { return .waitingForActiveWork }
      case .move:
        if authority.hasPendingWork { return .waitingForActiveWork }
        guard authority.state.lifecycle == .alive else { return .needsReplanning }
      default:
        guard authority.state.lifecycle == .alive else { return .needsReplanning }
      }
    }
    return nil
  }
  private static func items(_ step: SharedLibraryOperation.Step, root: URL) throws
    -> [CoordinatedFileAccess.WriteItem]
  {
    let paths: [(String, CoordinatedFileAccess.WriteMode)]
    switch step {
    case .move(let source, let destination, _), .moveDirectory(let source, let destination, _):
      paths = [(source, .moving), (destination, .replacing)]
    case .write(let path, _, _): paths = [(path, .replacing)]
    case .trash(let path, _): paths = [(path, .deleting)]
    case .removeEmptyDirectory(let path): paths = [(path, .deleting)]
    case .createDirectory(let path): paths = [(path, .merging)]
    case .replaceAudio(let path, let staged, _, _, _), .publishAudio(let path, let staged, _):
      paths = [(path, .replacing), (staged, .moving)]
    }
    return try paths.map { path, mode in
      let url = root.appendingPathComponent(path).standardizedFileURL.resolvingSymlinksInPath()
      guard contained(url, in: root) else { throw SharedLibraryOperationError.unsafePath }
      return .init(url, mode: mode)
    }
  }
  private static func owner(
    _ path: String, authority: SharedMaterializationAuthority, required: Bool
  ) throws {
    let owners = authority.pathOwners[path] ?? []
    guard owners.isEmpty ? !required : owners == [authority.state.id] else {
      throw SharedLibraryOperationError.pathConflict(path)
    }
  }
  private static func hash(_ scope: CoordinatedFileAccess.Scope, checkCancellation: Bool = true)
    throws -> String?
  {
    guard FileManager.default.fileExists(atPath: scope.url.path) else { return nil }
    let file = try FileHandle(forReadingFrom: scope.url)
    defer { try? file.close() }
    var digest = SHA256()
    while true {
      if checkCancellation { try scope.checkCancellation() }
      let bytes = try file.read(upToCount: 1024 * 1024) ?? Data()
      if bytes.isEmpty { break }
      digest.update(data: bytes)
    }
    return digest.finalize().map { String(format: "%02x", $0) }.joined()
  }
  private static func apply(
    _ step: SharedLibraryOperation.Step, files: [CoordinatedFileAccess.Scope],
    authority: SharedMaterializationAuthority, replaying: Bool,
    trash: @Sendable (URL) throws -> Void,
    beforeMutation: () throws -> Void
  ) throws -> Phase {
    let fm = FileManager.default
    switch step {
    case .move(let source, let destination, let expected):
      try owner(source, authority: authority, required: true)
      try owner(destination, authority: authority, required: false)
      let sourceHash = try hash(files[0])
      let destinationHash = try hash(files[1])
      if let destinationHash {
        guard destinationHash == expected,
          authority.pathOwners[destination] == [authority.state.id]
            || (replaying && sourceHash == nil)
        else {
          throw SharedLibraryOperationError.pathConflict(destination)
        }
        if let sourceHash {
          guard sourceHash == expected else {
            throw SharedLibraryOperationError.contentChanged(source)
          }
          try files[0].checkCancellation()
          try beforeMutation()
          try fm.removeItem(at: files[0].url)
          return .init(changed: true, pending: nil)
        }
        return .init(changed: false, pending: nil)
      }
      guard let sourceHash else { return .init(changed: false, pending: .waitingForFile(source)) }
      guard sourceHash == expected else { throw SharedLibraryOperationError.contentChanged(source) }
      try files[0].checkCancellation()
      try beforeMutation()
      try fm.moveItem(at: files[0].url, to: files[1].url)
      files[0].didMove(to: files[1].url)
      return .init(changed: true, pending: nil)
    case .moveDirectory(let source, let destination, let expected):
      try owner(source, authority: authority, required: true)
      try owner(destination, authority: authority, required: false)
      let hasSource = fm.fileExists(atPath: files[0].url.path)
      let hasDestination = fm.fileExists(atPath: files[1].url.path)
      if hasDestination {
        guard !hasSource, replaying,
              try SharedDirectoryInventory.capture(at: files[1].url) == expected else { throw SharedLibraryOperationError.pathConflict(destination) }
        return .init(changed: false, pending: nil)
      }
      guard hasSource else { return .init(changed: false, pending: .waitingForFile(source)) }
      guard try SharedDirectoryInventory.capture(at: files[0].url) == expected else { throw SharedLibraryOperationError.contentChanged(source) }
      try files[0].checkCancellation()
      try beforeMutation()
      try fm.moveItem(at: files[0].url, to: files[1].url)
      files[0].didMove(to: files[1].url)
      return .init(changed: true, pending: nil)
    case .write(let path, let expected, let bytes):
      try owner(path, authority: authority, required: false)
      let actual = try hash(files[0])
      let selected = SharedLibraryOperation.fingerprint(bytes)
      if actual == selected, authority.pathOwners[path] == [authority.state.id] || replaying {
        return .init(changed: false, pending: nil)
      }
      guard actual == expected else { throw SharedLibraryOperationError.contentChanged(path) }
      if actual != nil { try owner(path, authority: authority, required: true) }
      try files[0].checkCancellation()
      try beforeMutation()
      try bytes.write(to: files[0].url, options: .atomic)
      return .init(changed: true, pending: nil)
    case .trash(let path, let expected):
      try owner(path, authority: authority, required: true)
      guard let actual = try hash(files[0]) else {
        // Crash between Trash and receipt commit is ambiguous. Keep it
        // pending instead of pretending externally missing audio moved.
        return .init(changed: false, pending: .waitingForFile(path))
      }
      guard actual == expected else { throw SharedLibraryOperationError.contentChanged(path) }
      try files[0].checkCancellation()
      try beforeMutation()
      try trash(files[0].url)
      guard !fm.fileExists(atPath: files[0].url.path) else {
        throw SharedLibraryOperationError.contentChanged(path)
      }
      return .init(changed: true, pending: nil)
    case .createDirectory(let path):
      try owner(path, authority: authority, required: true)
      if fm.fileExists(atPath: files[0].url.path) {
        guard
          (try fm.attributesOfItem(atPath: files[0].url.path)[.type] as? FileAttributeType)
            == .typeDirectory
        else {
          throw SharedLibraryOperationError.pathConflict(path)
        }
        return .init(changed: false, pending: nil)
      }
      try files[0].checkCancellation()
      try beforeMutation()
      try fm.createDirectory(at: files[0].url, withIntermediateDirectories: false)
      return .init(changed: true, pending: nil)
    case .removeEmptyDirectory(let path):
      try owner(path, authority: authority, required: true)
      guard fm.fileExists(atPath: files[0].url.path) else {
        return .init(changed: false, pending: nil)
      }
      guard try fm.contentsOfDirectory(atPath: files[0].url.path).isEmpty else {
        return .init(changed: false, pending: .directoryNotEmpty(path))
      }
      try files[0].checkCancellation()
      try beforeMutation()
      try fm.removeItem(at: files[0].url)
      return .init(changed: true, pending: nil)
    case .publishAudio(let path, let staged, let selected):
      return try apply(
        .replaceAudio(
          path: path, staged: staged, expectedFingerprint: nil, selectedFingerprint: selected,
          repair: false),
        files: files, authority: authority, replaying: replaying, trash: trash,
        beforeMutation: beforeMutation)
    case .replaceAudio(let path, _, let expected, let selected, _):
      try owner(path, authority: authority, required: true)
      let actual = try hash(files[0])
      let staged = try hash(files[1])
      if actual == selected {
        if let staged {
          guard staged == selected else {
            throw SharedLibraryOperationError.contentChanged("staged audio")
          }
          try files[1].checkCancellation()
          try beforeMutation()
          try fm.removeItem(at: files[1].url)
          return .init(changed: true, pending: nil)
        }
        return .init(changed: false, pending: nil)
      }
      guard actual == expected else { throw SharedLibraryOperationError.contentChanged(path) }
      guard let staged else {
        return .init(changed: false, pending: .waitingForFile("staged audio"))
      }
      guard staged == selected else {
        throw SharedLibraryOperationError.contentChanged("staged audio")
      }
      try files[0].checkCancellation()
      try beforeMutation()
      if actual != nil {
        let destination = try fm.replaceItemAt(
          files[0].url, withItemAt: files[1].url, backupItemName: nil, options: [])
        guard destination == files[0].url else {
          throw SharedLibraryOperationError.contentChanged(path)
        }
      } else {
        try fm.moveItem(at: files[1].url, to: files[0].url)
      }
      files[1].didMove(to: files[0].url)
      guard try hash(files[0], checkCancellation: false) == selected else {
        throw SharedLibraryOperationError.contentChanged(path)
      }
      return .init(changed: true, pending: nil)
    }
  }
  static func contained(_ url: URL, in root: URL) -> Bool {
    url.standardizedFileURL.resolvingSymlinksInPath().path.hasPrefix(
      root.standardizedFileURL.resolvingSymlinksInPath().path + "/")
  }
  static func checkRoot(_ root: URL) throws {
    guard
      (try? FileManager.default.attributesOfItem(atPath: root.path)[.type] as? FileAttributeType)
        == .typeDirectory
    else {
      throw SharedLibraryOperationError.unavailableRoot
    }
  }
  public nonisolated static func moveToTrash(_ url: URL) throws {
    #if os(macOS)
      try FileManager.default.trashItem(at: url, resultingItemURL: nil)
    #else
      // iOS has no filesystem Trash equivalent. Do not silently turn the
      // user's recoverable delete into a permanent removal.
      throw CocoaError(.featureUnsupported)
    #endif
  }
}
