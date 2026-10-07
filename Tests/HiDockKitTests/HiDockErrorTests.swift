// © 2026 High Gain Design. All rights reserved.

import Foundation
import XCTest
@testable import HiDockKit

final class HiDockErrorTests: XCTestCase {
    func testLocalizedDescriptionPreservesActionableReasonThroughNSErrorBridge() {
        let busyReason = "Device is busy — wait for the current operation to finish."
        let error: Error = HiDockError.transferFailed(busyReason)
        XCTAssertEqual((error as NSError).localizedDescription, busyReason)
        let transport: Error = HiDockError.usb(.seizeFailed("Another app is using HiDock."))
        XCTAssertTrue(transport.localizedDescription.contains("Another app"))
        let response: Error = HiDockError.proto(.invalidBody("Recording has an invalid header."))
        XCTAssertTrue(response.localizedDescription.contains("invalid header"))
    }
}
