// © 2026 High Gain Design. All rights reserved.
import Foundation

/// Uses a fresh coordinator/queue per request, so a waiting file never owns a
/// library-wide serial queue. Accessor work must remain synchronous and finish
/// before returning; its resolved URL must not escape the coordinated scope.
public struct CoordinatedFileAccess: Sendable {
  public init() {}

  public struct Scope: Sendable {
    public let url: URL
    fileprivate let cancellation: Progress
    fileprivate let notifyMove: @Sendable (URL) -> Void

    public func checkCancellation() throws {
      if cancellation.isCancelled { throw CancellationError() }
    }
    /// Foundation requires the successful move announcement inside the
    /// accessor so registered presenters follow the actual destination.
    public func didMove(to destination: URL) { notifyMove(destination) }
  }

  // Foundation explicitly permits cancel() from any thread. All other access
  // to this coordinator belongs to its single request. There is no custom
  // shared mutable state or general-purpose unchecked actor replacement here.
  private final class Request: @unchecked Sendable {
    let coordinator = NSFileCoordinator()
    let cancellation = Progress(parent: nil, userInfo: nil)
    let intents: [NSFileAccessIntent]
    let queue = OperationQueue()

    init(intents: [NSFileAccessIntent]) {
      self.intents = intents
      queue.maxConcurrentOperationCount = 1
      queue.qualityOfService = .userInitiated
    }

    func cancel() {
      cancellation.cancel()
      coordinator.cancel()
    }
  }

  public func read(at url: URL) async throws -> Data {
    guard try await RecordingFileAccess().waitUntilAvailable(at: url, knownToExist: true) else {
      throw CocoaError(.fileReadNoSuchFile)
    }
    let bytes = try await perform(at: url, writing: false) { scope in
      try scope.checkCancellation()
      let bytes = try Data(contentsOf: scope.url)
      try scope.checkCancellation()
      return bytes
    }
    try Task.checkCancellation()
    return bytes
  }

  /// Read a provider-owned promised/version URL through coordination directly.
  /// Its bytes need not exist locally before the provider grants this access.
  public func withRead<Output: Sendable>(
    at url: URL,
    accessor: @escaping @Sendable (Scope) throws -> Output
  ) async throws -> Output {
    let result = try await perform(at: url, writing: false, accessor: accessor)
    try Task.checkCancellation()
    return result
  }

  /// Check cancellation before committing a write. After its atomic commit
  /// point, return the accepted result even if cancellation raced with it;
  /// reporting a rollback that never happened would corrupt the caller's state.
  public func withWrite<Output: Sendable>(
    at url: URL,
    accessor: @escaping @Sendable (Scope) throws -> Output
  ) async throws -> Output {
    try await perform(at: url, writing: true, accessor: accessor)
  }

  private func perform<Output: Sendable>(
    at url: URL, writing: Bool,
    accessor: @escaping @Sendable (Scope) throws -> Output
  ) async throws -> Output {
    let intent =
      writing
      ? NSFileAccessIntent.writingIntent(with: url, options: .forMerging)
      : NSFileAccessIntent.readingIntent(with: url, options: [])
    return try await perform(intents: [intent]) { scopes in try accessor(scopes[0]) }
  }

  public enum WriteMode: Sendable { case merging, moving, replacing, deleting }
  public struct WriteItem: Sendable {
    public let url: URL
    public let mode: WriteMode
    public init(_ url: URL, mode: WriteMode = .merging) {
      self.url = url
      self.mode = mode
    }
  }

  /// Only related files in one physical operation share this request. The
  /// receipt participates in the same local lease as its source/destination.
  /// Related control-file reads follow the write scopes in the returned array;
  /// hydration happens before acquiring this access, never in a global read batch.
  public func withWrites<Output: Sendable>(
    _ items: [WriteItem], reading: [URL] = [], accessor: @escaping @Sendable ([Scope]) throws -> Output
  ) async throws -> Output {
    guard !items.isEmpty else { throw CocoaError(.fileWriteInvalidFileName) }
    let intents = items.map { item in
      let options: NSFileCoordinator.WritingOptions
      switch item.mode {
      case .merging: options = .forMerging
      case .moving: options = .forMoving
      case .replacing: options = .forReplacing
      case .deleting: options = .forDeleting
      }
      return NSFileAccessIntent.writingIntent(with: item.url, options: options)
    }
    let reads = reading.map { NSFileAccessIntent.readingIntent(with: $0, options: []) }
    return try await perform(intents: intents + reads, accessor: accessor)
  }

  /// A version read and its canonical-file history mutation form one local
  /// access. The version's private URL is never treated as the canonical URL.
  func withVersionMutation<Output: Sendable>(
    reading version: URL, writing canonical: URL,
    accessor: @escaping @Sendable (Scope, Scope) throws -> Output
  ) async throws -> Output {
    let intents = [
      NSFileAccessIntent.readingIntent(with: version, options: []),
      NSFileAccessIntent.writingIntent(with: canonical, options: .forMerging),
    ]
    return try await perform(intents: intents) { scopes in try accessor(scopes[0], scopes[1]) }
  }

  private func perform<Output: Sendable>(
    intents: [NSFileAccessIntent], accessor: @escaping @Sendable ([Scope]) throws -> Output
  ) async throws -> Output {
    try Task.checkCancellation()
    let request = Request(intents: intents)
    return try await withTaskCancellationHandler {
      try Task.checkCancellation()
      return try await withCheckedThrowingContinuation { continuation in
        request.coordinator.coordinate(with: request.intents, queue: request.queue) { error in
          if let error {
            let cocoa = error as NSError
            if request.cancellation.isCancelled
              || (cocoa.domain == NSCocoaErrorDomain && cocoa.code == NSUserCancelledError)
            {
              continuation.resume(throwing: CancellationError())
            } else {
              continuation.resume(throwing: error)
            }
            return
          }
          do {
            let scopes = request.intents.map { intent in
              let source = intent.url
              return Scope(
                url: source, cancellation: request.cancellation,
                notifyMove: {
                  request.coordinator.item(at: source, didMoveTo: $0)
                })
            }
            for scope in scopes { try scope.checkCancellation() }
            continuation.resume(returning: try accessor(scopes))
          } catch {
            continuation.resume(throwing: error)
          }
        }
      }
    } onCancel: {
      request.cancel()
    }
  }
}
