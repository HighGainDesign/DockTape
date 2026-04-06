import Foundation
import CLibUSB

/// Real USB connection to a HiDock device using libusb-1.0.
/// This matches the approach used by all working HiDock tools
/// (pyusb, node-usb — both libusb backends).
public final class USBConnection: USBConnectionProtocol, @unchecked Sendable {
    private var context: OpaquePointer?      // libusb_context*
    private var handle: OpaquePointer?       // libusb_device_handle*
    private let vendorID: UInt16
    private let productID: UInt16
    private let interfaceNum: Int32 = 0
    private let ioQueue = DispatchQueue(label: "com.hidock.usb-io")
    private let timeoutMs: UInt32 = 5000     // 5 second timeout

    public init(vendorID: UInt16, productID: UInt16) {
        self.vendorID = vendorID
        self.productID = productID
    }

    /// Open the device, detach kernel driver if needed, claim interface.
    public func open() throws {
        // Init libusb
        var ctx: OpaquePointer?
        let initResult = libusb_init(&ctx)
        guard initResult == 0 else {
            throw USBError.openFailed("libusb_init failed: \(initResult)")
        }
        context = ctx

        // Open device by VID/PID
        handle = libusb_open_device_with_vid_pid(ctx, vendorID, productID)
        guard handle != nil else {
            throw USBError.deviceNotFound
        }

        // Auto-detach kernel driver when claiming (works cross-platform;
        // on macOS this enables IOKit device seize)
        let autoDetach = libusb_set_auto_detach_kernel_driver(handle, 1)
        print("    auto_detach_kernel_driver: \(autoDetach)")

        // Try set_configuration first (like midock does).
        // On macOS this can fail — not fatal, claim_interface is what matters.
        let configResult = libusb_set_configuration(handle, 1)
        print("    set_configuration: \(configResult)")

        // Claim interface
        let claimResult = libusb_claim_interface(handle, interfaceNum)
        if claimResult != 0 {
            print("    claim_interface failed: \(claimResult)")
            print("")
            print("    On macOS, grant USB access to your terminal app:")
            print("    System Settings → Privacy & Security → USB")
            print("    (Add Terminal.app or your IDE)")
            print("")
            print("    Also try: unplug/replug device, close HiNotes browser tab")
            throw USBError.openFailed("libusb_claim_interface failed: \(claimResult)")
        }
    }

    public func send(_ data: Data) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            self.ioQueue.async {
                var transferred: Int32 = 0
                let result = data.withUnsafeBytes { rawBuffer -> Int32 in
                    guard let ptr = rawBuffer.baseAddress else { return -1 }
                    return libusb_bulk_transfer(
                        self.handle,
                        DeviceConstants.bulkOutEndpoint,
                        UnsafeMutablePointer(mutating: ptr.assumingMemoryBound(to: UInt8.self)),
                        Int32(rawBuffer.count),
                        &transferred,
                        self.timeoutMs
                    )
                }
                if result == 0 {
                    continuation.resume()
                } else {
                    continuation.resume(throwing: USBError.writeFailed(result))
                }
            }
        }
    }

    public func receive(maxLength: Int) async throws -> Data {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data, Error>) in
            self.ioQueue.async {
                var buffer = [UInt8](repeating: 0, count: maxLength)
                var transferred: Int32 = 0
                let result = libusb_bulk_transfer(
                    self.handle,
                    DeviceConstants.bulkInEndpoint,
                    &buffer,
                    Int32(maxLength),
                    &transferred,
                    self.timeoutMs
                )
                if result == 0 || result == LIBUSB_ERROR_TIMEOUT.rawValue {
                    // Timeout with some data is OK for streaming
                    if transferred > 0 {
                        continuation.resume(returning: Data(buffer.prefix(Int(transferred))))
                    } else if result == LIBUSB_ERROR_TIMEOUT.rawValue {
                        continuation.resume(throwing: USBError.readTimeout)
                    } else {
                        continuation.resume(returning: Data())
                    }
                } else {
                    continuation.resume(throwing: USBError.readFailed(result))
                }
            }
        }
    }

    public func close() async {
        if let h = handle {
            libusb_release_interface(h, interfaceNum)
            libusb_close(h)
            handle = nil
        }
        if let ctx = context {
            libusb_exit(ctx)
            context = nil
        }
    }
}
