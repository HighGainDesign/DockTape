import Foundation

/// Observable state for a connected HiDock device.
@Observable
public final class DeviceModel: Identifiable, @unchecked Sendable {
    public let id: String  // serial number or unique ID
    public var model: HiDockModel
    public var firmwareVersion: String = ""
    public var serialNumber: String = ""

    public var battery: BatteryInfo?
    public var cardInfo: CardInfo?
    public var settings: DeviceSettings?
    public var files: [FileEntry] = []
    public var deviceTime: Date?

    public var isConnected: Bool = false
    public var isTransferring: Bool = false
    public var transferProgress: Double = 0  // 0.0 to 1.0
    public var transferFilename: String = ""

    public init(id: String, model: HiDockModel = .unknown) {
        self.id = id
        self.model = model
    }
}
