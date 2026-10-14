// © 2026 High Gain Design. All rights reserved.
import CryptoKit
import Foundation

public enum SharedLibraryOperationError: Error, Equatable, Sendable {
  case invalidOperation, invalidReceipt, differentBinding, unfinishedOperation, staleAuthority
  case pathConflict(String)
  case contentChanged(String)
  case unsafePath, unavailableRoot
}
public enum SharedMaterializationResult: Equatable, Sendable {
  case complete, needsReplanning, waitingForAcknowledgments, waitingForActiveWork
  case waitingForFile(String)
  case directoryNotEmpty(String)
}
public enum SharedDestructivePurpose: String, Codable, Sendable { case delete, replaceAudio }

/// An acknowledgment is metadata, never an alive user mutation or sync-complete
/// claim. Only the exact selected revision and stable enrolled cohort can use it.
public struct SharedOperationAcknowledgment: Codable, Hashable, Sendable {
  public let writer: UUID
  public let entity: UUID
  public let revision: String
  public let cohort: String
  public let purpose: SharedDestructivePurpose
  public init(
    writer: UUID, entity: UUID, revision: String, cohort: String, purpose: SharedDestructivePurpose
  ) {
    self.writer = writer
    self.entity = entity
    self.revision = revision
    self.cohort = cohort
    self.purpose = purpose
  }
}

/// Narrow Foundation cancellation capability. The coordinator revokes this
/// snapshot lease before an edit, enrollment change, refresh or job transition.
/// Checks inside the accessor catch revisions changed while waiting for a file.
public struct SharedMaterializationLease: Sendable {
  private let cancellation = Progress(parent: nil, userInfo: nil)
  public init() {}
  public func revoke() { cancellation.cancel() }
  public var isRevoked: Bool { cancellation.isCancelled }
}

public struct SharedMaterializationBinding: Sendable {
  public let file: URL
  public let validate: @Sendable (Data) throws -> Bool
  public init(file: URL, validate: @escaping @Sendable (Data) throws -> Bool) {
    self.file = file
    self.validate = validate
  }
}

public struct SharedMaterializationAuthority: Sendable {
  public let libraryID: UUID
  public var state: SharedEntityState
  public var membership: SharedLibraryMembership
  public var acknowledgments: [SharedOperationAcknowledgment]
  public var hasPendingWork: Bool
  public var jobGate: SharedLibraryJobGate? = nil
  public var jobGates: [SharedLibraryJobGate] = []
  /// Exact owners from the current identity/path index plus retained operation
  /// claims. An empty set is unowned, multiple IDs is a path conflict.
  public var pathOwners: [String: Set<UUID>]
  /// Live coordinator permissions are limited to these requested canonical
  /// paths. Staged-input locations are separately bound/validated by the plan.
  public var allowedPaths: Set<String>? = nil
  public var binding: SharedMaterializationBinding? = nil
  public var additionalBindings: [SharedMaterializationBinding] = []
  public var revisionLease: SharedMaterializationLease
  /// Actual coordinator authority checks its local checkpoint again inside the
  /// gate: a different process cannot revoke this process's Progress object.
  public var validateLocalCommit: @Sendable () throws -> Bool = { true }
  public init(
    libraryID: UUID, state: SharedEntityState, membership: SharedLibraryMembership,
    acknowledgments: [SharedOperationAcknowledgment], hasPendingWork: Bool,
    pathOwners: [String: Set<UUID>]
  ) {
    self.libraryID = libraryID
    self.state = state
    self.membership = membership
    self.acknowledgments = acknowledgments
    self.hasPendingWork = hasPendingWork
    self.pathOwners = pathOwners
    self.revisionLease = .init()
  }
  public func mayDestroy(_ purpose: SharedDestructivePurpose) -> Bool {
    guard membership.libraryID == libraryID, state.conflicts.isEmpty, !hasPendingWork,
      membership.pendingWriters.isEmpty, !membership.hasConcurrentEnrollment,
      purpose == .delete ? state.lifecycle == .deleted : state.lifecycle == .alive,
      let revision = try? SharedStateFingerprint.of(state)
    else { return false }
    let approved = Set(
      acknowledgments.filter {
        $0.purpose == purpose && $0.entity == state.id && $0.revision == revision
          && $0.cohort == membership.fingerprint
      }.map(\.writer))
    return membership.cohort.isSubset(of: approved)
  }
  public func acknowledgment(by writer: UUID, purpose: SharedDestructivePurpose) throws
    -> SharedOperationAcknowledgment
  {
    guard !hasPendingWork, state.conflicts.isEmpty, membership.mayEdit(writer),
      membership.pendingWriters.isEmpty, !membership.hasConcurrentEnrollment,
      purpose == .delete ? state.lifecycle == .deleted : state.lifecycle == .alive
    else { throw SharedLibraryOperationError.invalidOperation }
    return .init(
      writer: writer, entity: state.id, revision: try SharedStateFingerprint.of(state),
      cohort: membership.fingerprint, purpose: purpose)
  }
}

/// An immutable plan derived AFTER the semantic mutation was accepted. Receipt
/// data contains no original media; staged paths refer only to newly supplied bytes.
public struct SharedLibraryOperation: Codable, Equatable, Sendable {
  public enum Step: Codable, Equatable, Sendable {
    case move(source: String, destination: String, fingerprint: String)
    case moveDirectory(source: String, destination: String, inventory: SharedDirectoryInventory)
    case write(path: String, expectedFingerprint: String?, bytes: Data)
    case trash(path: String, fingerprint: String)
    case removeEmptyDirectory(path: String)
    case createDirectory(path: String)
    case publishAudio(path: String, staged: String, selectedFingerprint: String)
    case replaceAudio(
      path: String, staged: String, expectedFingerprint: String?, selectedFingerprint: String,
      repair: Bool)
  }
  public let id: UUID
  public let libraryID: UUID
  public let entity: SharedEntityIdentity
  public let inputRevision: String
  public let outputRevision: String
  public let steps: [Step]
  public let inputAudioFingerprint: String?
  public init(
    id: UUID = UUID(), libraryID: UUID, entity: SharedEntityIdentity, inputRevision: String,
    outputRevision: String, steps: [Step], inputAudioFingerprint: String? = nil
  ) throws {
    self.id = id
    self.libraryID = libraryID
    self.entity = entity
    self.inputRevision = inputRevision
    self.outputRevision = outputRevision
    self.steps = steps
    self.inputAudioFingerprint = inputAudioFingerprint
    try validate()
  }
  var canonicalPaths: Set<String> {
    Set(steps.flatMap { step -> [String] in
      switch step {
      case .move(let source, let destination, _), .moveDirectory(let source, let destination, _): return [source, destination]
      case .write(let path, _, _), .trash(let path, _), .createDirectory(let path), .removeEmptyDirectory(let path): return [path]
      case .publishAudio(let path, _, _), .replaceAudio(let path, _, _, _, _): return [path]
      }
    })
  }
  public static func fingerprint(_ bytes: Data) -> String {
    SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
  }
  func validate() throws {
    guard !inputRevision.isEmpty, Self.validHash(outputRevision), !steps.isEmpty else {
      throw SharedLibraryOperationError.invalidOperation
    }
    for step in steps {
      let paths: [String]
      let hashes: [String]
      switch step {
      case .move(let source, let destination, let hash):
        guard source != destination,
          (source as NSString).pathExtension.lowercased()
            == (destination as NSString).pathExtension.lowercased()
        else { throw SharedLibraryOperationError.invalidOperation }
        paths = [source, destination]
        hashes = [hash]
      case .moveDirectory(let source, let destination, let inventory):
        guard entity.kind == .folder, source != destination,
              !destination.hasPrefix(source + "/"), !source.hasPrefix(destination + "/") else { throw SharedLibraryOperationError.invalidOperation }
        try inventory.validate()
        paths = [source, destination]; hashes = []
      case .write(let path, let expected, _):
        guard ["json", "md", "txt"].contains((path as NSString).pathExtension.lowercased()) else {
          throw SharedLibraryOperationError.invalidOperation
        }
        paths = [path]
        hashes = expected.map { [$0] } ?? []
      case .trash(let path, let hash):
        paths = [path]
        hashes = [hash]
      case .removeEmptyDirectory(let path), .createDirectory(let path):
        paths = [path]
        hashes = []
      case .publishAudio(let path, let staged, let selected):
        paths = [path]
        hashes = [selected]
        try validateAudioPath(path, staged: staged)
      case .replaceAudio(let path, let staged, let expected, let selected, let repair):
        try validateAudioPath(path, staged: staged)
        paths = [path]
        hashes = [selected] + (expected.map { [$0] } ?? [])
        if repair && inputAudioFingerprint != selected {
          throw SharedLibraryOperationError.invalidOperation
        }
      }
      for path in paths { _ = try SharedLibraryIdentity.normalized(path) }
      guard hashes.allSatisfy(Self.validHash) else {
        throw SharedLibraryOperationError.invalidOperation
      }
    }
  }
  private func validateAudioPath(_ path: String, staged: String) throws {
    let prefix = ".docktape/staging/" + entity.id.uuidString + "/"
    guard (path as NSString).pathExtension.lowercased() == "mp3", staged.hasPrefix(prefix),
      UUID(uuidString: String(staged.dropFirst(prefix.count).dropLast(4))) != nil,
      staged.hasSuffix(".mp3")
    else { throw SharedLibraryOperationError.invalidOperation }
  }
  static func validHash(_ string: String) -> Bool {
    string.utf8.count == 64
      && string.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
  }
}

struct SharedOperationReceipt: Codable, Sendable {
  let schema: Int
  let operation: SharedLibraryOperation
  var completed: Int
  var attempting: Bool
  var reviewedCleanups: [String: String] = [:]
  init(_ operation: SharedLibraryOperation) {
    schema = 1
    self.operation = operation
    completed = 0
    attempting = false
  }
  private struct Envelope: Codable {
    let receipt: SharedOperationReceipt
    let checksum: String
  }
  func encoded() throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    return try encoder.encode(Envelope(receipt: self, checksum: SharedStateFingerprint.of(self)))
  }
  static func decode(_ data: Data) throws -> Self {
    let envelope = try JSONDecoder().decode(Envelope.self, from: data)
    let value = envelope.receipt
    try value.operation.validate()
    guard value.schema == 1, value.completed >= 0, value.completed <= value.operation.steps.count,
      value.completed != value.operation.steps.count || !value.attempting,
      try SharedStateFingerprint.of(value) == envelope.checksum
    else { throw SharedLibraryOperationError.invalidReceipt }
    return value
  }
}

public struct SharedLibraryOperationProgress: Sendable {
  public let operation: SharedLibraryOperation
  public let completedSteps: Int
  public let phaseWasAttempted: Bool
}
