// © 2026 High Gain Design. All rights reserved.
import Foundation

/// Local legacy mutations re-read under coordination. This prevents two local
/// stores losing unrelated keys; offline multi-Mac merging belongs to shared
/// metadata. A shared-format library must never fall back to these writes.
struct LegacyLibraryFileAccess: Sendable {
  private let access = CoordinatedFileAccess()
  func mutateObject(
    at file: URL, root: URL, initialObject: Data = Data("{}".utf8),
    mutation: @escaping @Sendable (inout [String: Any]) throws -> Void
  ) async throws -> Data {
    try Self.requireLegacyRoot(root)
    _ = try await RecordingFileAccess().waitUntilAvailable(at: file)
    return try await access.withWrite(at: file) { scope in
      try Self.requireLegacyRoot(root)
      guard SharedLibraryMaterializer.contained(scope.url, in: root) else {
        throw SharedLibraryOperationError.unsafePath
      }
      let existing =
        FileManager.default.fileExists(atPath: scope.url.path)
        ? try Data(contentsOf: scope.url) : nil
      var object: [String: Any]
      do {
        guard
          let decoded = try JSONSerialization.jsonObject(with: existing ?? initialObject)
            as? [String: Any]
        else {
          throw SharedLibraryOperationError.invalidOperation
        }
        object = decoded
      }
      let before = try JSONSerialization.data(
        withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])
      try mutation(&object)
      let after = try JSONSerialization.data(
        withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])
      if before == after, let existing { return existing }
      try scope.checkCancellation()
      try after.write(to: scope.url, options: .atomic)
      return after
    }
  }
  static func requireLegacyRoot(_ root: URL) throws {
    try SharedLibraryMaterializer.checkRoot(root)
    if FileManager.default.fileExists(atPath: root.appendingPathComponent(".docktape").path) {
      throw HiDockError.storageError(
        "This library uses shared metadata. Open it with an enrolled DockTape instance before editing."
      )
    }
  }
}
