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

    @Test("A key-required item fails the pass on the detect step with the reason's copy and Retry")
    func keyRequiredPassNamesTheReason() {
        let state = makeState(
            queueStatus: .keyRequired(.trialPaused),
            downloadRecord: downloadRecord(state: .completed),
            transcription: .completed(transcriptRecord(state: .completed))
        )

        #expect(state == EpisodePipelineState(
            title: EpisodePipelineState.passFailedTitle,
            steps: [
                EpisodePipelineStep(kind: .download, status: .done),
                EpisodePipelineStep(kind: .transcribe, status: .done),
                EpisodePipelineStep(
                    kind: .detectAds,
                    status: .failed(message: "Free analyses are paused for now. Add a key in Settings › AI Services.")
                )
            ],
            footnote: nil,
            action: .retryPass
        ))
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

    @Test("The running card says when a run uses the trial service for a free-tier key, and only then")
    func freeTierFootnote() {
        let footnote = "Your Google key is on Google's free tier. Using opencast's trial service."
        let pass = { (isFreeTierTrial: Bool) in
            makeState(
                queueStatus: .running,
                queueSnapshot: AdFreePassQueueSnapshot(
                    currentStage: .analyzing(steps: EpisodeAdFreePassAnalysisSteps(completed: 0, total: 2, isFreeTierTrial: isFreeTierTrial))
                )
            )
        }
        #expect(pass(true)?.footnote == footnote)
        #expect(pass(false)?.footnote == nil)

        #expect(makeState(analysis: .running, usesTrialForFreeTier: true)?.footnote == footnote)
        #expect(makeState(analysis: .running)?.footnote == nil)
    }

    @Test(
        "A failed analysis names its persisted failure kind, solo and inside a failed pass",
        arguments: [
            (EpisodeAnalysisFailureKind.timedOut, "Ad detection took too long. Try again."),
            (.keyRequiredTrialExhausted, "Your free analyses are used. Add a key in Settings › AI Services.")
        ] as [(EpisodeAnalysisFailureKind, String)]
    )
    func failedAnalysisCopyFollowsFailureKind(kind: EpisodeAnalysisFailureKind, message: String) {
        let analysis = EpisodeAdAnalysisJobState.failed(analysisRecord(state: .failed, failureKind: kind), isStale: false)

        let solo = makeState(analysis: analysis)
        #expect(solo == EpisodePipelineState(
            title: EpisodePipelineState.analysisFailedTitle,
            steps: [EpisodePipelineStep(kind: .detectAds, status: .failed(message: message))],
            footnote: nil,
            action: .retryAnalysis
        ))

        let pass = makeState(
            queueStatus: .failed(message: "Queue outcome."),
            downloadRecord: downloadRecord(state: .completed),
            transcription: .completed(transcriptRecord(state: .completed)),
            analysis: analysis
        )
        #expect(pass?.title == EpisodePipelineState.passFailedTitle)
        #expect(pass?.steps.last == EpisodePipelineStep(kind: .detectAds, status: .failed(message: message)))
        #expect(pass?.action == .retryPass)
    }

    @Test("A failed analysis without a persisted kind keeps the generic copy")
    func failedAnalysisWithoutKindKeepsGenericCopy() {
        let state = makeState(analysis: .failed(analysisRecord(state: .failed), isStale: false))
        #expect(state?.steps == [EpisodePipelineStep(
            kind: .detectAds,
            status: .failed(message: EpisodePipelineState.analysisFailedMessage)
        )])
    }

    @Test("A stale failed analysis hides the card")
    func staleFailedAnalysisHidesCard() {
        let state = makeState(analysis: .failed(analysisRecord(state: .failed), isStale: true))
        #expect(state == nil)
    }

    // MARK: - Cloud preparation

    @Test(
        "An exact-copy upload shows measured part counts, never a fraction, with the upload footnote",
        arguments: [
            (0, 0, "Preparing audio upload…"),
            (0, 10, "Uploading audio… 0 of 10 parts uploaded"),
            (2, 10, "Uploading audio… 2 of 10 parts uploaded"),
            (9, 10, "Uploading audio… 9 of 10 parts uploaded"),
            (10, 10, "Finishing audio upload…")
        ] as [(Int, Int, String)]
    )
    func cloudUploadShowsPartCounts(completedParts: Int, totalParts: Int, detail: String) {
        let state = makeState(
            queueStatus: .running,
            queueSnapshot: activeSnapshot(stage: .cloudUploadingExactCopy(
                completedParts: completedParts,
                totalParts: totalParts
            )),
            downloadRecord: downloadRecord(state: .completed)
        )

        #expect(state == EpisodePipelineState(
            title: EpisodePipelineState.passTitle,
            steps: [
                EpisodePipelineStep(kind: .download, status: .done),
                EpisodePipelineStep(
                    kind: .transcribe,
                    status: .running(fraction: nil, detail: detail)
                ),
                EpisodePipelineStep(kind: .detectAds, status: .waiting)
            ],
            footnote: EpisodePipelineState.cloudUploadFootnote,
            action: .cancelPass
        ))
    }

    // MARK: - Parked cloud job

    @Test(
        "A parked cloud item says the server is still working, keeps Cancel and offers Resume",
        arguments: [RemoteTranscriptionJobExit.parked, .connectionLost, .localRequestFailed]
    )
    func remoteParkedOffersResumeAndCancel(reason: RemoteTranscriptionJobExit) {
        var head = pendingItem(episodeID)
        head.remoteParkReason = reason
        let state = makeState(
            queueStatus: .remoteParked(reason),
            queueSnapshot: AdFreePassQueueSnapshot(state: .pausedInterrupted, pendingItems: [head]),
            downloadRecord: downloadRecord(state: .completed)
        )

        #expect(state == EpisodePipelineState(
            title: RemoteTranscriptionStatusPresentation.parkedTitle,
            steps: [
                EpisodePipelineStep(kind: .download, status: .done),
                EpisodePipelineStep(kind: .transcribe, status: .waiting),
                EpisodePipelineStep(kind: .detectAds, status: .waiting)
            ],
            footnote: RemoteTranscriptionStatusPresentation.parkedDetail(for: reason),
            action: .cancelPass,
            footerAction: .resumeQueue
        ))
        #expect(state?.footnote != EpisodePipelineState.pausedFootnote)
    }

    // MARK: - Fixtures

    private func makeState(
        queueStatus: AdFreePassQueueEpisodeStatus = .notQueued,
        queueSnapshot: AdFreePassQueueSnapshot = AdFreePassQueueSnapshot(),
        downloadRecord: EpisodeDownloadRecord? = nil,
        transcription: EpisodeTranscriptionJobState = .unavailable,
        analysis: EpisodeAdAnalysisJobState? = nil,
        usesTrialForFreeTier: Bool = false
    ) -> EpisodePipelineState? {
        EpisodePipelineState.make(
            episodeID: episodeID,
            queueStatus: queueStatus,
            queueSnapshot: queueSnapshot,
            downloadRecord: downloadRecord,
            transcription: transcription,
            analysis: analysis,
            usesTrialForFreeTier: usesTrialForFreeTier
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

    private func analysisRecord(
        state: EpisodeAnalysisRecordState,
        failureKind: EpisodeAnalysisFailureKind? = nil
    ) -> EpisodeAdAnalysisRecord {
        let record = EpisodeAdAnalysisRecord(episodeID: episodeID, podcastID: "podcast", state: state)
        record.failureKind = failureKind
        return record
    }
}
