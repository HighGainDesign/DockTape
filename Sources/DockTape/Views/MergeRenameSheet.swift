// © 2026 High Gain Design. All rights reserved.

import SwiftUI
import HiDockKit

/// Sheet shown when merging recordings — lets the user name the merged file.
struct MergeRenameSheet: View {
    @Bindable var state: AppState
    @State private var mergeName: String = ""
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 16) {
            Text("Merge \(state.mergeFilenames.count) Recordings")
                .font(.headline)

            Text("The following recordings will be merged in order:")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            List {
                ForEach(Array(state.mergeFilenames.enumerated()), id: \.offset) { index, filename in
                    let rec = state.library.recordings.first { $0.filename == filename }
                    HStack {
                        Text("\(index + 1).")
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                        Text(rec?.displayTitle ?? filename)
                        Spacer()
                        if let rec {
                            Text(DurationCalculator.formatDuration(rec.estimatedDuration))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .onMove { from, to in
                    state.mergeFilenames.move(fromOffsets: from, toOffset: to)
                }
            }
            .frame(height: min(CGFloat(state.mergeFilenames.count) * 28 + 20, 200))
            .listStyle(.bordered)

            TextField("Name for merged recording", text: $mergeName)
                .textFieldStyle(.roundedBorder)

            HStack {
                Button("Cancel") {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)

                Spacer()

                Button("Merge") {
                    dismiss()
                    Task {
                        await state.executeMerge(as: mergeName)
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(mergeName.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding()
        .frame(width: 400)
        .onAppear {
            // Default name from first recording
            if let first = state.mergeFilenames.first,
               let rec = state.library.recordings.first(where: { $0.filename == first }) {
                mergeName = "\(rec.displayTitle) (Merged)"
            }
        }
    }
}
