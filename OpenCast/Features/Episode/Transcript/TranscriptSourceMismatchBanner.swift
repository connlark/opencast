import SwiftUI

/// Floating notice shown while the current player item is not proven to be
/// the audio asset the transcript describes. Follow-along stays suspended in
/// this state so karaoke never fakes synchronization against a different
/// audio assembly, and the switch action restarts playback from the exact
/// downloaded copy the transcript was generated from when it still exists.
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
