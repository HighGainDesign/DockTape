import Foundation

/// Errors from the USB transport layer.
public enum USBError: Error, Sendable {
    case deviceNotFound
    case openFailed(String)
    case interfaceNotFound
    case endpointNotFound(UInt8)
    case writeFailed(Int32)
    case readFailed(Int32)
    case readTimeout
    case deviceDisconnected
    case seizeFailed(String)
}

/// Errors from the Jensen protocol layer.
public enum ProtocolError: Error, Sendable {
    case invalidMagic
    case unknownCommand(UInt16)
    case responseTooShort(expected: Int, got: Int)
    case sequenceMismatch(expected: UInt32, got: UInt32)
    case invalidBody(String)
    case timeout
    case commandFailed(UInt8)
}

/// High-level HiDock errors.
public enum HiDockError: Error, Sendable {
    case usb(USBError)
    case proto(ProtocolError)
    case fileNotFound(String)
    case transferFailed(String)
    case conversionFailed(String)
    case storageError(String)
    case noDevice
    case invalidFilename(String)
}
