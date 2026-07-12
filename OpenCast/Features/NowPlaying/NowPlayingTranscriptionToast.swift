import SwiftUI

struct NowPlayingTranscriptionToast: View {
    private static let terminalDisplayDuration: Duration = .seconds(8)

    @Environment(OpenCastAppModel.self) private var appModel

    let request: EpisodeTranscriptionRequest
    let onOpenTranscript: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        HStack(spacing: 0) {
            Button(action: onOpenTranscript) {
                HStack(spacing: 12) {
                    statusIndicator

                    VStack(alignment: .leading, spacing: 2) {
                        Text(title)
                            .font(.headline)
                            .lineLimit(1)

                        Text(detail)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .frame(maxWidth: .infinity, alignment: .leading)
            .disabled(!canOpenTranscript)
            .accessibilityLabel("\(title). \(detail)")
            .accessibilityHint("Opens the transcript", isEnabled: canOpenTranscript)

            Button("Dismiss", systemImage: "xmark", action: onDismiss)
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
        .accessibilityIdentifier("Transcription Progress Toast")
        .task(id: request.phase) {
            await dismissAfterTerminalDelay()
        }
    }

    @ViewBuilder
    private var statusIndicator: some View {
        switch request.phase {
        case .completed:
            Image(systemName: "checkmark.circle.fill")
                .font(.title2)
                .foregroundStyle(.green)
        case .failed:
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.title2)
                .foregroundStyle(.orange)
        case .interrupted:
            Image(systemName: "pause.circle.fill")
                .font(.title2)
                .foregroundStyle(.orange)
        case .cancelled:
            Image(systemName: "xmark.circle.fill")
                .font(.title2)
                .foregroundStyle(.secondary)
        default:
            if let progressFraction {
                ProgressView(value: progressFraction)
                    .progressViewStyle(.circular)
            } else {
                ProgressView()
                    .progressViewStyle(.circular)
            }
        }
    }

    private var title: String {
        switch request.phase {
        case .downloading:
            "Downloading episode"
        case .transcribingAppleSpeech:
            "Transcribing with Apple Speech"
        case .preparingWhisper:
            "Preparing Whisper"
        case .transcribingWhisper:
            "Transcribing with Whisper"
        case .completed:
            "Transcript ready"
        case .interrupted:
            "Transcription paused"
        case .cancelled:
            "Transcription cancelled"
        case .failed:
            "Transcription stopped"
        }
    }

    private var canOpenTranscript: Bool {
        request.phase == .completed
    }

    private var detail: String {
        switch request.phase {
        case .downloading:
            downloadDetail
        case .transcribingAppleSpeech, .transcribingWhisper:
            transcriptionDetail
        case .preparingWhisper:
            whisperPreparationDetail
        case .completed:
            completedDetail
        case .interrupted:
            if request.canResumeFromCheckpoint {
                "Generate the transcript again to resume from the saved checkpoint."
            } else {
                "Generate the transcript again to restart from the beginning."
            }
        case .cancelled:
            "Generate the transcript again to start a new request."
        case .failed(let message):
            message
        }
    }

    private var progressFraction: Double? {
        switch request.phase {
        case .downloading:
            guard let record = downloadRecord,
                  let expected = record.bytesExpected,
                  expected > 0
            else {
                return nil
            }
            return Double(record.bytesReceived) / Double(expected)
        case .preparingWhisper:
            if case .installing(let progress) = appModel.transcriptionModels.state,
               progress.totalByteCount > 0 {
                return Double(progress.completedByteCount) / Double(progress.totalByteCount)
            }
            return nil
        case .transcribingAppleSpeech, .transcribingWhisper:
            return transcriptionProgress?.fractionCompleted
        case .completed, .interrupted, .cancelled, .failed:
            return nil
        }
    }

    private var downloadRecord: EpisodeDownloadRecord? {
        appModel.downloads.record(for: request.episodeID)
    }

    private var transcriptionProgress: EpisodeTranscriptionProgress? {
        appModel.transcriptions.progressByEpisodeID[request.episodeID]
    }

    private var downloadDetail: String {
        guard let record = downloadRecord else {
            return "Preparing audio for on-device transcription."
        }
        let received = record.bytesReceived.formatted(.byteCount(style: .file))
        guard let expected = record.bytesExpected, expected > 0 else {
            return received
        }
        return "\(received) of \(expected.formatted(.byteCount(style: .file)))"
    }

    private var transcriptionDetail: String {
        guard let progress = transcriptionProgress else {
            return "Starting on-device transcription."
        }
        let duration = "\(progress.completedDuration.formattedPlaybackDuration) of \(progress.audioDuration.formattedPlaybackDuration)"
        guard progress.checkpointCount > 0 else {
            return duration
        }
        return "\(duration) · \(progress.checkpointCount) checkpoints"
    }

    private var whisperPreparationDetail: String {
        if case .installing(let progress) = appModel.transcriptionModels.state {
            return "\(progress.completedByteCount.formatted(.byteCount(style: .file))) of \(progress.totalByteCount.formatted(.byteCount(style: .file)))"
        }
        return "Loading the background-safe on-device model."
    }

    private var completedDetail: String {
        guard let record = appModel.transcriptions.record(for: request.episodeID) else {
            return request.episodeTitle
        }
        let duration = record.audioDuration.formattedPlaybackDuration
        return "\(duration) · \(record.checkpointCount) checkpoints"
    }

    private func dismissAfterTerminalDelay() async {
        guard request.phase.isTerminal else {
            return
        }
        do {
            try await Task.sleep(for: Self.terminalDisplayDuration)
        } catch {
            return
        }
        onDismiss()
    }
}
