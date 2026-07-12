import OpenCastTranscription
import SwiftUI

struct SettingsTranscriptionModelInstallProgressView: View {
    let progress: OpenCastWhisperModelInstallProgress

    var body: some View {
        if progress.totalByteCount > 0 {
            ProgressView(
                value: Double(progress.completedByteCount),
                total: Double(progress.totalByteCount)
            ) {
                Text("Installing")
            } currentValueLabel: {
                Text("\(byteCount(progress.completedByteCount)) of \(byteCount(progress.totalByteCount))")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        } else {
            ProgressView("Installing")
        }
    }

    private func byteCount(_ bytes: Int64) -> String {
        bytes.formatted(.byteCount(style: .file))
    }
}
