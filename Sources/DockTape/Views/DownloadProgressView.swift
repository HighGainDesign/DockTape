import SwiftUI

struct DownloadProgressView: View {
    let filename: String
    let progress: Double

    var body: some View {
        VStack(spacing: 16) {
            Text("Downloading")
                .font(.headline)

            Text(filename)
                .font(.subheadline)
                .foregroundStyle(.secondary)

            ProgressView(value: progress)
                .progressViewStyle(.linear)
                .accessibilityLabel("Download progress")
                .accessibilityValue("\(Int(progress * 100)) percent")

            Text("\(Int(progress * 100))%")
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
        .padding(32)
        .frame(minWidth: 300)
    }
}
