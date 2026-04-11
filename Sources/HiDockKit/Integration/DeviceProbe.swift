// © 2026 High Gain Design. All rights reserved.

import Foundation

/// Quick integration probe — connects to a real HiDock device and dumps info.
/// Run with: swift run hidock-probe
public enum DeviceProbe {

    public static func run() async {
        print("=== HiDock Device Probe ===\n")

        // 1. Scan for connected devices
        print("[1] Scanning for HiDock devices (via libusb)...")
        let devices = USBDeviceMonitor.findConnectedDevices()

        if devices.isEmpty {
            print("    No HiDock devices found.")
            print("    Make sure the device is plugged in via USB.")
            print("    Known VID/PIDs:")
            for (vid, pid) in DeviceConstants.allDeviceIDs {
                print("      VID=0x\(String(format: "%04X", vid)) PID=0x\(String(format: "%04X", pid))")
            }
            return
        }

        for (i, dev) in devices.enumerated() {
            print("    [\(i)] VID=0x\(String(format: "%04X", dev.vendorID)) PID=0x\(String(format: "%04X", dev.productID)) model=\(dev.model.rawValue)")
        }

        let target = devices[0]
        print("\n[2] Opening USB connection to \(target.model.rawValue) via libusb...")

        let connection = USBConnection(vendorID: target.vendorID, productID: target.productID)
        do {
            try connection.open()
            print("    USB connection opened successfully!")
        } catch {
            print("    FAILED to open: \(error)")
            return
        }

        let transport = JensenTransport(connection: connection)

        // 3. DeviceInfo
        print("\n[3] Sending DeviceInfo command (0x01)...")
        do {
            let response = try await transport.sendCommand(.deviceInfo)
            print("    Response: cmd=0x\(String(format: "%04X", response.command.rawValue)) seq=\(response.sequence) bodyLen=\(response.body.count)")
            hexDump(response.body, label: "    Body")

            let info = try JensenParsers.parseDeviceInfo(response.body)
            print("    Firmware: \(info.firmwareVersion)")
            print("    Serial:   \(info.serialNumber)")
        } catch {
            print("    FAILED: \(error)")
        }

        // 4. Battery
        print("\n[4] Sending Battery command (0x1004)...")
        do {
            let response = try await transport.sendCommand(.battery)
            print("    Response: cmd=0x\(String(format: "%04X", response.command.rawValue)) bodyLen=\(response.body.count)")
            hexDump(response.body, label: "    Body")

            if response.body.count >= 2 {
                let battery = try JensenParsers.parseBattery(response.body)
                print("    Battery: \(battery.level)% charging=\(battery.isCharging)")
            }
        } catch {
            print("    FAILED: \(error)")
        }

        // 5. CardInfo
        print("\n[5] Sending CardInfo command (0x10)...")
        do {
            let response = try await transport.sendCommand(.cardInfo)
            print("    Response: bodyLen=\(response.body.count)")
            hexDump(response.body, label: "    Body")

            if response.body.count >= 12 {
                let card = try JensenParsers.parseCardInfo(response.body)
                let totalGB = Double(card.totalBytes) / 1_073_741_824
                let freeGB = Double(card.freeBytes) / 1_073_741_824
                print("    Card: \(String(format: "%.1f", totalGB)) GB total, \(String(format: "%.1f", freeGB)) GB free, inserted=\(card.isInserted)")
            }
        } catch {
            print("    FAILED: \(error)")
        }

        // 6. FileCount
        print("\n[6] Sending FileCount command (0x06)...")
        do {
            let response = try await transport.sendCommand(.fileCount)
            print("    Response: bodyLen=\(response.body.count)")
            hexDump(response.body, label: "    Body")

            if response.body.count >= 4 {
                let count = try JensenParsers.parseFileCount(response.body)
                print("    Files on device: \(count)")
            }
        } catch {
            print("    FAILED: \(error)")
        }

        // 7. GetTime
        print("\n[7] Sending GetTime command (0x02)...")
        do {
            let response = try await transport.sendCommand(.getTime)
            print("    Response: bodyLen=\(response.body.count)")
            hexDump(response.body, label: "    Body")

            if response.body.count >= 7 {
                let time = try JensenParsers.parseTime(response.body)
                let formatter = DateFormatter()
                formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
                print("    Device time: \(formatter.string(from: time))")
            }
        } catch {
            print("    FAILED: \(error)")
        }

        // 8. FileList
        print("\n[8] Sending FileList command (0x04)...")
        do {
            let response = try await transport.sendCommand(.fileList)
            print("    Response: bodyLen=\(response.body.count)")
            if response.body.count > 0 {
                hexDump(Data(response.body.prefix(512)), label: "    Body (first 512 bytes)")
            }

            let files = try JensenParsers.parseFileList(response.body)
            print("    Parsed \(files.count) file entries:")
            for file in files.prefix(10) {
                let duration = DurationCalculator.formatDuration(
                    DurationCalculator.estimateDuration(fileSize: UInt64(file.size))
                )
                print("      \(file.filename) (\(file.size) bytes, ~\(duration)) md5=\(file.md5.prefix(8))...")
            }
            if files.count > 10 {
                print("      ... and \(files.count - 10) more")
            }
        } catch {
            print("    FAILED: \(error)")
        }

        // Done
        print("\n[9] Closing connection...")
        await transport.close()
        print("    Done!\n")
        print("=== Probe complete ===")
    }

    private static func hexDump(_ data: Data, label: String) {
        guard !data.isEmpty else {
            print("\(label): (empty)")
            return
        }
        // Print in 16-byte rows
        let maxBytes = min(data.count, 128)
        for row in stride(from: 0, to: maxBytes, by: 16) {
            let end = min(row + 16, maxBytes)
            let hex = data[row..<end].map { String(format: "%02X", $0) }.joined(separator: " ")
            let ascii = data[row..<end].map { (0x20...0x7E).contains($0) ? String(UnicodeScalar($0)) : "." }.joined()
            let pad = String(repeating: "   ", count: 16 - (end - row))
            print("\(label)\(row == 0 ? "" : String(repeating: " ", count: label.count)) \(hex)\(pad)  \(ascii)")
        }
        if data.count > maxBytes {
            print("\(String(repeating: " ", count: label.count)) ... (\(data.count) bytes total)")
        }
    }
}
