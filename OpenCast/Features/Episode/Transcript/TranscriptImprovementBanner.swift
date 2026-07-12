import SwiftUI

/// In-page progress surface for the foreground-only "Improve Transcript"
/// flow. Observes the improvement coordinator and per-episode transcription
/// progress in its own body so the 1 Hz progress churn never re-evaluates the
/// menu-owning parents.
struct TranscriptImprovementBanner: View {
    @Environment(OpenCastAppModel.self) private var appModel
    @Environment(\.modelContext) private var modelContext

    let episodeID: String

    @State private var isConfirmingStop = false

    var body: some View {
        if appModel.transcriptImprovement.episodeID == episodeID {
            switch appModel.transcriptImprovement.phase {
            case .installingAssets:
                runningContent(
                    statusText: "Preparing Apple Speech",
                    fraction: assetInstallFraction
                )
            case .transcribing:
                runningContent(
                    statusText: transcribingStatusText,
                    fraction: transcriptionProgress?.fractionCompleted
                )
            case .interrupted:
                terminalContent(
                    message: "Improving stopped because OpenCast went to the background. Your original transcript is unchanged."
                )
            case .failed(let message):
                terminalContent(message: message)
            case .idle, .completed:
                EmptyView()
            }
        }
    }

    private func runningContent(statusText: String, fraction: Double?) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(statusText)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Button("Stop", action: confirmStop)
                    .font(.footnote)
                    .buttonStyle(.borderless)
            }
            ProgressView(value: fraction)
            Text("Keep OpenCast open — improving runs only in the foreground and restarts from the beginning if interrupted.")
                .font(.footnote)
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 6)
        .confirmationDialog(
            "Stop Improving?",
            isPresented: $isConfirmingStop,
            titleVisibility: .visible
        ) {
            Button("Stop Improving", role: .destructive, action: stopImproving)
        } message: {
            Text("Your current transcript is kept.")
        }
    }

    private func terminalContent(message: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(message, systemImage: "exclamationmark.triangle")
                .font(.footnote)
                .foregroundStyle(.orange)
            HStack(spacing: 16) {
                Button("Try Again", action: retryImprove)
                    .font(.footnote)
                    .buttonStyle(.borderless)
                Button("Dismiss", action: dismissTerminal)
                    .font(.footnote)
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 6)
    }

    private var transcribingStatusText: String {
        guard let progress = transcriptionProgress else {
            return "Improving with Apple Speech"
        }
        return "Improving with Apple Speech — \(progress.completedDuration.formattedPlaybackDuration) of \(progress.audioDuration.formattedPlaybackDuration)"
    }

    private var transcriptionProgress: EpisodeTranscriptionProgress? {
        appModel.transcriptions.progressByEpisodeID[episodeID]
    }

    private var assetInstallFraction: Double? {
        if case .installing(_, let fraction) = appModel.appleSpeechAssets.state {
            return fraction
        }
        return nil
    }

    private func confirmStop() {
        isConfirmingStop = true
    }

    private func stopImproving() {
        appModel.transcriptImprovement.cancel(modelContext: modelContext)
    }

    private func retryImprove() {
        appModel.improveTranscriptWithAppleSpeech(episodeID: episodeID, modelContext: modelContext)
    }

    private func dismissTerminal() {
        appModel.transcriptImprovement.acknowledgeTerminal()
    }
}
