// © 2026 High Gain Design. All rights reserved.
import Foundation

/// Each writer owns one current acknowledgment per entity. Older provider files
/// cannot authorize a different revision/cohort; no acknowledgment writes alive.
public actor SharedOperationAcknowledgmentStore {
  private let root: URL
  private let libraryID: UUID
  private let writer: UUID
  private let access = CoordinatedFileAccess()
  public init(root: URL, libraryID: UUID, writer: UUID) {
    self.root = root.standardizedFileURL.resolvingSymlinksInPath()
    self.libraryID = libraryID
    self.writer = writer
  }
  private struct Payload: Codable, Equatable, Sendable {
    let schema: Int
    let library: UUID
    let writer: UUID
    let entity: UUID
    let sequence: UInt64
    let acknowledgment: SharedOperationAcknowledgment?
  }
  private struct Envelope: Codable {
    let payload: Payload
    let checksum: String
  }
  public func acknowledge(
    purpose: SharedDestructivePurpose,
    authority: @escaping SharedLibraryMaterializer.Authority
  ) async throws -> SharedOperationAcknowledgment {
    let current = try await authority()
    guard current.libraryID == libraryID else { throw SharedLibraryOperationError.differentBinding }
    let acknowledgment = try current.acknowledgment(by: writer, purpose: purpose)
    let directory = try await ensureDirectory(entity: current.state.id)
    let fresh = try await authority()
    guard try fresh.acknowledgment(by: writer, purpose: purpose) == acknowledgment else {
      throw SharedLibraryOperationError.invalidOperation
    }
    try await write(
      acknowledgment, entity: acknowledgment.entity, directory: directory,
      lease: fresh.revisionLease)
    return acknowledgment
  }
  public func withdraw(entity: UUID) async throws {
    let directory = try await ensureDirectory(entity: entity)
    try await write(nil, entity: entity, directory: directory)
  }
  private func write(
    _ acknowledgment: SharedOperationAcknowledgment?, entity: UUID, directory: URL,
    lease: SharedMaterializationLease? = nil
  ) async throws {
    let file = directory.appendingPathComponent(writer.uuidString + ".json")
    let library = libraryID
    let writer = self.writer
    let root = self.root
    // Include valid provider copies when repairing the owner sequence. The
    // device-local counter witness is also required at app integration.
    let known = try await payloads(entity: entity)
    let highWater = known.filter { $0.writer == writer }.map(\.sequence).max() ?? 0
    try await access.withWrite(at: file) { scope in
      guard lease?.isRevoked != true else { throw SharedLibraryOperationError.staleAuthority }
      try SharedLibraryMaterializer.checkRoot(root)
      guard SharedLibraryMaterializer.contained(scope.url, in: directory) else {
        throw SharedLibraryOperationError.unsafePath
      }
      var old: Payload?
      if FileManager.default.fileExists(atPath: scope.url.path) {
        old = try Self.decode(Data(contentsOf: scope.url), library: library, entity: entity)
        guard old?.writer == writer else { throw SharedLibraryOperationError.invalidReceipt }
        if old?.acknowledgment == acknowledgment, old?.sequence == highWater { return }
      }
      let sequence = max(highWater, old?.sequence ?? 0)
      guard sequence < UInt64.max else { throw SharedLibraryOperationError.invalidReceipt }
      let payload = Payload(
        schema: 1, library: library, writer: writer, entity: entity,
        sequence: sequence + 1, acknowledgment: acknowledgment)
      let encoder = JSONEncoder()
      encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
      let bytes = try encoder.encode(
        Envelope(payload: payload, checksum: SharedStateFingerprint.of(payload)))
      try scope.checkCancellation()
      try bytes.write(to: scope.url, options: .atomic)
    }
  }
  public func load(entity: UUID) async throws -> [SharedOperationAcknowledgment] {
    let payloads = try await payloads(entity: entity)
    var heads: [UUID: Payload] = [:]
    for payload in payloads {
      if let old = heads[payload.writer], old.sequence > payload.sequence { continue }
      if let old = heads[payload.writer], old.sequence == payload.sequence, old != payload {
        throw SharedLibraryOperationError.invalidReceipt
      }
      heads[payload.writer] = payload
    }
    return heads.values.compactMap(\.acknowledgment).sorted {
      $0.writer.uuidString < $1.writer.uuidString
    }
  }
  private func payloads(entity: UUID) async throws -> [Payload] {
    try SharedLibraryMaterializer.checkRoot(root)
    let directory = root.appendingPathComponent(".docktape/acknowledgments").appendingPathComponent(
      entity.uuidString)
    guard SharedLibraryMaterializer.contained(directory, in: root) else {
      throw SharedLibraryOperationError.unsafePath
    }
    guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
    let files = LibraryFileDiscovery.files(in: directory, suffix: ".json")
    let access = self.access
    let library = libraryID
    return try await withThrowingTaskGroup(of: Payload.self) { group in
      for file in files {
        group.addTask {
          guard SharedLibraryMaterializer.contained(file.url, in: directory) else {
            throw SharedLibraryOperationError.unsafePath
          }
          let logicalURL = directory.appendingPathComponent(file.relativePath)
          return try Self.decode(
            await access.read(at: logicalURL), library: library, entity: entity)
        }
      }
      var result: [Payload] = []
      for try await acknowledgment in group { result.append(acknowledgment) }
      return result
    }
  }
  private func ensureDirectory(entity: UUID) async throws -> URL {
    try SharedLibraryMaterializer.checkRoot(root)
    var current = root
    for name in [".docktape", "acknowledgments", entity.uuidString] {
      current.appendPathComponent(name)
      let directory = current
      guard SharedLibraryMaterializer.contained(directory, in: root) else {
        throw SharedLibraryOperationError.unsafePath
      }
      try await access.withWrite(at: directory) { scope in
        try SharedLibraryMaterializer.checkRoot(self.root)
        guard SharedLibraryMaterializer.contained(scope.url, in: self.root) else {
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
    return current
  }
  private static func decode(_ bytes: Data, library: UUID, entity: UUID) throws -> Payload {
    let envelope = try JSONDecoder().decode(Envelope.self, from: bytes)
    guard envelope.payload.schema == 1, envelope.payload.library == library,
      envelope.payload.entity == entity, envelope.payload.sequence > 0,
      envelope.payload.acknowledgment == nil
        || (envelope.payload.acknowledgment?.writer == envelope.payload.writer
          && envelope.payload.acknowledgment?.entity == entity),
      envelope.checksum == (try SharedStateFingerprint.of(envelope.payload))
    else {
      throw SharedLibraryOperationError.invalidReceipt
    }
    return envelope.payload
  }
}
