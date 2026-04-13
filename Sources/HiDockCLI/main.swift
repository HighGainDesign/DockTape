// © 2026 High Gain Design. All rights reserved.

import HiDockKit
import Foundation

// hidock — unified CLI for HiDock device management
//
// Usage:
//   hidock status                    — device info, battery, storage, file list
//   hidock sync                      — download new files + transcribe + diarize
//   hidock sync --skip-transcribe    — download only, no transcription
//   hidock sync --delete-after       — delete files from device after download
//   hidock transcribe                — transcribe any untranscribed local recordings
//   hidock transcribe FILE           — transcribe a specific recording
//   hidock recordings                — list local recordings and their transcription status
//   hidock export FILE --format txt  — export transcript (txt, jsonl, srt, json)
//   hidock settings                  — show device settings
//   hidock settings set KEY VALUE    — update a device setting
//   hidock clock sync                — sync device clock to system time
//   hidock help                      — show this help

let args = Array(CommandLine.arguments.dropFirst())
let command = args.first ?? "help"

Task {
    do {
        switch command {
        case "status":
            try await runStatus()
        case "sync":
            try await runSync(args: Array(args.dropFirst()))
        case "transcribe":
            try await runTranscribe(args: Array(args.dropFirst()))
        case "recordings":
            try await runRecordings()
        case "export":
            try await runExport(args: Array(args.dropFirst()))
        case "settings":
            try await runSettings(args: Array(args.dropFirst()))
        case "clock":
            if args.dropFirst().first == "sync" {
                try await runClockSync()
            } else {
                try await runClockGet()
            }
        case "help", "--help", "-h":
            printHelp()
        default:
            print("Unknown command: \(command)")
            printHelp()
        }
    } catch {
        print("Error: \(error.localizedDescription)")
    }
    exit(0)
}

RunLoop.main.run()

// MARK: - Commands

func runStatus() async throws {
    let (manager, _) = try await connectDevice()
    defer { Task { await manager.disconnect() } }

    let info = try await manager.queryDeviceInfo()
    let battery = try await manager.queryBattery()
    let card = try await manager.queryCardInfo()
    let files = try await manager.queryFileList()
    let time = try await manager.queryTime()

    let formatter = DateFormatter()
    formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"

    print("Device:    \(info.firmwareVersion)")
    print("Serial:    \(info.serialNumber)")
    print("Battery:   \(battery.level)%\(battery.isCharging ? " (charging)" : "")")
    let totalGB = String(format: "%.1f", Double(card.totalBytes) / 1_073_741_824)
    let freeGB = String(format: "%.1f", Double(card.freeBytes) / 1_073_741_824)
    print("Storage:   \(freeGB) GB free / \(totalGB) GB total")
    print("Clock:     \(formatter.string(from: time))")
    print("Files:     \(files.count)")

    if !files.isEmpty {
        print("")
        for file in files {
            let sizeMB = String(format: "%6.1f MB", Double(file.size) / 1_048_576)
            let duration = DurationCalculator.formatDuration(
                DurationCalculator.estimateDuration(fileSize: UInt64(file.size)))
            print("  \(file.filename)  \(sizeMB)  ~\(duration)")
        }
    }
}

func runSync(args: [String]) async throws {
    let skipTranscribe = args.contains("--skip-transcribe")
    let deleteAfter = args.contains("--delete-after")
    let numSpeakers = parseIntFlag(args, flag: "--speakers")

    let (manager, _) = try await connectDevice()

    let pipeline = RecordingPipeline()
    try await pipeline.setup()
    print("Storage: \(pipeline.storageDirectory.path)\n")

    if deleteAfter {
        print("WARNING: --delete-after enabled. Files will be removed from device after download.\n")
    }

    try await pipeline.downloadAndTranscribeAll(
        deviceManager: manager,
        skipTranscription: skipTranscribe,
        deleteAfterDownload: deleteAfter,
        numSpeakers: numSpeakers
    ) { event in
        printEvent(event)
    }

    await manager.disconnect()
}

func runTranscribe(args: [String]) async throws {
    let numSpeakers = parseIntFlag(args, flag: "--speakers")
    let pipeline = RecordingPipeline()
    try await pipeline.setup()

    let positionalArgs = args.filter { !$0.hasPrefix("-") && Int($0) == nil }
    if let filename = positionalArgs.first {
        // Transcribe specific file
        print("Transcribing \(filename)...")
        let transcript = try await pipeline.transcribeRecording(filename: filename)
        print("Done: \(transcript.segments.count) segments, \(transcript.speakerIDs.count) speakers")
    } else {
        // Transcribe all untranscribed
        try await pipeline.transcribeAllLocal(numSpeakers: numSpeakers) { event in
            printEvent(event)
        }
    }
}

func runRecordings() async throws {
    let pipeline = RecordingPipeline()
    try await pipeline.setup()

    let recordings = await pipeline.allRecordings()
    if recordings.isEmpty {
        print("No local recordings. Run 'hidock sync' to download from device.")
        return
    }

    print("Local recordings (\(recordings.count)):\n")
    for meta in recordings.sorted(by: { ($0.recordedAt ?? .distantPast) > ($1.recordedAt ?? .distantPast) }) {
        let duration = DurationCalculator.formatDuration(meta.estimatedDuration)
        let hasTranscript = await pipeline.transcript(for: meta.filename) != nil
        let status = hasTranscript ? "transcribed" : "not transcribed"
        let dateStr: String
        if let date = meta.recordedAt {
            let fmt = DateFormatter()
            fmt.dateFormat = "yyyy-MM-dd HH:mm"
            dateStr = fmt.string(from: date)
        } else {
            dateStr = "unknown date"
        }
        print("  \(meta.filename)  ~\(duration)  \(dateStr)  [\(status)]")
    }
}

func runExport(args: [String]) async throws {
    guard let filename = args.first, !filename.hasPrefix("-") else {
        print("Usage: hidock export FILENAME [--format txt|jsonl|srt|json]")
        return
    }

    let format: String
    if let positionalFormat = args.dropFirst().first(where: { !$0.hasPrefix("-") }) {
        format = positionalFormat
    } else if let idx = args.firstIndex(of: "--format"), idx + 1 < args.count {
        format = args[idx + 1]
    } else {
        format = "txt"
    }

    let pipeline = RecordingPipeline()
    try await pipeline.setup()

    guard let transcript = await pipeline.transcript(for: filename) else {
        print("No transcript found for \(filename). Run 'hidock transcribe \(filename)' first.")
        return
    }

    let output: String
    switch format {
    case "txt":
        output = TranscriptExporter.exportPlainText(transcript: transcript)
    case "srt":
        output = TranscriptExporter.exportSRT(transcript: transcript)
    case "jsonl":
        let data = TranscriptExporter.exportJSONLines(transcript: transcript)
        output = String(data: data, encoding: .utf8) ?? ""
    case "json":
        let data = TranscriptExporter.exportJSON(transcript: transcript)
        output = String(data: data, encoding: .utf8) ?? ""
    default:
        print("Unknown format: \(format). Use txt, jsonl, srt, or json.")
        return
    }

    print(output)
}

func runSettings(args: [String]) async throws {
    let (manager, _) = try await connectDevice()
    defer { Task { await manager.disconnect() } }

    if args.first == "set", args.count >= 3 {
        let key = args[1]
        let value = args[2]
        var settings = try await manager.querySettings()

        switch key {
        case "auto-record":
            settings = DeviceSettings(
                autoRecord: value == "on" || value == "true",
                autoPlay: settings.autoPlay,
                notification: settings.notification)
        case "auto-play":
            settings = DeviceSettings(
                autoRecord: settings.autoRecord,
                autoPlay: value == "on" || value == "true",
                notification: settings.notification)
        case "notification":
            settings = DeviceSettings(
                autoRecord: settings.autoRecord,
                autoPlay: settings.autoPlay,
                notification: value == "on" || value == "true")
        default:
            print("Unknown setting: \(key). Options: auto-record, auto-play, notification")
            return
        }
        try await manager.updateSettings(settings)
        print("Updated \(key) = \(value)")
    } else {
        let settings = try await manager.querySettings()
        print("Device Settings:")
        print("  auto-record:  \(settings.autoRecord ? "on" : "off")")
        print("  auto-play:    \(settings.autoPlay ? "on" : "off")")
        print("  notification: \(settings.notification ? "on" : "off")")
    }
}

func runClockGet() async throws {
    let (manager, _) = try await connectDevice()
    defer { Task { await manager.disconnect() } }

    let time = try await manager.queryTime()
    let formatter = DateFormatter()
    formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
    print("Device time: \(formatter.string(from: time))")
    print("System time: \(formatter.string(from: Date()))")
}

func runClockSync() async throws {
    let (manager, _) = try await connectDevice()
    defer { Task { await manager.disconnect() } }

    try await manager.syncTime()
    print("Device clock synced to system time.")
}

// MARK: - Helpers

func parseIntFlag(_ args: [String], flag: String) -> Int? {
    guard let idx = args.firstIndex(of: flag), idx + 1 < args.count else { return nil }
    return Int(args[idx + 1])
}

func connectDevice() async throws -> (DeviceManager, USBDeviceMonitor.USBDevice) {
    let devices = USBDeviceMonitor.findConnectedDevices()
    guard let target = devices.first else {
        throw HiDockError.noDevice
    }

    let connection = USBConnection(vendorID: target.vendorID, productID: target.productID)
    try await connection.open()

    let device = await DeviceModel(id: target.model.rawValue, model: target.model)
    let manager = DeviceManager(device: device)
    await manager.connect(via: connection)

    return (manager, target)
}

func printEvent(_ event: RecordingPipeline.Event) {
    switch event {
    case .downloading(let filename, let sizeMB):
        print("  Downloading \(filename) (\(sizeMB) MB)...", terminator: "")
        fflush(stdout)
    case .downloaded(let filename):
        print(" done -> \(filename)")
    case .skippedDownload(let filename):
        print("  Already have \(filename)")
    case .downloadFailed(let filename, let error):
        print("  FAILED \(filename): \(error)")
    case .loadingModels:
        print("\nLoading AI models (first run downloads ~100 MB from HuggingFace)...")
    case .modelsReady:
        print("Models loaded.\n")
    case .transcribing(let filename, let duration):
        print("  Transcribing \(filename) (~\(duration))...")
    case .transcribed(let filename, let segments, let speakers, let elapsed):
        print("    \(segments) segments, \(speakers) speakers in \(elapsed)s")
    case .skippedTranscription(let filename):
        print("  Already transcribed \(filename)")
    case .transcriptionFailed(let filename, let error):
        print("  Transcription FAILED for \(filename): \(error)")
    case .complete(let count):
        print("\nDone. \(count) files processed.")
    }
}

func printHelp() {
    print("""
    hidock — HiDock device manager

    Commands:
      status                         Device info, battery, storage, files
      sync [--skip-transcribe]       Download new files + transcribe
           [--delete-after]          Delete from device after download
           [--speakers N]            Hint: expected number of speakers
      transcribe [FILE]              Transcribe recordings (all or specific)
               [--speakers N]        Hint: expected number of speakers
      recordings                     List local recordings
      export FILE [--format FMT]     Export transcript (txt, jsonl, srt, json)
      settings                       Show device settings
      settings set KEY VALUE         Update setting (auto-record, auto-play, notification)
      clock                          Show device vs system time
      clock sync                     Sync device clock to system time
      help                           Show this help

    Storage: ~/Documents/HiDock Recordings/
    """)
}
