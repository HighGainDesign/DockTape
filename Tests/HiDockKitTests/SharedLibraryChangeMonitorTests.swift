// © 2026 High Gain Design. All rights reserved.
import XCTest

@testable import HiDockKit

final class SharedLibraryChangeMonitorTests: XCTestCase {
    func testActualCoordinatedSubitemWritesNotifyDirectoryPresenterAndBurstCoalesces() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let nested = directory.appendingPathComponent(".docktape/records")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let observed = expectation(description: "A real directory presenter receives nested file changes")
        observed.assertForOverFulfill = true
        let monitor = SharedLibraryChangeMonitor(root: directory, delay: .milliseconds(120)) { observed.fulfill() }
        let file = nested.appendingPathComponent("writer.json")
        let access = CoordinatedFileAccess()
        for value in 0..<8 {
            try await access.withWrite(at: file) { scope in
                try Data("value-\(value)".utf8).write(to: scope.url, options: .atomic)
            }
        }
        await fulfillment(of: [observed], timeout: 3)
        await monitor.close()
        let noLater = expectation(description: "No late callback after close")
        noLater.isInverted = true
        let closed = SharedLibraryChangeMonitor(root: directory, delay: .milliseconds(120)) { noLater.fulfill() }
        try await access.withWrite(at: file) { scope in try Data("last".utf8).write(to: scope.url, options: .atomic) }
        await closed.close()
        await fulfillment(of: [noLater], timeout: 0.25)
    }
}
