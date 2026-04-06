import Foundation

/// Known HiDock device vendor/product IDs and USB endpoint addresses.
public enum DeviceConstants {
    // MARK: - Vendor IDs
    public static let vendorIDActions: UInt16 = 0x10D6
    public static let vendorIDHiDock: UInt16 = 0x388F

    // MARK: - Product IDs (Actions Semiconductor — older devices)
    // Mapping confirmed by kms254/hidock-mcp and nhblock/midock
    public static let pidH1: UInt16 = 0xB00C
    public static let pidH1E: UInt16 = 0xB00D
    public static let pidP1: UInt16 = 0xB00E
    public static let pidP1Mini: UInt16 = 0xB00F

    // MARK: - Product IDs (HiDock branded — newer firmware)
    public static let pidHiDockP1: UInt16 = 0x0100
    public static let pidHiDockP1Mini: UInt16 = 0x0101
    public static let pidHiDockH1: UInt16 = 0x0102
    public static let pidHiDockH1E: UInt16 = 0x0103
    public static let pidHiDockP1v2: UInt16 = 0x0240
    public static let pidHiDockP1Miniv2: UInt16 = 0x0241

    // MARK: - Endpoints
    public static let bulkOutEndpoint: UInt8 = 0x01
    public static let bulkInEndpoint: UInt8 = 0x82

    // MARK: - All known VID/PID pairs
    public static let allDeviceIDs: [(vendorID: UInt16, productID: UInt16)] = [
        (vendorIDActions, pidP1),
        (vendorIDActions, pidP1Mini),
        (vendorIDActions, pidH1),
        (vendorIDActions, pidH1E),
        (vendorIDHiDock, pidHiDockP1),
        (vendorIDHiDock, pidHiDockP1Mini),
        (vendorIDHiDock, pidHiDockH1),
        (vendorIDHiDock, pidHiDockH1E),
        (vendorIDHiDock, pidHiDockP1v2),
        (vendorIDHiDock, pidHiDockP1Miniv2),
    ]
}

/// HiDock device model.
public enum HiDockModel: String, Sendable, CaseIterable {
    case p1 = "P1"
    case p1Mini = "P1 Mini"
    case h1 = "H1"
    case h1e = "H1E"
    case unknown = "Unknown"

    public static func from(vendorID: UInt16, productID: UInt16) -> HiDockModel {
        switch (vendorID, productID) {
        case (DeviceConstants.vendorIDActions, DeviceConstants.pidP1),
             (DeviceConstants.vendorIDHiDock, DeviceConstants.pidHiDockP1),
             (DeviceConstants.vendorIDHiDock, DeviceConstants.pidHiDockP1v2):
            return .p1
        case (DeviceConstants.vendorIDActions, DeviceConstants.pidP1Mini),
             (DeviceConstants.vendorIDHiDock, DeviceConstants.pidHiDockP1Mini),
             (DeviceConstants.vendorIDHiDock, DeviceConstants.pidHiDockP1Miniv2):
            return .p1Mini
        case (DeviceConstants.vendorIDActions, DeviceConstants.pidH1),
             (DeviceConstants.vendorIDHiDock, DeviceConstants.pidHiDockH1):
            return .h1
        case (DeviceConstants.vendorIDActions, DeviceConstants.pidH1E),
             (DeviceConstants.vendorIDHiDock, DeviceConstants.pidHiDockH1E):
            return .h1e
        default:
            return .unknown
        }
    }
}
