// © 2026 High Gain Design. All rights reserved.

import XCTest
@testable import HiDockKit

final class JensenTransportTests: XCTestCase {

    func testSendCommandBasic() async throws {
        let mock = MockUSBConnection()
        let responseBody = Data([0x01, 0x02, 0x03])
        mock.queueFrameResponse(command: .deviceInfo, sequence: 1, body: responseBody)

        let transport = JensenTransport(connection: mock)
        let response = try await transport.sendCommand(.deviceInfo)

        XCTAssertEqual(response.command, .deviceInfo)
        XCTAssertEqual(response.sequence, 1)
        XCTAssertEqual(response.body, responseBody)

        // Verify something was sent
        XCTAssertEqual(mock.sentData.count, 1)
        let sentFrame = JensenFrame.decode(from: mock.sentData[0])
        XCTAssertNotNil(sentFrame)
        XCTAssertEqual(sentFrame?.command, .deviceInfo)
        XCTAssertEqual(sentFrame?.sequence, 1)
    }

    func testSequenceIncrementsAcrossCommands() async throws {
        let mock = MockUSBConnection()
        mock.queueFrameResponse(command: .deviceInfo, sequence: 1)
        mock.queueFrameResponse(command: .battery, sequence: 2)

        let transport = JensenTransport(connection: mock)
        let r1 = try await transport.sendCommand(.deviceInfo)
        let r2 = try await transport.sendCommand(.battery)

        XCTAssertEqual(r1.sequence, 1)
        XCTAssertEqual(r2.sequence, 2)

        let sent1 = JensenFrame.decode(from: mock.sentData[0])
        let sent2 = JensenFrame.decode(from: mock.sentData[1])
        XCTAssertEqual(sent1?.sequence, 1)
        XCTAssertEqual(sent2?.sequence, 2)
    }

    func testSendCommandWithBody() async throws {
        let mock = MockUSBConnection()
        mock.queueFrameResponse(command: .setTime, sequence: 1)

        let transport = JensenTransport(connection: mock)
        let timeBody = Data([0x20, 0x24, 0x03, 0x15, 0x14, 0x30, 0x00])
        let response = try await transport.sendCommand(.setTime, body: timeBody)

        XCTAssertEqual(response.command, .setTime)

        let sentFrame = JensenFrame.decode(from: mock.sentData[0])
        XCTAssertEqual(sentFrame?.body, timeBody)
    }

    func testClose() async throws {
        let mock = MockUSBConnection()
        let transport = JensenTransport(connection: mock)
        await transport.close()
        XCTAssertTrue(mock.isClosed)
    }

    func testResponseWithPadding() async throws {
        let mock = MockUSBConnection()
        // Simulate a device response with padding in length field
        var responseData = Data()
        responseData.appendUInt16BE(0x1234)
        responseData.appendUInt16BE(JensenCommand.fileList.rawValue)
        responseData.appendUInt32BE(1)
        // padding=4, bodyLen=3
        responseData.appendUInt32BE((4 << 24) | 3)
        responseData.append(Data([0xAA, 0xBB, 0xCC]))  // body
        responseData.append(Data(repeating: 0, count: 4))  // padding
        mock.queueResponse(responseData)

        let transport = JensenTransport(connection: mock)
        let response = try await transport.sendCommand(.fileList)

        XCTAssertEqual(response.command, .fileList)
        XCTAssertEqual(response.body, Data([0xAA, 0xBB, 0xCC]))
    }

    func testMultiPacketResponse() async throws {
        let mock = MockUSBConnection()
        // Build a response frame with a 600-byte body
        let body = Data(repeating: 0xAA, count: 600)
        let frame = JensenFrame(command: .fileList, sequence: 1, body: body)
        let encoded = frame.encode()

        // Split into two chunks
        let chunk1 = Data(encoded.prefix(256))
        let chunk2 = Data(encoded.suffix(from: 256))
        mock.queueResponse(chunk1)
        mock.queueResponse(chunk2)

        let transport = JensenTransport(connection: mock)
        let response = try await transport.sendCommandMultiPacket(
            .fileList,
            expectedBodySize: 600
        )

        XCTAssertEqual(response.command, .fileList)
        XCTAssertEqual(response.body.count, 600)
        XCTAssertEqual(response.body, body)
    }
}
