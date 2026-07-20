import Foundation
import OpenCastTranscription
import Testing
@testable import OpenCast

@MainActor
@Suite("Episode pipeline card state")
struct EpisodePipelineStateTests {
    private let episodeID = "pipeline-episode"

    // MARK: - Active pass stages

    @Test("Active downloading stage shows a byte-fraction download row")
    func activeDownloadingStage() {
        let state = makeState(
            queueStatus: .running,
            queueSnapshot: activeSnapshot(stage: .downloadingEpisode),
            downloadRecord: downloadRecord(state: .downloading, bytesReceived: 50, bytesExpected: 100)
        )

        #expect(state == EpisodePipelineState(
            title: EpisodePipelineState.passTitle,
            steps: [
                EpisodePipelineStep(kind: .download, status: .running(fraction: 0.5, detail: nil)),
                EpisodePipelineStep(kind: .transcribe, status: .waiting),
                EpisodePipelineStep(kind: .detectAds, status: .waiting)
            ],
            footnote: nil,
            action: .cancelPass
        ))
    }

    @Test("Active download without a byte total is indeterminate")
    func activeDownloadingIndeterminate() {
        let state = makeState(
            queueStatus: .running,
            queueSnapshot: activeSnapshot(stage: .downloadingEpisode),
            downloadRecord: downloadRecord(state: .downloading, bytesReceived: 50, bytesExpected: nil)
        )

        #expect(state?.steps.first?.status == .running(fraction: nil, detail: nil))
    }

    @Test("Model install stage reports speech-model preparation on the transcribe row")
    func activeInstallingModelStage() {
        let progress = OpenCastWhisperModelInstallProgress(
            modelIdentifier: "model",
            version: "1",
            completedFileCount: 1,
            totalFileCount: 2,
            completedByteCount: 39_450_000,
            totalByteCount: 78_900_000,
            currentFilePath: nil
        )

        let state = makeState(queueStatus: .running, queueSnapshot: activeSnapshot(stage: .installingModel(progress)))

        #expect(state?.steps == [
            EpisodePipelineStep(kind: .download, status: .done),
            EpisodePipelineStep(kind: .transcribe, status: .running(fraction: 0.5, detail: "Preparing speech model… 50%")),
            EpisodePipelineStep(kind: .detectAds, status: .waiting)
        ])
        #expect(state?.action == .cancelPass)
    }

    @Test("Speech asset install stage reports preparation progress")
    func activeInstallingSpeechAssetsStage() {
        let state = makeState(
            queueStatus: .running,
            queueSnapshot: activeSnapshot(stage: .installingSpeechAssets(fractionCompleted: 0.25))
        )

        #expect(state?.steps[1].status == .running(fraction: 0.25, detail: "Preparing speech model… 25%"))
    }

    @Test("Transcribing stage carries a fraction and elapsed-of-total detail")
    func activeTranscribingStage() {
        let progress = EpisodeTranscriptionProgress(
            audioDuration: 3_480,
            completedDuration: 2_040,
            checkpointCount: 3,
            currentWindowIndex: nil,
            currentText: nil
        )

        let state = makeState(queueStatus: .running, queueSnapshot: activeSnapshot(stage: .transcribing(progress)))

        #expect(state?.steps == [
            EpisodePipelineStep(kind: .download, status: .done),
            EpisodePipelineStep(
                kind: .transcribe,
                status: .running(fraction: progress.fractionCompleted, detail: "34:00 of 58:00")
            ),
            EpisodePipelineStep(kind: .detectAds, status: .waiting)
        ])
    }

    @Test("Analyzing stage marks earlier steps done")
    func activeAnalyzingStage() {
        let state = makeState(queueStatus: .running, queueSnapshot: activeSnapshot(stage: .analyzing))

        #expect(state?.steps == [
            EpisodePipelineStep(kind: .download, status: .done),
            EpisodePipelineStep(kind: .transcribe, status: .done),
            EpisodePipelineStep(kind: .detectAds, status: .running(fraction: nil, detail: nil))
        ])
        #expect(state?.action == .cancelPass)
    }

    @Test("Completed stage hides the card")
    func activeCompletedStageHidesCard() {
        let state = makeState(queueStatus: .running, queueSnapshot: activeSnapshot(stage: .completed(zoneCount: 3)))
        #expect(state == nil)
    }

    // MARK: - Completed analysis hides the card

    @Test("A current completed analysis hides the card entirely")
    func completedCurrentAnalysisHidesCard() {
        let state = makeState(analysis: .completed(analysisRecord(state: .completed), isStale: false))
        #expect(state == nil)
    }

    @Test("A stale completed analysis also hides the card")
    func staleCompletedAnalysisHidesCard() {
        let state = makeState(analysis: .completed(analysisRecord(state: .completed), isStale: true))
        #expect(state == nil)
    }

    // MARK: - Paused queue states

    @Test("Model consent for the queue head offers the model download")
    func awaitingModelConsentHead() {
        let state = makeState(
            queueStatus: .queued(ahead: 0),
            queueSnapshot: pendingSnapshot(
                state: .awaitingModelConsent,
                pendingIDs: [episodeID],
                pendingModelConsentByteCount: 78_900_000
            ),
            downloadRecord: downloadRecord(state: .completed)
        )

        #expect(state?.title == EpisodePipelineState.passTitle)
        #expect(state?.steps.first?.status == .done)
        #expect(state?.footnote == EpisodePipelineState.modelConsentFootnote)
        #expect(state?.action == .downloadModel(byteCount: 78_900_000))
        #expect(state?.action?.title.contains("Download Model") == true)
    }

    @Test("Model consent for a non-head episode shows the queued card instead")
    func awaitingModelConsentNotHead() {
        let state = makeState(
            queueStatus: .queued(ahead: 1),
            queueSnapshot: pendingSnapshot(
                state: .awaitingModelConsent,
                pendingIDs: ["other-episode", episodeID],
                pendingModelConsentByteCount: 78_900_000
            )
        )

        #expect(state?.footnote == "Queued — 1 ahead")
        #expect(state?.action == .removeFromQueue)
    }

    @Test("An interrupted queue head offers Resume")
    func pausedInterruptedHead() {
        let state = makeState(
            queueStatus: .queued(ahead: 0),
            queueSnapshot: pendingSnapshot(state: .pausedInterrupted, pendingIDs: [episodeID]),
            downloadRecord: downloadRecord(state: .completed)
        )

        #expect(state?.footnote == EpisodePipelineState.pausedFootnote)
        #expect(state?.action == .resumeQueue)
    }

    @Test("Cap deferral shows the settled copy with Retry")
    func capDeferred() {
        let state = makeState(
            queueStatus: .capDeferred,
            queueSnapshot: pendingSnapshot(state: .capDeferred, pendingIDs: [episodeID])
        )

        #expect(state?.footnote == EpisodeAdFreePassPresentation.capDeferred.statusText)
        #expect(state?.action == .retryQueue)
    }

    @Test("A queued episode reports its position and offers removal")
    func queuedBehindTwo() {
        let state = makeState(
            queueStatus: .queued(ahead: 2),
            queueSnapshot: pendingSnapshot(state: .running, pendingIDs: ["a", "b", episodeID]),
            downloadRecord: downloadRecord(state: .completed)
        )

        #expect(state?.title == EpisodePipelineState.passTitle)
        #expect(state?.steps.first?.status == .done)
        #expect(state?.footnote == "Queued — 2 ahead")
        #expect(state?.action == .removeFromQueue)
    }

    // MARK: - Session failures

    @Test("A session failure pins its message on the first incomplete step")
    func sessionFailureMarksFirstIncompleteStep() {
        let state = makeState(
            queueStatus: .failed(message: "Transcript failed."),
            downloadRecord: downloadRecord(state: .completed),
            transcription: .ready
        )

        #expect(state == EpisodePipelineState(
            title: EpisodePipelineState.passFailedTitle,
            steps: [
                EpisodePipelineStep(kind: .download, status: .done),
                EpisodePipelineStep(kind: .transcribe, status: .failed(message: "Transcript failed.")),
                EpisodePipelineStep(kind: .detectAds, status: .waiting)
            ],
            footnote: nil,
            action: .retryPass
        ))
    }

    @Test("A session failure defers to a persisted store failure")
    func sessionFailurePrefersPersistedFailure() {
        let state = makeState(
            queueStatus: .failed(message: "Something else."),
            downloadRecord: downloadRecord(state: .failed)
        )

        #expect(state?.steps.first?.status == .failed(message: EpisodePipelineState.downloadFailedMessage))
        #expect(state?.steps[1].status == .waiting)
        #expect(state?.action == .retryPass)
    }

    // MARK: - Solo download

    @Test("A solo download in flight shows a cancelable progress row")
    func soloDownloadRunning() {
        let state = makeState(downloadRecord: downloadRecord(state: .downloading, bytesReceived: 25, bytesExpected: 100))

        #expect(state == EpisodePipelineState(
            title: EpisodePipelineState.downloadingTitle,
            steps: [EpisodePipelineStep(kind: .download, status: .running(fraction: 0.25, detail: nil))],
            footnote: nil,
            action: .cancelDownload
        ))
    }

    @Test("A failed download survives relaunch as a Retry card")
    func failedDownloadAfterRelaunch() {
        let state = makeState(downloadRecord: downloadRecord(state: .failed))

        #expect(state == EpisodePipelineState(
            title: EpisodePipelineState.downloadFailedTitle,
            steps: [EpisodePipelineStep(kind: .download, status: .failed(message: EpisodePipelineState.downloadFailedMessage))],
            footnote: nil,
            action: .retryDownload
        ))
    }

    @Test("A missing downloaded file reads differently from a failed download")
    func missingDownload() {
        let state = makeState(downloadRecord: downloadRecord(state: .missing))

        #expect(state?.steps.first?.status == .failed(message: EpisodePipelineState.downloadMissingMessage))
        #expect(state?.action == .retryDownload)
    }

    @Test("A paused download offers Resume")
    func pausedDownload() {
        let state = makeState(downloadRecord: downloadRecord(state: .paused))

        #expect(state?.title == EpisodePipelineState.downloadPausedTitle)
        #expect(state?.action == .resumeDownload)
    }

    // MARK: - Solo transcription

    @Test("A solo transcription shows fraction plus elapsed detail and can cancel")
    func soloTranscriptionRunning() {
        let progress = EpisodeTranscriptionProgress(
            audioDuration: 600,
            completedDuration: 60,
            checkpointCount: 1,
            currentWindowIndex: nil,
            currentText: nil
        )

        let state = makeState(downloadRecord: downloadRecord(state: .completed), transcription: .running(progress))

        #expect(state == EpisodePipelineState(
            title: EpisodePipelineState.transcribingTitle,
            steps: [EpisodePipelineStep(
                kind: .transcribe,
                status: .running(fraction: progress.fractionCompleted, detail: "1:00 of 10:00")
            )],
            footnote: nil,
            action: .cancelTranscription
        ))
    }

    @Test("A failed transcript survives relaunch as a Retry card")
    func failedTranscriptAfterRelaunch() {
        let state = makeState(
            downloadRecord: downloadRecord(state: .completed),
            transcription: .failed(transcriptRecord(state: .failed))
        )

        #expect(state?.title == EpisodePipelineState.transcriptFailedTitle)
        #expect(state?.steps == [EpisodePipelineStep(
            kind: .transcribe,
            status: .failed(message: EpisodePipelineState.transcriptFailedMessage)
        )])
        #expect(state?.action == .retryTranscription)
    }

    @Test("A cancelled transcript offers Retry with its own copy")
    func cancelledTranscript() {
        let state = makeState(transcription: .cancelled(transcriptRecord(state: .cancelled)))

        #expect(state?.steps.first?.status == .failed(message: EpisodePipelineState.transcriptCancelledMessage))
        #expect(state?.action == .retryTranscription)
    }

    @Test("An interrupted transcript offers a solo Resume")
    func interruptedTranscript() {
        let state = makeState(transcription: .interrupted(transcriptRecord(state: .interrupted)))

        #expect(state?.title == EpisodePipelineState.transcriptPausedTitle)
        #expect(state?.footnote == EpisodePipelineState.pausedFootnote)
        #expect(state?.action == .resumeTranscription)
    }

    @Test("An interrupted Apple transcript offers Retry with restart copy")
    func interruptedAppleTranscript() {
        let state = makeState(transcription: .interrupted(transcriptRecord(
            state: .interrupted,
            modelIdentifier: "apple-speech-transcriber.en_US"
        )))

        #expect(state?.title == EpisodePipelineState.transcriptPausedTitle)
        #expect(state?.footnote == EpisodePipelineState.appleSpeechRestartFootnote)
        #expect(state?.action == .retryTranscription)
    }

    // MARK: - Solo analysis

    @Test("A running analysis shows without a cancel action")
    func soloAnalysisRunning() {
        let state = makeState(analysis: .running)

        #expect(state == EpisodePipelineState(
            title: EpisodePipelineState.analyzingTitle,
            steps: [EpisodePipelineStep(kind: .detectAds, status: .running(fraction: nil, detail: nil))],
            footnote: nil,
            action: nil
        ))
    }

    @Test("A fresh failed analysis offers Retry")
    func failedAnalysis() {
        let state = makeState(analysis: .failed(analysisRecord(state: .failed), isStale: false))

        #expect(state?.title == EpisodePipelineState.analysisFailedTitle)
        #expect(state?.action == .retryAnalysis)
    }

    @Test("A stale failed analysis hides the card")
    func staleFailedAnalysisHidesCard() {
        let state = makeState(analysis: .failed(analysisRecord(state: .failed), isStale: true))
        #expect(state == nil)
    }

    // MARK: - Idle

    @Test("No work and no failures means no card")
    func idleHidesCard() {
        #expect(makeState() == nil)
        #expect(makeState(downloadRecord: downloadRecord(state: .completed), transcription: .completed(transcriptRecord(state: .completed))) == nil)
    }

    @Test("Action titles carry the settled copy")
    func actionTitles() {
        #expect(EpisodePipelineAction.cancelPass.title == "Cancel")
        #expect(EpisodePipelineAction.resumeQueue.title == "Resume")
        #expect(EpisodePipelineAction.retryPass.title == "Retry")
        #expect(EpisodePipelineAction.removeFromQueue.title == "Remove from Queue")
        #expect(EpisodePipelineAction.downloadModel(byteCount: nil).title == "Download Model")
    }

    // MARK: - Fixtures

    private func makeState(
        queueStatus: AdFreePassQueueEpisodeStatus = .notQueued,
        queueSnapshot: AdFreePassQueueSnapshot = AdFreePassQueueSnapshot(),
        downloadRecord: EpisodeDownloadRecord? = nil,
        transcription: EpisodeTranscriptionJobState = .unavailable,
        analysis: EpisodeAdAnalysisJobState? = nil
    ) -> EpisodePipelineState? {
        EpisodePipelineState.make(
            episodeID: episodeID,
            queueStatus: queueStatus,
            queueSnapshot: queueSnapshot,
            downloadRecord: downloadRecord,
            transcription: transcription,
            analysis: analysis
        )
    }

    private func activeSnapshot(stage: EpisodeAdFreePassStage) -> AdFreePassQueueSnapshot {
        AdFreePassQueueSnapshot(
            state: .running,
            activeEpisodeID: episodeID,
            currentStage: stage
        )
    }

    private func pendingSnapshot(
        state: AdFreePassQueueState,
        pendingIDs: [String],
        pendingModelConsentByteCount: Int64? = nil
    ) -> AdFreePassQueueSnapshot {
        AdFreePassQueueSnapshot(
            state: state,
            pendingItems: pendingIDs.map(pendingItem),
            pendingModelConsentByteCount: pendingModelConsentByteCount
        )
    }

    private func pendingItem(_ id: String) -> AdFreePassQueueItem {
        AdFreePassQueueItem(episode: episodeSnapshot(id), origin: .manual, enqueuedAt: .now, sequence: 0)
    }

    private func episodeSnapshot(_ id: String) -> EpisodeListItemSnapshot {
        EpisodeListItemSnapshot(
            episodeID: id,
            podcastID: "podcast",
            podcastTitle: "Podcast",
            title: "Episode",
            summary: nil,
            publishedAt: nil,
            duration: nil,
            audioURL: nil,
            artworkURL: nil,
            artworkPreview: nil,
            guid: nil,
            cachedAt: .now
        )
    }

    private func downloadRecord(
        state: EpisodeDownloadState,
        bytesReceived: Int64 = 0,
        bytesExpected: Int64? = nil
    ) -> EpisodeDownloadRecord {
        EpisodeDownloadRecord(
            episodeID: episodeID,
            podcastID: "podcast",
            sourceAudioURL: "https://example.com/audio.mp3",
            state: state,
            bytesReceived: bytesReceived,
            bytesExpected: bytesExpected
        )
    }

    private func transcriptRecord(
        state: EpisodeTranscriptState,
        modelIdentifier: String = ""
    ) -> EpisodeTranscriptRecord {
        EpisodeTranscriptRecord(
            episodeID: episodeID,
            podcastID: "podcast",
            sourceAudioURL: "https://example.com/audio.mp3",
            modelIdentifier: modelIdentifier,
            state: state
        )
    }

    private func analysisRecord(state: EpisodeAdAnalysisState) -> EpisodeAdAnalysisRecord {
        EpisodeAdAnalysisRecord(episodeID: episodeID, podcastID: "podcast", state: state)
    }
}
