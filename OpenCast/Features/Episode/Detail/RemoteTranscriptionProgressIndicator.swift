import SwiftUI

struct RemoteTranscriptionProgressIndicator: View {
    let progressFraction: Double?

    var body: some View {
        if let progressFraction {
            let clampedFraction = progressFraction.isNaN
                ? 0
                : min(max(progressFraction, 0), 1)
            ProgressView(value: clampedFraction)
                .progressViewStyle(.circular)
                .accessibilityIdentifier("Remote Transcription Chunk Progress")
                .accessibilityLabel("Transcription progress")
                .accessibilityValue("\(Int((clampedFraction * 100).rounded())) percent")
        } else {
            ProgressView()
                .progressViewStyle(.circular)
                .accessibilityLabel("Transcription progress")
        }
    }
}
