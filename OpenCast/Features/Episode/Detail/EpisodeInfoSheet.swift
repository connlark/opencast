import SwiftUI

/// Technical detail the redesigned screen keeps out of the main scroll:
/// source URL, byte counts, transcript and ad-analysis internals.
struct EpisodeInfoSheet: View {
    @Environment(OpenCastAppModel.self) private var appModel
    @Environment(\.dismiss) private var dismiss

    let episodeID: String

    var body: some View {
        NavigationStack {
            List {
                if let episode = appModel.library.episode(with: episodeID) {
                    episodeSection(episode)
                }
                if let record = appModel.downloads.record(for: episodeID) {
                    downloadSection(record)
                }
                if let record = appModel.transcriptions.record(for: episodeID) {
                    transcriptSection(record)
                }
                if let record = appModel.adAnalyses.record(for: episodeID) {
                    analysisSection(record)
                }
            }
            .navigationTitle("Episode Info")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done", action: dismiss.callAsFunction)
                }
            }
        }
    }

    private func episodeSection(_ episode: EpisodeListItemSnapshot) -> some View {
        Section("Episode") {
            if let audioURL = episode.audioURL {
                LabeledContent("Audio URL") {
                    Text(audioURL)
                        .font(.footnote)
                        .multilineTextAlignment(.trailing)
                        .textSelection(.enabled)
                }
            }
            if let publishedAt = episode.publishedAt {
                LabeledContent("Published") {
                    Text(publishedAt, format: .dateTime.month(.wide).day().year())
                }
            }
            if let duration = episode.duration, duration > 0 {
                LabeledContent("Duration", value: duration.formattedPlaybackDuration)
            }
        }
    }

    private func downloadSection(_ record: EpisodeDownloadRecord) -> some View {
        Section {
            LabeledContent("Status", value: record.state.rawValue.capitalized)
            let progress = appModel.downloads.byteProgress(for: episodeID)
            LabeledContent("Received", value: byteCount(progress?.bytesReceived ?? record.bytesReceived))
            if let bytesExpected = progress?.bytesExpected ?? record.bytesExpected {
                LabeledContent("Expected", value: byteCount(bytesExpected))
            }
            if let errorMessage = record.errorMessage {
                LabeledContent("Error") {
                    Text(errorMessage)
                        .font(.footnote)
                        .multilineTextAlignment(.trailing)
                }
            }
        } header: {
            Text("Download")
        } footer: {
            Text("Stored on this device only.")
        }
    }

    private func transcriptSection(_ record: EpisodeTranscriptRecord) -> some View {
        Section("Transcript") {
            LabeledContent("Status", value: record.state.rawValue.capitalized)
            if !record.modelIdentifier.isEmpty {
                LabeledContent("Model", value: record.modelIdentifier)
            }
            if !record.modelVersion.isEmpty {
                LabeledContent("Model Version", value: record.modelVersion)
            }
            LabeledContent("Language", value: record.languageCode)
            LabeledContent("Checkpoints", value: record.checkpointCount, format: .number)
            if let errorMessage = record.errorMessage {
                LabeledContent("Error") {
                    Text(errorMessage)
                        .font(.footnote)
                        .multilineTextAlignment(.trailing)
                }
            }
        }
    }

    private func analysisSection(_ record: EpisodeAdAnalysisRecord) -> some View {
        Section("Ad Analysis") {
            LabeledContent("Status", value: record.state.rawValue.capitalized)
            if !record.model.isEmpty {
                LabeledContent("Model", value: record.model)
            }
            if !record.policy.isEmpty {
                LabeledContent("Policy", value: record.policy)
            }
            LabeledContent("Spans", value: record.spanCount, format: .number)
            LabeledContent("Warnings", value: record.warningCount, format: .number)
            if let errorMessage = record.errorMessage {
                LabeledContent("Error") {
                    Text(errorMessage)
                        .font(.footnote)
                        .multilineTextAlignment(.trailing)
                }
            }
        }
    }

    private func byteCount(_ bytes: Int64) -> String {
        bytes.formatted(.byteCount(style: .file))
    }
}

#Preview("Dark") {
    EpisodeInfoSheet(episodeID: "preview-episode")
        .environment(OpenCastAppModel())
        .preferredColorScheme(.dark)
}

#Preview("Light") {
    EpisodeInfoSheet(episodeID: "preview-episode")
        .environment(OpenCastAppModel())
        .preferredColorScheme(.light)
}
