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
    @State private var loadedTextContentIdentity: TextContentIdentity?
    @State private var adSection = EpisodeAdAnalysisSectionModel()
    @State private var chaptersSection = EpisodeChaptersSummarySectionModel()
    @State private var isConfirmingClearProgress = false
    @State private var isConfirmingGenerateDisclosure = false
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
        let adAnalysisContentIdentifier = adSection.loadKey(appModel: appModel, episodeID: episode?.episodeID)
        let transcriptAnalysisContentIdentifier = chaptersSection.loadKey(appModel: appModel, episodeID: episode?.episodeID)

        Group {
            if let episode {
                content(
                    episode: episode,
                    progressSummary: progressSummary,
                    adAnalysisKey: adAnalysisContentIdentifier,
                    chaptersKey: transcriptAnalysisContentIdentifier
                )
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
                        onShowEpisodeDiagnostics: showEpisodeDiagnostics,
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
            identity: TextContentIdentity(
                episodeID: episode?.episodeID,
                transcriptCompletedAt: completedTranscriptUpdatedAt(for: episode?.episodeID)
            ),
            isNowPlayingPresented: appModel.isNowPlayingPresented
        )) {
            let episode = episode
            guard !appModel.isNowPlayingPresented else {
                return
            }

            await updateTextContent(for: episode)
        }
        .task(id: adAnalysisContentIdentifier) {
            await adSection.load(appModel: appModel, episode: episode, key: adAnalysisContentIdentifier)
        }
        .task(id: transcriptAnalysisContentIdentifier) {
            await chaptersSection.load(appModel: appModel, episode: episode, key: transcriptAnalysisContentIdentifier)
        }
    }

    private func content(
        episode: EpisodeListItemSnapshot,
        progressSummary: EpisodeProgressSummary?,
        adAnalysisKey: String,
        chaptersKey: String
    ) -> some View {
        let downloadRecord = appModel.downloads.record(for: episode.episodeID)
        let transcription = appModel.transcriptions.jobState(
            for: episode.episodeID,
            downloadRecord: downloadRecord,
            modelState: appModel.transcriptionModels.state,
            requiresInstalledWhisperModel: !appModel.appleSpeechAssets.isTranscriberAvailable
        )
        let analysis = adSection.jobState(forKey: adAnalysisKey)
        let hasCurrentAnalysis = adSection.hasCurrentAnalysis(forKey: adAnalysisKey, episodeID: episode.episodeID)
        let zoneTiers = adSection.zoneTiers(forKey: adAnalysisKey, episodeID: episode.episodeID)
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

                // Creator metadata wins (D3) at render time too: an analysis
                // generated while chapters_url was still unpopulated (the
                // pre-upgrade cache window) stops rendering as soon as a feed
                // refresh reveals the creator declaration.
                let showsGeneratedCards = chaptersSection.hasCurrentAnalysis(forKey: chaptersKey, episodeID: episode.episodeID)
                    && chaptersSection.creatorChaptersURL == nil
                if showsGeneratedCards, let analysisDocument = chaptersSection.analysisDocument {
                    if !analysisDocument.chapters.isEmpty {
                        EpisodeChaptersCard(chapters: analysisDocument.chapters) { chapter in
                            seekToChapter(chapter, episode: episode)
                        }
                    }
                    if let summary = analysisDocument.summary {
                        EpisodeGeneratedSummaryCard(summary: summary)
                    }
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

                // Generation stays below the show notes, out of the way — the
                // app is a podcast listener first. The !showsGeneratedCards
                // gate keeps the old if/else mutual exclusivity: the controls
                // presentation maps a completed analysis to .ready, which
                // must not re-offer Generate under the rendered cards.
                if !showsGeneratedCards,
                   let controlsPresentation = chaptersSummaryControlsPresentation(for: episode, key: chaptersKey) {
                    EpisodeChaptersSummaryControlsCard(presentation: controlsPresentation) {
                        generateChaptersAndSummary(episode)
                    }
                    .confirmationDialog(
                        TranscriptAnalysisGenerateDisclosureCopy.title,
                        isPresented: $isConfirmingGenerateDisclosure,
                        titleVisibility: .visible
                    ) {
                        Button(
                            TranscriptAnalysisGenerateDisclosureCopy.confirmButtonTitle,
                            action: acknowledgeGenerateDisclosure
                        )
                        Button("Cancel", role: .cancel) {}
                    } message: {
                        Text(TranscriptAnalysisGenerateDisclosureCopy.confirmationBody())
                    }
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
        guard let document = adSection.transcriptDocument(
            forKey: adSection.loadKey(appModel: appModel, episodeID: episode.episodeID),
            episodeID: episode.episodeID
        ) else {
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

    private func showEpisodeDiagnostics() {
        sheetDestination = .episodeDiagnostics(episodeID: episodeID)
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
        // The task key deliberately includes isNowPlayingPresented (defer
        // while covered, refresh on dismissal); the identity memo makes that
        // refresh a cache hit when the content is unchanged.
        let identity = TextContentIdentity(
            episodeID: episode?.episodeID,
            transcriptCompletedAt: completedTranscriptUpdatedAt(for: episode?.episodeID)
        )
        guard identity != loadedTextContentIdentity else {
            return
        }

        guard let episode else {
            showNotes = .empty
            transcriptSnippet = nil
            loadedTextContentIdentity = identity
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
        loadedTextContentIdentity = identity
    }

    /// Fail-open surface: failures render the ready state again (a manual tap
    /// re-probes, which is also the cap-deferral retry path) — never an
    /// error. The pay gate's insufficient-balance denial is the deliberate
    /// exception: it renders the needs-minutes state with a buy path (H8).
    /// Offered for any episode with a completed transcript — generation is a
    /// per-episode manual action, with no show-wide setting gating it.
    private func chaptersSummaryControlsPresentation(
        for episode: EpisodeListItemSnapshot,
        key: String
    ) -> EpisodeChaptersSummaryControlsCard.Presentation? {
        guard chaptersSection.isLoaded(forKey: key, episodeID: episode.episodeID) else {
            return nil
        }
        if chaptersSection.creatorChaptersURL != nil {
            return .creatorChaptersAvailable
        }
        switch chaptersSection.jobState {
        case .running:
            return .running
        case .failed(let record, _) where record.failureKind == .insufficientSeconds:
            return .needsMinutes(chargeDescription: transcriptAnalysisNeedsMinutesDescription())
        case .ready, .completed, .failed:
            return .ready(costDescription: transcriptAnalysisCostDescription())
        case .unavailable:
            return nil
        }
    }

    /// Display-only estimate: the server recomputes the charge from its own
    /// authoritative duration at reserve, so this can mis-display but never
    /// mis-charge. Mirrors the server's duration basis (declared duration or
    /// the last segment end, whichever is larger).
    private var transcriptAnalysisChargeSeconds: Int64? {
        guard let document = chaptersSection.transcriptDocument else {
            return nil
        }
        let duration = max(document.audioDuration, document.segments.last?.end ?? 0)
        return appModel.remoteTranscriptionPurchases
            .analysisEstimate(durationSeconds: duration)?
            .estimatedSeconds
    }

    private func transcriptAnalysisCostDescription() -> String? {
        guard TranscriptAnalysisFeatureFlags.chargesTranscriptionMinutes,
              let chargeSeconds = transcriptAnalysisChargeSeconds
        else {
            return nil
        }
        return String(
            localized: "Uses ~\(RemoteTranscriptionBalanceFormatting.hours(chargeSeconds)) of transcription time."
        )
    }

    private func transcriptAnalysisNeedsMinutesDescription() -> String {
        guard let chargeSeconds = transcriptAnalysisChargeSeconds else {
            return String(localized: "Not enough transcription time for this episode.")
        }
        return String(
            localized: "Not enough transcription time — generating needs ~\(RemoteTranscriptionBalanceFormatting.hours(chargeSeconds))."
        )
    }

    private func generateChaptersAndSummary(_ episode: EpisodeListItemSnapshot) {
        guard appModel.transcriptAnalyses.hasAcknowledgedGenerateDisclosure else {
            isConfirmingGenerateDisclosure = true
            return
        }
        appModel.generateChaptersAndSummary(episodeID: episode.episodeID, modelContext: modelContext)
    }

    private func acknowledgeGenerateDisclosure() {
        appModel.transcriptAnalyses.acknowledgeGenerateDisclosure(modelContext: modelContext)
        guard let episode else {
            return
        }
        appModel.generateChaptersAndSummary(episodeID: episode.episodeID, modelContext: modelContext)
    }

    private func seekToChapter(
        _ chapter: EpisodeTranscriptAnalysisChapter,
        episode: EpisodeListItemSnapshot
    ) {
        guard let transcriptDocument = chaptersSection.transcriptDocument(for: episode.episodeID) else {
            return
        }

        // Chapter times are exact only against the transcribed audio asset;
        // a dynamic enclosure can be a different assembly offset by tens of
        // seconds. Same verdict ladder as the transcript view's playFrom.
        if appModel.playback.currentEpisode?.id.rawValue == episode.episodeID {
            let downloadRecord = appModel.downloads.record(for: episode.episodeID)
            let alignment = TranscriptSourceAlignment.resolve(
                documentSHA256: transcriptDocument.sourceFileSHA256,
                trustedDownloadSHA256: appModel.downloads.completedSourceIdentity(for: episode.episodeID)?.sha256,
                downloadFileURL: downloadRecord.flatMap(appModel.downloads.localFileURL(for:)),
                playerItemURL: appModel.playback.currentItemSourceIdentity?.assetURL
            )
            switch alignment {
            case .verified, .mismatched(canSwitchToTranscribedCopy: false):
                // Verified: exact seek. No matched copy anywhere: explicit
                // best-effort jump — a restart could not land closer.
                appModel.playback.seek(to: chapter.startTime, intent: .scrub)
                if appModel.playback.state != .playing {
                    appModel.playback.play()
                }
                return
            case .mismatched(canSwitchToTranscribedCopy: true):
                // Seeking the unproven item cannot honor the chapter time;
                // restarting from the matched download at that time can.
                break
            }
        }

        runPlaybackAction {
            try appModel.playEpisode(
                episode,
                at: chapter.startTime,
                matchingSourceSHA256: transcriptDocument.sourceFileSHA256,
                presentsNowPlaying: false,
                modelContext: modelContext
            )
        }
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

    private func snippet(from document: EpisodeTranscriptDocument?) -> String? {
        // 2 000 source chars amply cover a 220-char snippet after whitespace
        // collapsing; keeps the regex off 100-400 KB transcripts.
        guard let document else {
            return nil
        }
        let text = String(document.text.prefix(2_000))
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            return nil
        }

        return String(text.prefix(220))
    }
}

private struct TextContentTaskKey: Equatable {
    let identity: TextContentIdentity
    let isNowPlayingPresented: Bool
}

private struct TextContentIdentity: Equatable {
    let episodeID: String?
    let transcriptCompletedAt: Date?
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
