import Foundation
import CLibUSB
import IOKit
import IOKit.usb

// Non-capturing C callbacks for IOKit notifications
private func ioKitMatchCallback(refcon: UnsafeMutableRawPointer?, iterator: io_iterator_t) {
    guard let refcon else { return }
    let monitor = Unmanaged<USBDeviceMonitor>.fromOpaque(refcon).takeUnretainedValue()
    monitor.drainIterator(iterator, isConnect: true)
}

private func ioKitRemoveCallback(refcon: UnsafeMutableRawPointer?, iterator: io_iterator_t) {
    guard let refcon else { return }
    let monitor = Unmanaged<USBDeviceMonitor>.fromOpaque(refcon).takeUnretainedValue()
    monitor.drainIterator(iterator, isConnect: false)
}

/// Monitors for HiDock USB device connections.
/// Uses libusb for device scanning and IOKit for hotplug notifications.
public final class USBDeviceMonitor: @unchecked Sendable {
    public struct USBDevice: Sendable {
        public let vendorID: UInt16
        public let productID: UInt16
        public let model: HiDockModel

        public init(vendorID: UInt16, productID: UInt16) {
            self.vendorID = vendorID
            self.productID = productID
            self.model = HiDockModel.from(vendorID: vendorID, productID: productID)
        }
    }

    public typealias DeviceCallback = @Sendable (USBDevice) -> Void

    private var notifyPort: IONotificationPortRef?
    private var iterators: [io_iterator_t] = []
    private var onConnect: DeviceCallback?
    private var onDisconnect: DeviceCallback?
    private let queue = DispatchQueue(label: "com.hidock.usb-monitor")

    public init() {}

    /// One-shot scan for connected HiDock devices using libusb.
    public static func findConnectedDevices() -> [USBDevice] {
        var ctx: OpaquePointer?
        guard libusb_init(&ctx) == 0 else { return [] }
        defer { libusb_exit(ctx) }

        var deviceList: UnsafeMutablePointer<OpaquePointer?>?
        let count = libusb_get_device_list(ctx, &deviceList)
        guard count > 0, let list = deviceList else { return [] }
        defer { libusb_free_device_list(list, 1) }

        var found: [USBDevice] = []
        let knownIDs = Set(DeviceConstants.allDeviceIDs.map { "\($0.vendorID):\($0.productID)" })

        for i in 0..<count {
            guard let dev = list[Int(i)] else { continue }
            var desc = libusb_device_descriptor()
            guard libusb_get_device_descriptor(dev, &desc) == 0 else { continue }

            let key = "\(desc.idVendor):\(desc.idProduct)"
            if knownIDs.contains(key) {
                found.append(USBDevice(vendorID: desc.idVendor, productID: desc.idProduct))
            }
        }

        return found
    }

    /// Start monitoring for HiDock device connections using IOKit notifications.
    public func start(onConnect: @escaping DeviceCallback, onDisconnect: @escaping DeviceCallback) {
        self.onConnect = onConnect
        self.onDisconnect = onDisconnect

        notifyPort = IONotificationPortCreate(kIOMainPortDefault)
        guard let notifyPort else { return }
        IONotificationPortSetDispatchQueue(notifyPort, queue)

        for (vid, pid) in DeviceConstants.allDeviceIDs {
            registerMatching(vid: vid, pid: pid, notifyPort: notifyPort)
        }
    }

    /// Stop monitoring.
    public func stop() {
        for iter in iterators {
            IOObjectRelease(iter)
        }
        iterators.removeAll()
        if let port = notifyPort {
            IONotificationPortDestroy(port)
            notifyPort = nil
        }
    }

    deinit { stop() }

    // MARK: - Private

    private func registerMatching(vid: UInt16, pid: UInt16, notifyPort: IONotificationPortRef) {
        let matching = IOServiceMatching(kIOUSBDeviceClassName) as NSMutableDictionary
        matching[kUSBVendorID] = vid
        matching[kUSBProductID] = pid

        let selfPtr = Unmanaged.passUnretained(self).toOpaque()

        // Add notification
        let matchingAdd = matching.mutableCopy() as! NSMutableDictionary
        var addIter: io_iterator_t = 0
        IOServiceAddMatchingNotification(
            notifyPort,
            kIOFirstMatchNotification,
            matchingAdd,
            ioKitMatchCallback,
            selfPtr,
            &addIter
        )
        drainIterator(addIter, isConnect: true)
        iterators.append(addIter)

        // Remove notification
        let matchingRemove = matching.mutableCopy() as! NSMutableDictionary
        var removeIter: io_iterator_t = 0
        IOServiceAddMatchingNotification(
            notifyPort,
            kIOTerminatedNotification,
            matchingRemove,
            ioKitRemoveCallback,
            selfPtr,
            &removeIter
        )
        drainIterator(removeIter, isConnect: false)
        iterators.append(removeIter)
    }

    fileprivate func drainIterator(_ iterator: io_iterator_t, isConnect: Bool) {
        while case let service = IOIteratorNext(iterator), service != 0 {
            let vid = getProperty(service: service, key: kUSBVendorID) ?? 0
            let pid = getProperty(service: service, key: kUSBProductID) ?? 0
            let device = USBDevice(vendorID: UInt16(vid), productID: UInt16(pid))
            if isConnect {
                onConnect?(device)
            } else {
                onDisconnect?(device)
            }
            IOObjectRelease(service)
        }
    }

    private func getProperty(service: io_service_t, key: String) -> Int? {
        guard let value = IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0) else {
            return nil
        }
        return (value.takeRetainedValue() as? NSNumber)?.intValue
    }
}
