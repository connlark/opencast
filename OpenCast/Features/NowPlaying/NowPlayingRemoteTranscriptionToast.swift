import SwiftUI

/// Compact active remote-transcription surface for the currently playing
/// episode. It shares stage, ETA, and determinate progress with the episode
/// status card.
struct NowPlayingRemoteTranscriptionToast: View {
    let presentation: RemoteTranscriptionStatusPresentation
    let onCancel: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            RemoteTranscriptionProgressIndicator(
                progressFraction: presentation.progressFraction
            )

            VStack(alignment: .leading, spacing: 2) {
                Text(presentation.title)
                    .font(.headline)
                    .lineLimit(1)

                if let detail = presentation.detail {
                    Text(detail)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                if let secondaryDetail = presentation.secondaryDetail {
                    Text(secondaryDetail)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Button("Cancel", systemImage: "xmark", action: onCancel)
                .labelStyle(.iconOnly)
                .frame(width: 44, height: 44)
                .contentShape(.circle)
        }
        .padding(.leading, 16)
        .padding(.trailing, 6)
        .padding(.vertical, 8)
        .frame(maxWidth: 420)
        .glassEffect(.regular, in: .rect(cornerRadius: 18))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("Remote Transcription Progress Toast")
    }
}
