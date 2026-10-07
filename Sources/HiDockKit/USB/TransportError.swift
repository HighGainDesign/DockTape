// © 2026 High Gain Design. All rights reserved.

import Foundation

/// Errors from the device transport layer (USB, ExternalAccessory, etc.).
public enum TransportError: LocalizedError, Sendable {
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
public enum ProtocolError: LocalizedError, Sendable {
    case invalidMagic
    case unknownCommand(UInt16)
    case responseTooShort(expected: Int, got: Int)
    case sequenceMismatch(expected: UInt32, got: UInt32)
    case invalidBody(String)
    case timeout
    case commandFailed(UInt8)
}

/// High-level HiDock errors.
public enum HiDockError: LocalizedError, Sendable {
    case usb(TransportError)
    case proto(ProtocolError)
    case fileNotFound(String)
    case transferFailed(String)
    case conversionFailed(String)
    case storageError(String)
    case noDevice
    case invalidFilename(String)
}

public extension TransportError {
    var errorDescription: String? {
        switch self {
        case .deviceNotFound: "No HiDock device found. Connect it and try again."
        case .openFailed(let reason), .seizeFailed(let reason): reason
        case .interfaceNotFound: "The HiDock USB interface is unavailable."
        case .endpointNotFound: "The HiDock USB connection is incomplete."
        case .writeFailed(let code): "Could not send data to HiDock (USB error \(code))."
        case .readFailed(let code): "Could not read data from HiDock (USB error \(code))."
        case .readTimeout: "HiDock did not respond in time. Check the connection and try again."
        case .deviceDisconnected: "HiDock was disconnected. Reconnect it and try again."
        }
    }
}

public extension ProtocolError {
    var errorDescription: String? {
        switch self {
        case .invalidMagic: "HiDock returned an unrecognized response."
        case .unknownCommand(let command): "HiDock returned an unsupported command (\(command))."
        case .responseTooShort(let expected, let got):
            "HiDock returned an incomplete response (expected \(expected) bytes, received \(got))."
        case .sequenceMismatch: "HiDock returned a response for a different request. Try again."
        case .invalidBody(let reason): reason
        case .timeout: "HiDock did not respond in time. Check the connection and try again."
        case .commandFailed(let status): "HiDock could not complete the request (status \(status))."
        }
    }
}

public extension HiDockError {
    var errorDescription: String? {
        switch self {
        case .usb(let error): error.localizedDescription
        case .proto(let error): error.localizedDescription
        case .fileNotFound(let filename): "Recording not found: \(filename)"
        case .transferFailed(let reason), .conversionFailed(let reason), .storageError(let reason): reason
        case .noDevice: "No HiDock device connected. Connect it and try again."
        case .invalidFilename(let filename): "The recording name is invalid or already exists: \(filename)"
        }
    }
}
