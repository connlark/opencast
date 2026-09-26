import SwiftUI

/// Glass status card for the remote transcription flow on episode detail:
/// live phase with Cancel while a request runs, Resume (and Cancel) while
/// the job is parked on the server, and a visible terminal state with Try
/// Again and the on-device fallback when it ends without a transcript.
struct RemoteTranscriptionStatusCard: View {
    let presentation: RemoteTranscriptionStatusPresentation
    let onTranscribeLocally: () -> Void
    let onResume: () -> Void
    let onCancel: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                statusIndicator

                Text(presentation.title)
                    .font(.headline)

                Spacer(minLength: 12)

                if presentation.isTerminalFailure {
                    Button("Dismiss", systemImage: "xmark", action: onDismiss)
                        .labelStyle(.iconOnly)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                } else {
                    Button("Cancel", action: onCancel)
                        .font(.subheadline)
                        .buttonStyle(.glass)
                }
            }

            if let detail = presentation.detail {
                Text(detail)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            if let secondaryDetail = presentation.secondaryDetail {
                Text(secondaryDetail)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            if presentation.offersResume || presentation.offersRetry || presentation.offersLocalFallback {
                HStack(spacing: 10) {
                    if presentation.offersResume {
                        Button(
                            RemoteTranscriptionStatusPresentation.resumeActionTitle,
                            systemImage: "play.circle",
                            action: onResume
                        )
                        .buttonStyle(.glassProminent)
                    } else if presentation.offersRetry {
                        Button(
                            RemoteTranscriptionStatusPresentation.retryActionTitle,
                            systemImage: "arrow.clockwise",
                            action: onResume
                        )
                        .buttonStyle(.glass)
                    }

                    if presentation.offersLocalFallback {
                        Button(
                            RemoteTranscriptionStatusPresentation.localFallbackActionTitle,
                            systemImage: "text.quote",
                            action: onTranscribeLocally
                        )
                        .buttonStyle(.glass)
                    }
                }
                .font(.subheadline)
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassEffect(.regular, in: .rect(cornerRadius: 26))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("Remote Transcription Status Card")
    }

    @ViewBuilder
    private var statusIndicator: some View {
        if presentation.isTerminalFailure {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.headline)
                .foregroundStyle(.orange)
        } else if presentation.isParked {
            Image(systemName: "pause.circle.fill")
                .font(.headline)
                .foregroundStyle(.secondary)
        } else {
            RemoteTranscriptionProgressIndicator(
                progressFraction: presentation.progressFraction
            )
            .controlSize(.small)
        }
    }
}

#Preview("States") {
    VStack(spacing: 16) {
        RemoteTranscriptionStatusCard(
            presentation: RemoteTranscriptionStatusPresentation.make(
                phase: .failed(.serverRejected(.transcriptionFailed))
            )!,
            onTranscribeLocally: {},
            onResume: {},
            onCancel: {},
            onDismiss: {}
        )
        RemoteTranscriptionStatusCard(
            presentation: RemoteTranscriptionStatusPresentation.make(
                phase: .parkedOnServer(.connectionLost)
            )!,
            onTranscribeLocally: {},
            onResume: {},
            onCancel: {},
            onDismiss: {}
        )
        RemoteTranscriptionStatusCard(
            presentation: RemoteTranscriptionStatusPresentation.make(
                phase: .failed(.localRequestFailed)
            )!,
            onTranscribeLocally: {},
            onResume: {},
            onCancel: {},
            onDismiss: {}
        )
        RemoteTranscriptionStatusCard(
            presentation: RemoteTranscriptionStatusPresentation.make(
                phase: .processing(RemoteTranscriptionActiveProgress(
                    stage: .transcribing,
                    completedChunks: 3,
                    totalChunks: 7,
                    fractionCompleted: 3.0 / 7.0,
                    estimate: .onTrack(remainingSeconds: 52)
                ))
            )!,
            onTranscribeLocally: {},
            onResume: {},
            onCancel: {},
            onDismiss: {}
        )
    }
    .padding()
    .preferredColorScheme(.dark)
}
