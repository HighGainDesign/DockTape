import Foundation

/// High-level async API for communicating with a HiDock device.
/// Wraps JensenTransport with parsed responses and state management.
public actor DeviceManager {
    private var transport: JensenTransport?
    private let device: DeviceModel

    public init(device: DeviceModel) {
        self.device = device
    }

    /// Connect to a device through the given USB connection.
    public func connect(via connection: any USBConnectionProtocol) {
        self.transport = JensenTransport(connection: connection)
    }

    /// Disconnect from the device.
    public func disconnect() async {
        await transport?.close()
        transport = nil
        await MainActor.run { device.isConnected = false }
    }

    // MARK: - Tier 1 Commands

    /// Query device info and update the device model.
    public func queryDeviceInfo() async throws -> DeviceInfo {
        let response = try await requireTransport().sendCommand(.deviceInfo)
        let info = try JensenParsers.parseDeviceInfo(response.body)
        await MainActor.run {
            device.firmwareVersion = info.firmwareVersion
            device.serialNumber = info.serialNumber
            device.isConnected = true
        }
        return info
    }

    /// Query battery status.
    public func queryBattery() async throws -> BatteryInfo {
        let response = try await requireTransport().sendCommand(.battery)
        let battery = try JensenParsers.parseBattery(response.body)
        await MainActor.run { device.battery = battery }
        return battery
    }

    /// Query SD card info.
    public func queryCardInfo() async throws -> CardInfo {
        let response = try await requireTransport().sendCommand(.cardInfo)
        let card = try JensenParsers.parseCardInfo(response.body)
        await MainActor.run { device.cardInfo = card }
        return card
    }

    /// Get the file count on the device.
    public func queryFileCount() async throws -> Int {
        let response = try await requireTransport().sendCommand(.fileCount)
        return try JensenParsers.parseFileCount(response.body)
    }

    /// Get the file list from the device.
    public func queryFileList() async throws -> [FileEntry] {
        let transport = try requireTransport()
        // First get file count to know expected body size
        let countResponse = try await transport.sendCommand(.fileCount)
        let count = try JensenParsers.parseFileCount(countResponse.body)

        guard count > 0 else {
            await MainActor.run { device.files = [] }
            return []
        }

        // Request file list — response may be large (multi-packet)
        let response = try await transport.sendCommand(.fileList)
        let files = try JensenParsers.parseFileList(response.body)
        await MainActor.run { device.files = files }
        return files
    }

    /// Get the current device time.
    public func queryTime() async throws -> Date {
        let response = try await requireTransport().sendCommand(.getTime)
        let time = try JensenParsers.parseTime(response.body)
        await MainActor.run { device.deviceTime = time }
        return time
    }

    /// Sync the device clock to the current system time.
    public func syncTime() async throws {
        let body = BCDCoding.encodeDate(Date())
        _ = try await requireTransport().sendCommand(.setTime, body: body)
    }

    /// Get device settings.
    public func querySettings() async throws -> DeviceSettings {
        let response = try await requireTransport().sendCommand(.getSettings)
        let settings = try JensenParsers.parseSettings(response.body)
        await MainActor.run { device.settings = settings }
        return settings
    }

    /// Update device settings.
    public func updateSettings(_ settings: DeviceSettings) async throws {
        _ = try await requireTransport().sendCommand(.setSettings, body: settings.encode())
        await MainActor.run { device.settings = settings }
    }

    /// Request a file transfer by filename. Returns the raw file data.
    /// Files are requested by name (not index) per the Jensen protocol.
    public func downloadFile(entry: FileEntry) async throws -> Data {
        let transport = try requireTransport()

        await MainActor.run {
            device.isTransferring = true
            device.transferProgress = 0
            device.transferFilename = entry.filename
        }

        do {
            // Send transfer request with filename as body (ASCII bytes)
            let filenameBody = Data(entry.filename.utf8)
            let fileSize = Int(entry.size)
            var fileData = Data()
            fileData.reserveCapacity(fileSize)

            // First response frame contains initial chunk of file data
            let response = try await transport.sendCommand(.transferFile, body: filenameBody)
            if response.body.count > 0 {
                fileData.append(response.body)
            }

            // Read remaining data frames (each is a Jensen frame with cmd=0x05)
            while fileData.count < fileSize {
                try Task.checkCancellation()
                let chunk = try await transport.receiveFrame()
                guard !chunk.body.isEmpty else {
                    throw HiDockError.transferFailed("Received empty data frame during transfer of \(entry.filename)")
                }
                fileData.append(chunk.body)

                let progress = Double(fileData.count) / Double(fileSize)
                await MainActor.run { device.transferProgress = progress }
            }

            await MainActor.run {
                device.isTransferring = false
                device.transferProgress = 0
                device.transferFilename = ""
            }
            return fileData
        } catch {
            await MainActor.run {
                device.isTransferring = false
                device.transferProgress = 0
                device.transferFilename = ""
            }
            throw error
        }
    }

    /// Delete a file on the device by filename.
    public func deleteFile(entry: FileEntry) async throws {
        let filenameBody = Data(entry.filename.utf8)
        let response = try await requireTransport().sendCommand(.deleteFile, body: filenameBody)
        try JensenParsers.parseCommandResult(response.body)
    }

    /// Format the SD card. This erases all recordings on the device.
    public func formatCard() async throws {
        let response = try await requireTransport().sendCommand(.formatCard)
        try JensenParsers.parseCommandResult(response.body)
        // Refresh file list and card info after format
        _ = try await queryFileList()
        _ = try await queryCardInfo()
    }

    // MARK: - Private

    private func requireTransport() throws -> JensenTransport {
        guard let transport else { throw HiDockError.noDevice }
        return transport
    }
}
