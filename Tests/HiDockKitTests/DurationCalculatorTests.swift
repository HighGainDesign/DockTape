// © 2026 High Gain Design. All rights reserved.

import XCTest
@testable import HiDockKit

final class DurationCalculatorTests: XCTestCase {

    func testEstimateDuration128kbps() {
        // 128 kbps = 16000 bytes/sec
        // 960000 bytes = 60 seconds
        let duration = DurationCalculator.estimateDuration(fileSize: 960_000)
        XCTAssertEqual(duration, 60.0, accuracy: 0.01)
    }

    func testEstimateDurationZeroSize() {
        let duration = DurationCalculator.estimateDuration(fileSize: 0)
        XCTAssertEqual(duration, 0.0)
    }

    func testEstimateDurationCustomBitrate() {
        // 256 kbps = 32000 bytes/sec
        let duration = DurationCalculator.estimateDuration(fileSize: 960_000, bitrate: 256_000)
        XCTAssertEqual(duration, 30.0, accuracy: 0.01)
    }

    func testFormatDurationMinutesOnly() {
        XCTAssertEqual(DurationCalculator.formatDuration(65), "1:05")
        XCTAssertEqual(DurationCalculator.formatDuration(0), "0:00")
        XCTAssertEqual(DurationCalculator.formatDuration(59), "0:59")
    }

    func testFormatDurationWithHours() {
        XCTAssertEqual(DurationCalculator.formatDuration(3661), "1:01:01")
        XCTAssertEqual(DurationCalculator.formatDuration(7200), "2:00:00")
    }
}
