// © 2026 High Gain Design. All rights reserved.
import XCTest

@testable import HiDockKit

final class CoordinatedFileAccessTests: XCTestCase {
  private enum FixtureError: Error { case holdTimedOut }
  private func files() throws -> (URL, URL, URL) {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let a = root.appendingPathComponent("a.txt")
    let b = root.appendingPathComponent("b.txt")
    try Data("Alpha".utf8).write(to: a)
    try Data("Beta".utf8).write(to: b)
    return (root, a, b)
  }

  func testBlockedReadAIsCancellableWhileIndependentBReadsImmediately() async throws {
    let (root, a, b) = try files()
    defer { try? FileManager.default.removeItem(at: root) }
    let access = CoordinatedFileAccess()
    let started = expectation(description: "Writer holds only A")
    let release = DispatchSemaphore(value: 0)
    defer { release.signal() }
    let holding = Task {
      try await access.withWrite(at: a) { _ in
        started.fulfill()
        guard release.wait(timeout: .now() + 5) == .success else { throw FixtureError.holdTimedOut }
      }
    }
    await fulfillment(of: [started], timeout: 2)
    let readReturned = expectation(description: "Read cannot bypass writer coordination")
    readReturned.isInverted = true
    let pending = Task {
      let data = try await access.read(at: a)
      readReturned.fulfill()
      return data
    }
    let before = ContinuousClock.now
    let data = try await access.read(at: b)
    XCTAssertEqual(data, Data("Beta".utf8))
    XCTAssertLessThan(
      before.duration(to: .now), .seconds(1),
      "One held file must not own a global serial accessor queue")
    await fulfillment(of: [readReturned], timeout: 0.05)
    pending.cancel()
    do {
      _ = try await pending.value
      XCTFail("Pending read must be cancellable")
    } catch { XCTAssertTrue(error is CancellationError) }
    release.signal()
    try await holding.value
  }

  func testCancelledQueuedWriteDoesNotRunAfterBlockingWriterReleases() async throws {
    let (root, a, _) = try files()
    defer { try? FileManager.default.removeItem(at: root) }
    let access = CoordinatedFileAccess()
    let started = expectation(description: "First writer owns A")
    let release = DispatchSemaphore(value: 0)
    defer { release.signal() }
    let holding = Task {
      try await access.withWrite(at: a) { _ in
        started.fulfill()
        guard release.wait(timeout: .now() + 5) == .success else { throw FixtureError.holdTimedOut }
      }
    }
    await fulfillment(of: [started], timeout: 2)
    let ran = expectation(description: "Cancelled writer must never acquire access")
    ran.isInverted = true
    let cancelled = Task {
      try await access.withWrite(at: a) { scope in
        ran.fulfill()
        try scope.checkCancellation()
        try Data("Late replacement".utf8).write(to: scope.url, options: .atomic)
      }
    }
    await fulfillment(of: [ran], timeout: 0.05)
    cancelled.cancel()
    do {
      try await cancelled.value
      XCTFail("Queued write must cancel")
    } catch { XCTAssertTrue(error is CancellationError) }
    release.signal()
    try await holding.value
    XCTAssertEqual(try Data(contentsOf: a), Data("Alpha".utf8))
  }

  func testCancellationAfterAcceptedWriteDoesNotReportFalseRollback() async throws {
    let (root, a, _) = try files()
    defer { try? FileManager.default.removeItem(at: root) }
    let access = CoordinatedFileAccess()
    let written = expectation(description: "Write has crossed its atomic commit point")
    let release = DispatchSemaphore(value: 0)
    defer { release.signal() }
    let operation = Task {
      try await access.withWrite(at: a) { scope in
        try scope.checkCancellation()
        try Data("Accepted".utf8).write(to: scope.url, options: .atomic)
        written.fulfill()
        guard release.wait(timeout: .now() + 5) == .success else { throw FixtureError.holdTimedOut }
        return "accepted"
      }
    }
    await fulfillment(of: [written], timeout: 2)
    operation.cancel()
    release.signal()
    let outcome = try await operation.value
    XCTAssertEqual(outcome, "accepted")
    XCTAssertEqual(try Data(contentsOf: a), Data("Accepted".utf8))
  }
  private final class MovePresenter: NSObject, NSFilePresenter {
    let presentedItemURL: URL?
    let presentedItemOperationQueue = OperationQueue()
    let moved: @Sendable (URL) -> Void
    init(url: URL, moved: @escaping @Sendable (URL) -> Void) {
      presentedItemURL = url
      self.moved = moved
      presentedItemOperationQueue.maxConcurrentOperationCount = 1
      super.init()
    }
    func presentedItemDidMove(to newURL: URL) { moved(newURL) }
  }
  func testSuccessfulMoveNotifiesActualSourceFilePresenter() async throws {
    let (root, source, _) = try files()
    defer { try? FileManager.default.removeItem(at: root) }
    let destination = root.appendingPathComponent("renamed.txt")
    let observed = expectation(description: "Source presenter receives its coordinated new URL")
    let presenter = MovePresenter(url: source) { newURL in
      XCTAssertEqual(newURL.standardizedFileURL, destination.standardizedFileURL)
      observed.fulfill()
    }
    NSFileCoordinator.addFilePresenter(presenter)
    defer { NSFileCoordinator.removeFilePresenter(presenter) }
    try await CoordinatedFileAccess().withWrites([
      .init(source, mode: .moving), .init(destination, mode: .replacing),
    ]) { scopes in
      try FileManager.default.moveItem(at: scopes[0].url, to: scopes[1].url)
      scopes[0].didMove(to: scopes[1].url)
    }
    await fulfillment(of: [observed], timeout: 2)
    XCTAssertEqual(try Data(contentsOf: destination), Data("Alpha".utf8))
  }

}
