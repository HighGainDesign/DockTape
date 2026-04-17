// © 2026 High Gain Design. All rights reserved.

import Foundation
@testable import HiDockKit

/// Mock device transport for testing. Returns canned responses in order.
final class MockDeviceTransport: DeviceTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var _sentData: [Data] = []
    private var _responses: [Data] = []
    private var _responseIndex = 0
    private var _closed = false

    var sentData: [Data] {
        lock.lock()
        defer { lock.unlock() }
        return _sentData
    }

    var isClosed: Bool {
        lock.lock()
        defer { lock.unlock() }
        return _closed
    }

    init(responses: [Data] = []) {
        _responses = responses
    }

    func queueResponse(_ data: Data) {
        lock.lock()
        defer { lock.unlock() }
        _responses.append(data)
    }

    /// Queue a valid Jensen frame as a response.
    func queueFrameResponse(command: JensenCommand, sequence: UInt32, body: Data = Data()) {
        let frame = JensenFrame(command: command, sequence: sequence, body: body)
        queueResponse(frame.encode())
    }

    func open() async throws {}

    func send(_ data: Data) async throws {
        lock.lock()
        defer { lock.unlock() }
        _sentData.append(data)
    }

    func receive(maxLength: Int) async throws -> Data {
        lock.lock()
        defer { lock.unlock() }
        guard _responseIndex < _responses.count else {
            throw TransportError.readTimeout
        }
        let response = _responses[_responseIndex]
        _responseIndex += 1
        // Return up to maxLength bytes
        if response.count <= maxLength {
            return response
        }
        return response.prefix(maxLength)
    }

    func close() async {
        lock.lock()
        defer { lock.unlock() }
        _closed = true
    }
}
