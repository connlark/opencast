import OpenCastPlayback
import SwiftData
import SwiftUI

struct EpisodeDetailView: View {
    @Environment(OpenCastAppModel.self) private var appModel
    @Environment(\.modelContext) private var modelContext

    let episodeID: String

    @State private var showNotes: EpisodeShowNotesContent = .empty
    @State private var transcriptSnippet: String?
    @State private var isConfirmingClearProgress = false
    @State private var sheetDestination: SheetDestination?

    private var episode: EpisodeListItemSnapshot? {
        if let episode = appModel.library.episode(with: episodeID) {
            return episode
        }

        guard let record = appModel.downloads.record(for: episodeID) else {
            return nil
        }
        return DownloadListItem.make(record: record, library: appModel.library).episode
    }

    var body: some View {
        let episode = episode
        let progressSummary = episode.map { appModel.library.progressSummary(for: $0) }
        let progressRecord = episode.flatMap { appModel.library.progressRecord(for: $0.episodeID) }

        Group {
            if let episode {
                content(episode: episode, progressSummary: progressSummary)
            } else {
                ContentUnavailableView("Episode Not Found", systemImage: "questionmark.circle")
            }
        }
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if let episode, let progressSummary {
                ToolbarItem(placement: .primaryAction) {
                    EpisodeMoreMenu(
                        episode: episode,
                        isPlayed: progressSummary.isCompleted,
                        hasProgressRecord: progressRecord != nil,
                        onClearProgress: confirmClearProgress,
                        onShowEpisodeInfo: showEpisodeInfo
                    )
                }
            }
        }
        .confirmationDialog(
            "Clear progress for \(episode?.title ?? "this episode")?",
            isPresented: $isConfirmingClearProgress,
            titleVisibility: .visible
        ) {
            Button("Clear Progress", role: .destructive, action: clearProgress)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Listening position for this episode will be removed. Downloads are unchanged.")
        }
        .sheet(item: $sheetDestination) { destination in
            SheetDestinationView(destination: destination, onDismiss: dismissSheet)
        }
        .task(id: TextContentTaskKey(
            episodeID: episode?.episodeID,
            transcriptUpdatedAt: episode.flatMap { appModel.transcriptions.record(for: $0.episodeID)?.updatedAt },
            isNowPlayingPresented: appModel.isNowPlayingPresented
        )) {
            let episode = episode
            guard !appModel.isNowPlayingPresented else {
                return
            }

            await updateTextContent(for: episode)
        }
    }

    private func content(
        episode: EpisodeListItemSnapshot,
        progressSummary: EpisodeProgressSummary?
    ) -> some View {
        let downloadRecord = appModel.downloads.record(for: episode.episodeID)
        let transcription = appModel.transcriptions.jobState(
            for: episode.episodeID,
            downloadRecord: downloadRecord,
            modelState: appModel.transcriptionModels.state,
            requiresInstalledWhisperModel: !appModel.appleSpeechAssets.isTranscriberAvailable
        )
        let analysis = appModel.adAnalyses.jobState(
            for: appModel.transcriptions.document(for: episode.episodeID),
            transcriptState: appModel.transcriptions.record(for: episode.episodeID)?.state
        )
        let pipelineState = EpisodePipelineState.make(
            episodeID: episode.episodeID,
            queueStatus: appModel.adFreePass.queueStatus(for: episode.episodeID),
            queueSnapshot: appModel.adFreePass.queueSnapshot,
            downloadRecord: downloadRecord,
            transcription: transcription,
            analysis: analysis
        )
        let chips = EpisodeMetadataChips.make(
            publishedAt: episode.publishedAt,
            duration: episode.duration,
            progress: progressSummary,
            isDownloaded: downloadRecord?.state == .completed,
            downloadedByteCount: downloadRecord?.bytesReceived
        )

        return ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                EpisodeHeroHeaderView(
                    episode: episode,
                    chips: chips,
                    onPreviewResolved: updateArtworkPreview
                )
                .animation(.easeOut(duration: 0.2), value: progressSummary)

                EpisodeActionBar(
                    downloadRecord: downloadRecord,
                    detectAdsState: appModel.detectAdsMenuState(for: episode),
                    onPlay: { play(episode) },
                    onDownload: { download(episode) },
                    onResumeDownload: { resumeDownload(episode) },
                    onCancelDownload: { cancelDownload(episode) },
                    onDeleteDownload: { deleteDownload(episode) },
                    onMakeAdFree: { makeAdFree(episode) }
                )

                if let pipelineState {
                    EpisodePipelineCard(state: pipelineState) { action in
                        perform(action, episode: episode)
                    }
                }

                if case .completed(_, let isStale) = analysis {
                    let zoneTiers = appModel.adAnalysisZoneTiers(for: episode, duration: episode.duration)
                    EpisodeAdSpanTimelineView(
                        duration: timelineDuration(episode: episode, zoneTiers: zoneTiers),
                        zoneTiers: zoneTiers,
                        isStale: isStale
                    )
                }

                if case .completed(let record) = transcription, record.transcriptRelativePath != nil {
                    EpisodeTranscriptEntryCard(episodeID: episode.episodeID, snippet: transcriptSnippet)
                }

                if !showNotes.isEmpty {
                    EpisodeShowNotesView(blocks: showNotes.blocks)
                }
            }
            .padding()
            .animation(.smooth, value: pipelineState)
        }
        .background(alignment: .top) {
            EpisodeArtworkGlowBackground(preview: episode.artworkPreview)
        }
        .contentMargins(.bottom, 72, for: .scrollContent)
    }

    private func play(_ episode: EpisodeListItemSnapshot) {
        nowPlayingProbeMark("playepisode-tap")
        runPlaybackAction {
            try appModel.playEpisode(episode, modelContext: modelContext)
        }
    }

    private func makeAdFree(_ episode: EpisodeListItemSnapshot) {
        appModel.startAdFreePass(for: episode, modelContext: modelContext)
    }

    private func perform(_ action: EpisodePipelineAction, episode: EpisodeListItemSnapshot) {
        switch action {
        case .cancelPass:
            appModel.cancelAdFreePass(for: episode, modelContext: modelContext)
        case .cancelDownload:
            cancelDownload(episode)
        case .cancelTranscription:
            appModel.cancelEpisodeTranscription(episodeID: episode.episodeID, modelContext: modelContext)
        case .downloadModel, .resumeQueue, .retryQueue:
            appModel.adFreePass.resumePausedQueue()
        case .resumeDownload:
            resumeDownload(episode)
        case .resumeTranscription, .retryTranscription:
            transcribe(episode)
        case .retryPass:
            appModel.startAdFreePass(for: episode, modelContext: modelContext)
        case .retryDownload:
            download(episode)
        case .retryAnalysis:
            detectAds(episode)
        case .removeFromQueue:
            appModel.adFreePass.removePendingItem(episodeID: episode.episodeID, modelContext: modelContext)
        }
    }

    private func transcribe(_ episode: EpisodeListItemSnapshot) {
        guard let downloadRecord = appModel.downloads.record(for: episode.episodeID) else {
            return
        }

        appModel.transcribeDownloadedEpisode(episode, downloadRecord: downloadRecord, modelContext: modelContext)
    }

    private func detectAds(_ episode: EpisodeListItemSnapshot) {
        guard let document = appModel.transcriptions.document(for: episode.episodeID) else {
            return
        }

        appModel.analyzeEpisodeTranscript(document, modelContext: modelContext)
    }

    private func updateArtworkPreview(_ preview: ArtworkPreview) {
        guard let episode else {
            return
        }

        appModel.library.updateArtworkPreview(preview, for: episode)
    }

    private func confirmClearProgress() {
        isConfirmingClearProgress = true
    }

    private func clearProgress() {
        guard let episode else {
            return
        }

        appModel.clearEpisodeProgress(episode, modelContext: modelContext)
    }

    private func showEpisodeInfo() {
        sheetDestination = .episodeInfo(episodeID: episodeID)
    }

    private func dismissSheet() {
        sheetDestination = nil
    }

    private func runPlaybackAction(_ action: () throws -> Void) {
        do {
            try action()
        } catch {
            appModel.lastPlaybackError = error.localizedDescription
        }
    }

    private func download(_ episode: EpisodeListItemSnapshot) {
        appModel.downloads.startDownload(for: episode, modelContext: modelContext)
    }

    private func cancelDownload(_ episode: EpisodeListItemSnapshot) {
        appModel.downloads.cancelDownload(episodeID: episode.episodeID, modelContext: modelContext)
    }

    private func resumeDownload(_ episode: EpisodeListItemSnapshot) {
        appModel.downloads.resumeDownload(episodeID: episode.episodeID, modelContext: modelContext)
    }

    private func deleteDownload(_ episode: EpisodeListItemSnapshot) {
        guard let downloadRecord = appModel.downloads.record(for: episode.episodeID) else {
            return
        }

        appModel.deleteDownload(downloadRecord, modelContext: modelContext)
    }

    private func timelineDuration(
        episode: EpisodeListItemSnapshot,
        zoneTiers: EpisodeAdAnalysisZoneTiers
    ) -> TimeInterval {
        if let duration = episode.duration, duration > 0 {
            return duration
        }

        return (zoneTiers.autoSkip + zoneTiers.displayOnly).map(\.endTime).max() ?? 0
    }

    private func updateTextContent(for episode: EpisodeListItemSnapshot?) async {
        guard let episode else {
            showNotes = .empty
            transcriptSnippet = nil
            return
        }

        // Show notes live only in the local cache store; fetch them lazily so
        // list loads never carry them.
        let detail = await appModel.library.episodeDetail(for: episode.episodeID)
        guard !Task.isCancelled else {
            return
        }

        let resolved = await EpisodeShowNotesContent.resolving(
            summaryHTML: episode.summary,
            showNotesHTML: detail?.showNotesHTML
        )
        guard !Task.isCancelled else {
            return
        }

        showNotes = resolved
        transcriptSnippet = snippet(from: appModel.transcriptions.document(for: episode.episodeID))
    }

    private func snippet(from document: EpisodeTranscriptDocument?) -> String? {
        guard let text = document?.text
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !text.isEmpty
        else {
            return nil
        }

        return String(text.prefix(220))
    }
}

private struct TextContentTaskKey: Equatable {
    let episodeID: String?
    let transcriptUpdatedAt: Date?
    let isNowPlayingPresented: Bool
}
