import OpenCastPlayback
import SwiftData
import SwiftUI

struct EpisodeDetailView: View {
    @Environment(OpenCastAppModel.self) private var appModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    let episodeID: String

    @State private var showNotes: EpisodeShowNotesContent = .empty
    @State private var transcriptSnippet: String?
    @State private var adAnalysisTranscriptDocument: EpisodeTranscriptDocument?
    @State private var adAnalysisDocument: EpisodeAdAnalysisDocument?
    @State private var adAnalysisState: EpisodeAdAnalysisJobState = .unavailable("Transcript unavailable.")
    @State private var hasCurrentCompletedAnalysis = false
    @State private var currentAdAnalysisZoneTiers: EpisodeAdAnalysisZoneTiers = .empty
    @State private var loadedAdAnalysisContentIdentifier: String?
    @State private var isConfirmingClearProgress = false
    @State private var sheetDestination: SheetDestination?
    @State private var adDetectionModePromptEpisode: EpisodeListItemSnapshot?
    @State private var episodeActionErrorTitle = "Couldn’t Complete Action"
    @State private var episodeActionErrorMessage = ""
    @State private var isShowingEpisodeActionError = false

    private var episode: EpisodeListItemSnapshot? {
        appModel.episodeSnapshot(for: episodeID)
    }

    var body: some View {
        let episode = episode
        let progressSummary = episode.map { appModel.library.progressSummary(for: $0) }
        let progressRecord = episode.flatMap { appModel.library.progressRecord(for: $0.episodeID) }
        let adAnalysisContentIdentifier = adAnalysisContentLoadIdentifier(for: episode?.episodeID)

        Group {
            if let episode {
                content(episode: episode, progressSummary: progressSummary)
            } else {
                ContentUnavailableView {
                    Label("Episode Not Found", systemImage: "questionmark.circle")
                } actions: {
                    Button("Go Back", systemImage: "chevron.backward", action: dismiss.callAsFunction)
                }
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
                        onShowEpisodeInfo: showEpisodeInfo,
                        onActionError: { showEpisodeActionError($0) }
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
        .alert(episodeActionErrorTitle, isPresented: $isShowingEpisodeActionError) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(episodeActionErrorMessage)
        }
        .sheet(item: remoteTranscriptionStartPreviewBinding) { request in
            RemoteTranscriptionConsumptionPreviewSheet(request: request) {
                startRemoteTranscript(request)
            }
        }
        .sheet(item: $sheetDestination) { destination in
            SheetDestinationView(destination: destination, onDismiss: dismissSheet)
        }
        .task(id: TextContentTaskKey(
            episodeID: episode?.episodeID,
            transcriptCompletedAt: completedTranscriptUpdatedAt(for: episode?.episodeID),
            isNowPlayingPresented: appModel.isNowPlayingPresented
        )) {
            let episode = episode
            guard !appModel.isNowPlayingPresented else {
                return
            }

            await updateTextContent(for: episode)
        }
        .task(id: adAnalysisContentIdentifier) {
            await updateAdAnalysisContent(
                for: episode,
                identifier: adAnalysisContentIdentifier
            )
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
        let isAdAnalysisContentCurrent = loadedAdAnalysisContentIdentifier
            == adAnalysisContentLoadIdentifier(for: episode.episodeID)
        let analysis: EpisodeAdAnalysisJobState = isAdAnalysisContentCurrent
            ? adAnalysisState
            : .unavailable("Transcript unavailable.")
        let hasCurrentAnalysis = isAdAnalysisContentCurrent
            && hasCurrentCompletedAnalysis
            && adAnalysisDocument?.episodeID == episode.episodeID
        let zoneTiers = hasCurrentAnalysis ? currentAdAnalysisZoneTiers : .empty
        // Coarse pipeline state (no live byte progress) drives column
        // presence/animation; the per-tick progress reads live in the leaf
        // sections below so ticks never re-evaluate this whole column.
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

                EpisodeDetailActionBarSection(
                    episodeID: episode.episodeID,
                    downloadRecord: downloadRecord,
                    detectAdsState: EpisodeDetectAdsMenuState(
                        queueStatus: appModel.adFreePass.queueStatus(for: episode.episodeID),
                        hasCurrentCompletedAnalysis: hasCurrentAnalysis
                    ),
                    showsPauseButton: showsPauseButton(for: episode),
                    onTogglePlayback: { togglePlayback(episode) },
                    onDownload: { download(episode) },
                    onResumeDownload: { resumeDownload(episode) },
                    onCancelDownload: { cancelDownload(episode) },
                    onDeleteDownload: { deleteDownload(episode) },
                    onMakeAdFree: { makeAdFree(episode) }
                )

                // Remote flow surface (dev-flag gated): live phase while a
                // request runs, and a visible terminal state with the
                // on-device fallback when it ends — no silent endings.
                if appModel.remoteTranscriptionPurchases.isSurfaceVisible,
                   let remoteStatus = RemoteTranscriptionStatusPresentation.make(
                       phase: appModel.remoteTranscription.store.phase(for: episode.episodeID)
                   ) {
                    RemoteTranscriptionStatusCard(
                        presentation: remoteStatus,
                        onTranscribeLocally: { transcribeLocallyAfterRemote(episode) },
                        onCancel: appModel.remoteTranscription.cancel,
                        onDismiss: { dismissRemoteOutcome(episode) }
                    )
                }

                if pipelineState != nil {
                    EpisodeDetailPipelineSection(
                        episodeID: episode.episodeID,
                        downloadRecord: downloadRecord,
                        transcription: transcription,
                        analysis: analysis
                    ) { action in
                        perform(action, episode: episode)
                    }
                }

                if case .completed(_, let isStale) = analysis {
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
                        .frame(
                            maxWidth: horizontalSizeClass == .regular ? 680 : .infinity,
                            alignment: .leading
                        )
                        .frame(maxWidth: .infinity)
                }
            }
            .padding()
            .animation(.smooth, value: pipelineState)
        }
        .adDetectionModeDialog(episode: $adDetectionModePromptEpisode)
        .background(alignment: .top) {
            EpisodeArtworkGlowBackground(preview: episode.artworkPreview)
        }
        .contentMargins(.bottom, 72, for: .scrollContent)
    }

    private func togglePlayback(_ episode: EpisodeListItemSnapshot) {
        guard appModel.playback.currentEpisode?.id.rawValue == episode.episodeID else {
            play(episode)
            return
        }

        if showsPauseButton(for: episode) {
            appModel.playback.pause()
        } else {
            appModel.playback.play()
        }
    }

    private func play(_ episode: EpisodeListItemSnapshot) {
        nowPlayingProbeMark("playepisode-tap")
        runPlaybackAction {
            try appModel.playEpisode(episode, modelContext: modelContext)
        }
    }

    private func showsPauseButton(for episode: EpisodeListItemSnapshot) -> Bool {
        guard appModel.playback.currentEpisode?.id.rawValue == episode.episodeID else {
            return false
        }

        switch appModel.playback.state {
        case .loading, .buffering, .playing:
            return true
        case .idle, .paused, .failed:
            return false
        }
    }

    private func makeAdFree(_ episode: EpisodeListItemSnapshot) {
        if appModel.startAdFreePassResolvingMode(for: episode, modelContext: modelContext) {
            adDetectionModePromptEpisode = episode
        }
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
            makeAdFree(episode)
        case .retryDownload:
            download(episode)
        case .retryAnalysis:
            detectAds(episode)
        case .removeFromQueue:
            appModel.adFreePass.removePendingItem(episodeID: episode.episodeID, modelContext: modelContext)
        case .detectOnDevice:
            appModel.startAdFreePass(for: episode, modelContext: modelContext, mode: .onDevice)
        }
    }

    private func transcribe(_ episode: EpisodeListItemSnapshot) {
        guard let downloadRecord = appModel.downloads.record(for: episode.episodeID) else {
            return
        }

        appModel.transcribeDownloadedEpisode(episode, downloadRecord: downloadRecord, modelContext: modelContext)
    }

    private var remoteTranscriptionStartPreviewBinding: Binding<RemoteTranscriptionStartPreviewRequest?> {
        let store = appModel.remoteTranscription.store
        return Binding {
            RemoteTranscriptionStartPreviewRouting.presentedRequest(
                store.startPreview,
                for: episodeID
            )
        } set: { request in
            guard request == nil,
                  let presentedRequest = RemoteTranscriptionStartPreviewRouting.presentedRequest(
                    store.startPreview,
                    for: episodeID
                  )
            else {
                return
            }
            store.dismissStartPreview(ifMatching: presentedRequest)
        }
    }

    private func startRemoteTranscript(_ request: RemoteTranscriptionStartPreviewRequest) {
        switch appModel.confirmRemoteTranscriptionStart(request, modelContext: modelContext) {
        case .started:
            break
        case .unavailable(let message):
            showEpisodeActionError(message, title: "Couldn’t Start Transcription")
        }
    }

    private func showEpisodeActionError(
        _ message: String,
        title: String = "Couldn’t Detect Ads"
    ) {
        episodeActionErrorTitle = title
        episodeActionErrorMessage = message
        isShowingEpisodeActionError = true
    }

    private func transcribeLocallyAfterRemote(_ episode: EpisodeListItemSnapshot) {
        appModel.remoteTranscription.store.dismissTerminalPhase(for: episode.episodeID)
        transcribe(episode)
    }

    private func dismissRemoteOutcome(_ episode: EpisodeListItemSnapshot) {
        appModel.remoteTranscription.store.dismissTerminalPhase(for: episode.episodeID)
    }

    private func detectAds(_ episode: EpisodeListItemSnapshot) {
        guard loadedAdAnalysisContentIdentifier == adAnalysisContentLoadIdentifier(for: episode.episodeID),
              let document = adAnalysisTranscriptDocument,
              document.episodeID == episode.episodeID
        else {
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
        let transcriptDocument: EpisodeTranscriptDocument?
        if appModel.transcriptions.record(for: episode.episodeID)?.state == .completed {
            do {
                transcriptDocument = try await appModel.transcriptions.loadDocument(for: episode.episodeID)
            } catch is CancellationError {
                return
            } catch {
                transcriptDocument = nil
            }
        } else {
            transcriptDocument = nil
        }
        guard !Task.isCancelled else {
            return
        }
        transcriptSnippet = snippet(from: transcriptDocument)
    }

    private func updateAdAnalysisContent(
        for episode: EpisodeListItemSnapshot?,
        identifier: String
    ) async {
        loadedAdAnalysisContentIdentifier = nil
        adAnalysisTranscriptDocument = nil
        adAnalysisDocument = nil
        adAnalysisState = .unavailable("Transcript unavailable.")
        hasCurrentCompletedAnalysis = false
        currentAdAnalysisZoneTiers = .empty

        guard let episode,
              appModel.transcriptions.record(for: episode.episodeID)?.state == .completed
        else {
            loadedAdAnalysisContentIdentifier = identifier
            return
        }

        let transcriptDocument: EpisodeTranscriptDocument
        do {
            transcriptDocument = try await appModel.transcriptions.loadDocument(for: episode.episodeID)
        } catch is CancellationError {
            return
        } catch {
            guard !Task.isCancelled else {
                return
            }
            loadedAdAnalysisContentIdentifier = identifier
            return
        }
        guard !Task.isCancelled else {
            return
        }

        let analysisDocument: EpisodeAdAnalysisDocument?
        if appModel.adAnalyses.record(for: episode.episodeID)?.state == .completed {
            do {
                analysisDocument = try await appModel.adAnalyses.loadDocument(for: episode.episodeID)
            } catch is CancellationError {
                return
            } catch {
                analysisDocument = nil
            }
        } else {
            analysisDocument = nil
        }
        guard !Task.isCancelled else {
            return
        }

        let state = appModel.adAnalyses.episodeDetailState(
            for: transcriptDocument,
            transcriptState: appModel.transcriptions.record(for: episode.episodeID)?.state,
            analysisDocument: analysisDocument
        )
        adAnalysisTranscriptDocument = transcriptDocument
        self.adAnalysisDocument = analysisDocument
        adAnalysisState = state.jobState
        hasCurrentCompletedAnalysis = state.hasCurrentCompletedAnalysis
        if state.hasCurrentCompletedAnalysis, let analysisDocument {
            currentAdAnalysisZoneTiers = EpisodeAdAnalysisZoneMapper.zoneTiers(
                for: analysisDocument,
                duration: episode.duration
            )
        } else {
            currentAdAnalysisZoneTiers = .empty
        }
        loadedAdAnalysisContentIdentifier = identifier
    }

    private func completedTranscriptUpdatedAt(for episodeID: String?) -> Date? {
        guard let episodeID,
              let record = appModel.transcriptions.record(for: episodeID),
              record.state == .completed
        else {
            return nil
        }
        return record.updatedAt
    }

    private func adAnalysisContentLoadIdentifier(for episodeID: String?) -> String {
        guard let episodeID else {
            return "missing"
        }

        let transcriptRecord = appModel.transcriptions.record(for: episodeID)
        let transcriptStamp = transcriptRecord?.state == .completed
            ? "completed:\(transcriptRecord?.updatedAt.timeIntervalSinceReferenceDate ?? -1)"
            : "incomplete"
        let analysisStamp: String
        if let analysisRecord = appModel.adAnalyses.record(for: episodeID) {
            analysisStamp = "\(analysisRecord.state.rawValue):\(analysisRecord.updatedAt.timeIntervalSinceReferenceDate)"
        } else {
            analysisStamp = "missing"
        }
        return "\(episodeID)|\(transcriptStamp)|\(analysisStamp)|\(appModel.adAnalyses.changeSequence)"
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
    let transcriptCompletedAt: Date?
    let isNowPlayingPresented: Bool
}

/// Reads live download byte progress in its own body so per-tick progress
/// publishes (many per download) re-evaluate this bar alone, never the
/// detail column above it.
private struct EpisodeDetailActionBarSection: View {
    @Environment(OpenCastAppModel.self) private var appModel

    let episodeID: String
    let downloadRecord: EpisodeDownloadRecord?
    let detectAdsState: EpisodeDetectAdsMenuState
    let showsPauseButton: Bool
    let onTogglePlayback: () -> Void
    let onDownload: () -> Void
    let onResumeDownload: () -> Void
    let onCancelDownload: () -> Void
    let onDeleteDownload: () -> Void
    let onMakeAdFree: () -> Void

    var body: some View {
        EpisodeActionBar(
            downloadRecord: downloadRecord,
            downloadLiveProgress: appModel.downloads.byteProgress(for: episodeID),
            detectAdsState: detectAdsState,
            showsPauseButton: showsPauseButton,
            onTogglePlayback: onTogglePlayback,
            onDownload: onDownload,
            onResumeDownload: onResumeDownload,
            onCancelDownload: onCancelDownload,
            onDeleteDownload: onDeleteDownload,
            onMakeAdFree: onMakeAdFree
        )
    }
}

/// Reads live download byte progress in its own body so per-tick progress
/// publishes re-evaluate this card alone, never the detail column above it.
/// Presence is decided by the parent's coarse (progress-free) state.
private struct EpisodeDetailPipelineSection: View {
    @Environment(OpenCastAppModel.self) private var appModel

    let episodeID: String
    let downloadRecord: EpisodeDownloadRecord?
    let transcription: EpisodeTranscriptionJobState
    let analysis: EpisodeAdAnalysisJobState?
    let onAction: (EpisodePipelineAction) -> Void

    var body: some View {
        if let state = EpisodePipelineState.make(
            episodeID: episodeID,
            queueStatus: appModel.adFreePass.queueStatus(for: episodeID),
            queueSnapshot: appModel.adFreePass.queueSnapshot,
            downloadRecord: downloadRecord,
            downloadLiveProgress: appModel.downloads.byteProgress(for: episodeID),
            transcription: transcription,
            analysis: analysis
        ) {
            EpisodePipelineCard(state: state, onAction: onAction)
        }
    }
}
