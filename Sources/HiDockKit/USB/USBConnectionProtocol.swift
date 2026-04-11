// © 2026 High Gain Design. All rights reserved.

import Foundation

/// Protocol defining the USB bulk transfer interface.
/// Concrete implementations: `USBConnection` (real hardware) and `MockUSBConnection` (testing).
public protocol USBConnectionProtocol: Sendable {
    /// Send data to the device's bulk OUT endpoint.
    func send(_ data: Data) async throws

    /// Receive data from the device's bulk IN endpoint.
    /// - Parameter maxLength: Maximum bytes to read (typically 512 or a multiple).
    /// - Returns: Data read from the device.
    func receive(maxLength: Int) async throws -> Data

    /// Close the connection and release USB resources.
    func close() async
}
