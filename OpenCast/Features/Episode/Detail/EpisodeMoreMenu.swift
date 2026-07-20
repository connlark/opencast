import SwiftData
import SwiftUI

/// The episode detail toolbar's "Episode Actions" menu: progress actions plus
/// the solo download/transcript/ad-analysis steps the one-tap pipeline
/// otherwise automates.
struct EpisodeMoreMenu: View {
    @Environment(OpenCastAppModel.self) private var appModel
    @Environment(\.modelContext) private var modelContext

    let episode: EpisodeListItemSnapshot
    let isPlayed: Bool
    let hasProgressRecord: Bool
    let onClearProgress: () -> Void
    let onShowEpisodeInfo: () -> Void

    var body: some View {
        Menu {
            progressActions
            Divider()
            downloadActions
            transcriptActions
            adAnalysisActions
            Divider()
            Button("Episode Info", systemImage: "info.circle", action: onShowEpisodeInfo)
        } label: {
            Label("Episode Actions", systemImage: "ellipsis.circle")
        }
    }

    @ViewBuilder
    private var progressActions: some View {
        if !isPlayed {
            Button("Mark Played", systemImage: "checkmark.circle", action: markPlayed)
        }
        if hasProgressRecord {
            Button("Clear Progress", systemImage: "arrow.counterclockwise", role: .destructive, action: onClearProgress)
        }
    }

    @ViewBuilder
    private var downloadActions: some View {
        switch appModel.downloadMenuState(for: episode) {
        case .available:
            Button("Download", systemImage: "arrow.down.circle", action: download)
        case .downloading:
            Button("Cancel Download", systemImage: "xmark.circle", action: cancelDownload)
        case .downloaded:
            Button("Delete Download", systemImage: "trash", role: .destructive, action: deleteDownload)
        }
    }

    @ViewBuilder
    private var transcriptActions: some View {
        let downloadRecord = appModel.downloads.record(for: episode.episodeID)
        switch appModel.transcriptions.jobState(
            for: episode.episodeID,
            downloadRecord: downloadRecord,
            modelState: appModel.transcriptionModels.state,
            requiresInstalledWhisperModel: !appModel.appleSpeechAssets.isTranscriberAvailable
        ) {
        case .unavailable, .downloadRequired, .modelBusy:
            EmptyView()
        case .modelRequired:
            Button("Install Speech Model", systemImage: "waveform", action: installSpeechModel)
        case .ready:
            Button("Generate Transcript", systemImage: "text.quote", action: generateTranscript)
        case .running:
            Button("Cancel Transcript", systemImage: "xmark.circle", action: cancelTranscript)
        case .completed:
            if downloadRecord?.state == .completed {
                Button("Regenerate Transcript", systemImage: "arrow.clockwise", action: generateTranscript)
            }
            Button("Delete Transcript", systemImage: "trash", role: .destructive, action: deleteTranscript)
        case .failed, .cancelled:
            Button("Retry Transcript", systemImage: "arrow.clockwise", action: generateTranscript)
            Button("Delete Partial Transcript", systemImage: "trash", role: .destructive, action: deleteTranscript)
        case .interrupted(let record):
            if record.isAppleSpeechTranscript {
                Button("Retry Transcript", systemImage: "arrow.clockwise", action: generateTranscript)
            } else {
                Button("Resume Transcript", systemImage: "play.circle", action: generateTranscript)
            }
            Button("Delete Partial Transcript", systemImage: "trash", role: .destructive, action: deleteTranscript)
        }

        remoteTranscriptActions
    }

    /// Remote eligibility is independent of download and local-model state.
    /// The purchase store still gates this to a resolved backend lane.
    @ViewBuilder
    private var remoteTranscriptActions: some View {
        if appModel.remoteTranscriptionPurchases.isSurfaceVisible {
            if let phase = appModel.remoteTranscription.store.phase(for: episode.episodeID),
               !phase.isTerminal {
                Button("Remote: \(phase.displayText)", systemImage: "cloud", action: {})
                    .disabled(true)
                Button("Cancel Remote Transcript", systemImage: "xmark.circle", action: cancelRemoteTranscript)
            } else {
                Button("Transcribe Remotely", systemImage: "cloud", action: requestRemoteTranscript)
            }
        }
    }

    @ViewBuilder
    private var adAnalysisActions: some View {
        if appModel.transcriptions.record(for: episode.episodeID)?.state == .completed {
            Button("Detect Ads Only", systemImage: "megaphone", action: detectAdsOnly)
                .disabled(!appModel.detectAdsMenuState(for: episode).isEnabled)
        }
        if appModel.adAnalyses.record(for: episode.episodeID) != nil {
            Button("Delete Ad Analysis", systemImage: "trash", role: .destructive, action: deleteAdAnalysis)
        }
    }

    private func markPlayed() {
        appModel.markEpisodePlayed(episode, modelContext: modelContext)
    }

    private func download() {
        appModel.downloads.startDownload(for: episode, modelContext: modelContext)
    }

    private func cancelDownload() {
        appModel.downloads.cancelDownload(episodeID: episode.episodeID, modelContext: modelContext)
    }

    private func deleteDownload() {
        guard let record = appModel.downloads.record(for: episode.episodeID) else {
            return
        }
        appModel.deleteDownload(record, modelContext: modelContext)
    }

    private func installSpeechModel() {
        appModel.installTranscriptionModel()
    }

    private func generateTranscript() {
        guard let downloadRecord = appModel.downloads.record(for: episode.episodeID) else {
            return
        }
        appModel.transcribeDownloadedEpisode(episode, downloadRecord: downloadRecord, modelContext: modelContext)
    }

    private func cancelTranscript() {
        appModel.cancelEpisodeTranscription(episodeID: episode.episodeID, modelContext: modelContext)
    }

    private func requestRemoteTranscript() {
        // The consumption preview sheet (episode detail) owns the actual start.
        appModel.remoteTranscription.store.startPreview = RemoteTranscriptionStartPreviewRequest(
            episodeID: episode.episodeID,
            durationSeconds: episode.duration
        )
    }

    private func cancelRemoteTranscript() {
        appModel.remoteTranscription.cancel()
    }

    private func deleteTranscript() {
        appModel.deleteEpisodeTranscript(episodeID: episode.episodeID, modelContext: modelContext)
    }

    private func detectAdsOnly() {
        guard let document = appModel.transcriptions.document(for: episode.episodeID) else {
            return
        }
        appModel.analyzeEpisodeTranscript(document, modelContext: modelContext)
    }

    private func deleteAdAnalysis() {
        appModel.deleteEpisodeAdAnalysis(episodeID: episode.episodeID, modelContext: modelContext)
    }
}

#Preview("Dark") {
    NavigationStack {
        Text("Episode")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    EpisodeMoreMenu(
                        episode: .previewSample,
                        isPlayed: false,
                        hasProgressRecord: true,
                        onClearProgress: {},
                        onShowEpisodeInfo: {}
                    )
                }
            }
    }
    .environment(OpenCastAppModel())
    .preferredColorScheme(.dark)
}

#Preview("Light") {
    NavigationStack {
        Text("Episode")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    EpisodeMoreMenu(
                        episode: .previewSample,
                        isPlayed: true,
                        hasProgressRecord: false,
                        onClearProgress: {},
                        onShowEpisodeInfo: {}
                    )
                }
            }
    }
    .environment(OpenCastAppModel())
    .preferredColorScheme(.light)
}
