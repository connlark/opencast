import SwiftUI

/// Glass status card for the remote transcription flow on episode detail:
/// live phase with Cancel while a request runs, and a visible terminal state
/// with the on-device fallback when it ends without a transcript.
struct RemoteTranscriptionStatusCard: View {
    let presentation: RemoteTranscriptionStatusPresentation
    let onTranscribeLocally: () -> Void
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

            if presentation.offersLocalFallback {
                Button(
                    RemoteTranscriptionStatusPresentation.localFallbackActionTitle,
                    systemImage: "text.quote",
                    action: onTranscribeLocally
                )
                .font(.subheadline)
                .buttonStyle(.glass)
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
        } else {
            RemoteTranscriptionProgressIndicator(
                progressFraction: presentation.progressFraction
            )
            .controlSize(.small)
        }
    }
}

#Preview("Failure") {
    VStack(spacing: 16) {
        RemoteTranscriptionStatusCard(
            presentation: RemoteTranscriptionStatusPresentation.make(
                phase: .failed(.serverRejected(.transcriptionFailed))
            )!,
            onTranscribeLocally: {},
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
            onCancel: {},
            onDismiss: {}
        )
    }
    .padding()
    .preferredColorScheme(.dark)
}
