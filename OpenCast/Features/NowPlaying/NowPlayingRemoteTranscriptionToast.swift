import SwiftUI

/// Compact active remote-transcription surface for the currently playing
/// episode. It shares stage, ETA, and determinate progress with the episode
/// status card, shows Resume while the job is parked on the server, and
/// keeps Cancel as the user cancel in both states.
struct NowPlayingRemoteTranscriptionToast: View {
    let presentation: RemoteTranscriptionStatusPresentation
    let canOpenEpisode: Bool
    let onOpenEpisode: () -> Void
    let onResume: () -> Void
    let onCancel: () -> Void

    var body: some View {
        HStack(spacing: 0) {
            Button(action: onOpenEpisode) {
                HStack(spacing: 12) {
                    if presentation.isParked {
                        Image(systemName: "pause.circle.fill")
                            .font(.headline)
                            .foregroundStyle(.secondary)
                    } else {
                        RemoteTranscriptionProgressIndicator(
                            progressFraction: presentation.progressFraction
                        )
                    }

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
                }
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .disabled(!canOpenEpisode)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityLabel(accessibilityLabel)
            .accessibilityHint("Opens the episode description.")
            .accessibilityIdentifier("Open Episode Description from Remote Toast")

            if presentation.offersResume {
                Button(
                    RemoteTranscriptionStatusPresentation.resumeActionTitle,
                    systemImage: "play.circle",
                    action: onResume
                )
                .labelStyle(.iconOnly)
                .frame(width: 44, height: 44)
                .contentShape(.circle)
                .accessibilityIdentifier("Resume Remote Transcription from Toast")
            }

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

    private var accessibilityLabel: String {
        [presentation.title, presentation.detail, presentation.secondaryDetail]
            .compactMap { $0 }
            .joined(separator: ". ")
    }
}
