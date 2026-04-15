// © 2026 High Gain Design. All rights reserved.

import Foundation

/// Byte-level transport abstraction for communicating with a HiDock device.
/// Platform implementations: `USBConnection` (macOS, via libusb), `EAConnection` (iOS, via ExternalAccessory).
public protocol DeviceTransport: Sendable {
    /// Open the connection to the device.
    func open() async throws

    /// Send data to the device.
    func send(_ data: Data) async throws

    /// Receive data from the device.
    /// - Parameter maxLength: Maximum bytes to read (typically 512 or a multiple).
    /// - Returns: Data read from the device.
    func receive(maxLength: Int) async throws -> Data

    /// Close the connection and release resources.
    func close() async
}
