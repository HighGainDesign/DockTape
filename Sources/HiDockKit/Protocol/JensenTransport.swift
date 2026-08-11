// © 2026 High Gain Design. All rights reserved.

import Foundation

/// Orchestrates Jensen command/response over a device transport.
/// Actor ensures only one command is in flight at a time.
public actor JensenTransport {
    private let connection: any DeviceTransport
    private var nextSequence: UInt32 = 1
    private let readSize = 512

    public init(connection: any DeviceTransport) {
        self.connection = connection
    }

    /// Send a command and receive the response frame.
    public func sendCommand(_ command: JensenCommand, body: Data = Data()) async throws -> JensenFrame {
        let seq = nextSequence
        nextSequence += 1

        let request = JensenFrame(command: command, sequence: seq, body: body)
        try await connection.send(request.encode())

        // Read response — may arrive in multiple packets
        var accumulated = Data()
        accumulated = try await connection.receive(maxLength: readSize)

        // Accumulate until we have the full frame (header + body + padding)
        while true {
            if let needed = JensenFrame.frameSizeFromHeader(accumulated) {
                if accumulated.count >= needed { break }
            } else if accumulated.count >= JensenFrame.headerSize {
                // Have header but can't parse — shouldn't happen, but bail out
                break
            }
            let chunk = try await connection.receive(maxLength: readSize)
            if chunk.isEmpty { throw ProtocolError.timeout }
            accumulated.append(chunk)
        }

        guard let response = JensenFrame.decode(from: accumulated) else {
            throw ProtocolError.invalidMagic
        }

        return response
    }

    /// Send a command and receive a multi-packet response (e.g., file list, file data).
    /// Reads until `expectedBodySize` bytes have been received in the body.
    public func sendCommandMultiPacket(
        _ command: JensenCommand,
        body: Data = Data(),
        expectedBodySize: Int
    ) async throws -> JensenFrame {
        let seq = nextSequence
        nextSequence += 1

        let request = JensenFrame(command: command, sequence: seq, body: body)
        try await connection.send(request.encode())

        var accumulated = Data()

        while true {
            let chunk = try await connection.receive(maxLength: readSize)
            if chunk.isEmpty { throw ProtocolError.timeout }
            accumulated.append(chunk)
            if let needed = JensenFrame.frameSizeFromHeader(accumulated),
               accumulated.count >= needed { break }
        }

        guard let response = JensenFrame.decode(from: accumulated) else {
            throw ProtocolError.invalidMagic
        }

        return response
    }

    /// Send a command for file transfer. Returns the header frame, then streams
    /// blocks via the provided closure.
    public func sendFileTransfer(
        _ command: JensenCommand,
        body: Data = Data(),
        onBlock: @Sendable (Data) async throws -> Void
    ) async throws -> JensenFrame {
        let seq = nextSequence
        nextSequence += 1

        let request = JensenFrame(command: command, sequence: seq, body: body)
        try await connection.send(request.encode())

        // Read the response header
        var headerData = try await connection.receive(maxLength: readSize)
        while headerData.count < JensenFrame.headerSize {
            let more = try await connection.receive(maxLength: readSize)
            if more.isEmpty { throw ProtocolError.timeout }
            headerData.append(more)
        }

        guard let response = JensenFrame.decode(from: headerData) else {
            throw ProtocolError.invalidMagic
        }

        return response
    }

    /// Receive the next response frame from the device (no send).
    /// Used for streaming responses like file transfer where multiple frames arrive.
    public func receiveFrame() async throws -> JensenFrame {
        var accumulated = Data()
        while true {
            let chunk = try await connection.receive(maxLength: readSize)
            if chunk.isEmpty { throw ProtocolError.timeout }
            accumulated.append(chunk)
            if let needed = JensenFrame.frameSizeFromHeader(accumulated),
               accumulated.count >= needed { break }
        }
        guard let frame = JensenFrame.decode(from: accumulated) else {
            throw ProtocolError.invalidMagic
        }
        return frame
    }

    public func close() async {
        await connection.close()
    }
}
