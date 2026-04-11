// © 2026 High Gain Design. All rights reserved.

import SwiftUI
import HiDockKit

/// Info tab: metadata grid for a single recording.
struct InfoTabView: View {
    let recording: RecordingMetadata
    let transcriptStatus: TranscriptStatus

    var body: some View {
        Form {
            Section("Recording") {
                LabeledContent("Title", value: recording.displayTitle)
                LabeledContent("Filename", value: recording.filename)
                if let date = recording.recordedAt {
                    LabeledContent("Date") {
                        Text(date, style: .date)
                        Text(date, style: .time)
                    }
                }
                LabeledContent("Mode", value: modeDisplayName)
                if let folder = recording.folder {
                    LabeledContent("Folder", value: folder)
                }
            }

            Section("File") {
                LabeledContent("Size", value: formattedSize)
                LabeledContent("Duration", value: formattedDuration)
            }

            Section("Transcription") {
                LabeledContent("Status") {
                    statusLabel
                }
            }
        }
        .formStyle(.grouped)
    }

    @ViewBuilder
    private var statusLabel: some View {
        switch transcriptStatus {
        case .done:
            Label("Complete", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case .inProgress:
            Label("In Progress", systemImage: "ellipsis.circle")
                .foregroundStyle(.orange)
        case .failed:
            Label("Failed", systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
        case .none:
            Text("Not transcribed")
                .foregroundStyle(.secondary)
        }
    }

    private var modeDisplayName: String {
        FilenameParsing.RecordingMode(rawValue: recording.mode)?.displayName ?? recording.mode
    }

    private var formattedSize: String {
        ByteCountFormatter.string(fromByteCount: Int64(recording.fileSizeBytes), countStyle: .file)
    }

    private var formattedDuration: String {
        DurationCalculator.formatDuration(recording.estimatedDuration)
    }
}
