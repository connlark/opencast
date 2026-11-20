import SwiftUI

struct TranscriptSourceMismatchBanner: View {
    let canSwitchToTranscribedCopy: Bool
    let switchToTranscribedCopy: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(message, systemImage: "waveform.badge.exclamationmark")
                .font(.footnote)
                .foregroundStyle(.secondary)
            if canSwitchToTranscribedCopy {
                Button(
                    "Switch to Transcribed Copy",
                    systemImage: "arrow.triangle.2.circlepath",
                    action: switchToTranscribedCopy
                )
                .font(.subheadline)
                .buttonStyle(.borderless)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassEffect(.regular, in: .rect(cornerRadius: 20))
    }

    private var message: String {
        canSwitchToTranscribedCopy
            ? "Now Playing is using a different copy of this episode than the transcript was made from, so follow-along is paused."
            : "The audio this transcript was made from is no longer downloaded, so follow-along is paused. Tapped lines seek to their listed time, which may not line up. Regenerating the transcript will re-align it with a fresh download."
    }
}
