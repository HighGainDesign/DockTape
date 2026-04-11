// © 2026 High Gain Design. All rights reserved.

import SwiftUI
import HiDockKit

/// Detail card shown when multiple recordings are selected.
struct MultiSelectSummary: View {
    let recordings: [RecordingMetadata]
    let transcriptionStatuses: [String: TranscriptStatus]
    var summaryStatuses: Set<String> = []

    private var totalSize: UInt64 {
        recordings.reduce(0) { $0 + $1.fileSizeBytes }
    }

    private var totalDuration: TimeInterval {
        recordings.reduce(0) { $0 + $1.estimatedDuration }
    }

    private var transcribedCount: Int {
        recordings.filter { (transcriptionStatuses[$0.filename] ?? .none) == .done }.count
    }

    private var summarizedCount: Int {
        recordings.filter { summaryStatuses.contains($0.filename) }.count
    }

    var body: some View {
        VStack(spacing: 20) {
            Spacer()

            Image(systemName: "doc.on.doc.fill")
                .font(.system(size: 48))
                .foregroundStyle(.secondary)

            Text("\(recordings.count) recordings selected")
                .font(.title2.weight(.medium))

            // Stats grid
            Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 8) {
                GridRow {
                    Text("Total Size").foregroundStyle(.secondary)
                    Text(formattedSize)
                }
                GridRow {
                    Text("Total Duration").foregroundStyle(.secondary)
                    Text(DurationCalculator.formatDuration(totalDuration))
                }
                GridRow {
                    Text("Transcribed").foregroundStyle(.secondary)
                    Text("\(transcribedCount) of \(recordings.count)")
                }
                GridRow {
                    Text("Summarized").foregroundStyle(.secondary)
                    Text("\(summarizedCount) of \(recordings.count)")
                }
            }
            .font(.body)

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var formattedSize: String {
        ByteCountFormatter.string(fromByteCount: Int64(totalSize), countStyle: .file)
    }
}
