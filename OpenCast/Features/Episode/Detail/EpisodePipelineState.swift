import Foundation

/// Pure mapping from queue/store state to the episode pipeline progress card.
/// `nil` means the card is hidden. First matching rule wins; the order follows
/// the redesign plan's mapping table.
struct EpisodePipelineState: Equatable {
    let title: String
    let steps: [EpisodePipelineStep]
    let footnote: String?
    let action: EpisodePipelineAction?

    static let passTitle = "Making this episode ad-free"
    static let passFailedTitle = "Couldn't make this episode ad-free"
    static let downloadingTitle = "Downloading…"
    static let downloadFailedTitle = "Download didn't finish"
    static let downloadPausedTitle = "Download paused"
    static let transcribingTitle = "Generating transcript…"
    static let transcriptFailedTitle = "Transcript didn't finish"
    static let transcriptPausedTitle = "Transcript paused"
    static let analyzingTitle = "Detecting ads…"
    static let analysisFailedTitle = "Ad detection didn't finish"

    static let downloadFailedMessage = "The download couldn't finish."
    static let downloadMissingMessage = "The downloaded file is missing."
    static let transcriptFailedMessage = "The transcript couldn't be completed."
    static let transcriptCancelledMessage = "The transcript was cancelled."
    static let analysisFailedMessage = "Ad detection couldn't finish."
    static let pausedFootnote = "Paused — resume anytime."
    static let modelConsentFootnote = "A speech model download is needed to continue."

    static func make(
        episodeID: String,
        queueStatus: AdFreePassQueueEpisodeStatus,
        queueSnapshot: AdFreePassQueueSnapshot,
        downloadRecord: EpisodeDownloadRecord?,
        transcription: EpisodeTranscriptionJobState,
        analysis: EpisodeAdAnalysisJobState?
    ) -> EpisodePipelineState? {
        if queueStatus == .running {
            return activePassState(stage: queueSnapshot.currentStage, downloadRecord: downloadRecord)
        }

        // A current completed analysis means the chips and ad-span timeline
        // take over; nothing below outranks it.
        if case .completed(_, isStale: false) = analysis {
            return nil
        }

        let isPendingHead = queueSnapshot.pendingItems.first?.episodeID == episodeID

        if queueSnapshot.state == .awaitingModelConsent, isPendingHead {
            return EpisodePipelineState(
                title: passTitle,
                steps: passSteps(download: completedOrWaiting(downloadRecord), transcribe: .waiting, detect: .waiting),
                footnote: modelConsentFootnote,
                action: .downloadModel(byteCount: queueSnapshot.pendingModelConsentByteCount)
            )
        }

        if queueSnapshot.state == .pausedInterrupted, isPendingHead {
            return EpisodePipelineState(
                title: passTitle,
                steps: passSteps(download: completedOrWaiting(downloadRecord), transcribe: .waiting, detect: .waiting),
                footnote: pausedFootnote,
                action: .resumeQueue
            )
        }

        if queueStatus == .capDeferred {
            return EpisodePipelineState(
                title: passTitle,
                steps: passSteps(
                    download: completedOrWaiting(downloadRecord),
                    transcribe: transcriptDone(transcription) ? .done : .waiting,
                    detect: .waiting
                ),
                footnote: EpisodeAdFreePassPresentation.capDeferred.statusText,
                action: .retryQueue
            )
        }

        if case .queued(let ahead) = queueStatus {
            return EpisodePipelineState(
                title: passTitle,
                steps: passSteps(
                    download: completedOrWaiting(downloadRecord),
                    transcribe: transcriptDone(transcription) ? .done : .waiting,
                    detect: .waiting
                ),
                footnote: ahead > 0 ? "Queued — \(ahead) ahead" : "Queued",
                action: .removeFromQueue
            )
        }

        if case .failed(let message) = queueStatus {
            return failedPassState(
                message: message,
                downloadRecord: downloadRecord,
                transcription: transcription,
                analysis: analysis
            )
        }

        switch downloadRecord?.state {
        case .downloading:
            return EpisodePipelineState(
                title: downloadingTitle,
                steps: [EpisodePipelineStep(
                    kind: .download,
                    status: .running(fraction: downloadFraction(downloadRecord), detail: nil)
                )],
                footnote: nil,
                action: .cancelDownload
            )
        case .failed:
            return soloFailure(kind: .download, title: downloadFailedTitle, message: downloadFailedMessage, action: .retryDownload)
        case .missing:
            return soloFailure(kind: .download, title: downloadFailedTitle, message: downloadMissingMessage, action: .retryDownload)
        case .paused:
            return EpisodePipelineState(
                title: downloadPausedTitle,
                steps: [EpisodePipelineStep(kind: .download, status: .waiting)],
                footnote: pausedFootnote,
                action: .resumeDownload
            )
        case .completed, nil:
            break
        }

        switch transcription {
        case .running(let progress):
            return EpisodePipelineState(
                title: transcribingTitle,
                steps: [EpisodePipelineStep(
                    kind: .transcribe,
                    status: .running(fraction: progress.fractionCompleted, detail: transcribingDetail(progress))
                )],
                footnote: nil,
                action: .cancelTranscription
            )
        case .failed:
            return soloFailure(kind: .transcribe, title: transcriptFailedTitle, message: transcriptFailedMessage, action: .retryTranscription)
        case .cancelled:
            return soloFailure(kind: .transcribe, title: transcriptFailedTitle, message: transcriptCancelledMessage, action: .retryTranscription)
        case .interrupted:
            return EpisodePipelineState(
                title: transcriptPausedTitle,
                steps: [EpisodePipelineStep(kind: .transcribe, status: .waiting)],
                footnote: pausedFootnote,
                action: .resumeTranscription
            )
        case .unavailable, .downloadRequired, .modelRequired, .modelBusy, .ready, .completed:
            break
        }

        switch analysis {
        case .running:
            // The analysis stage has no cancel API, so the card offers none.
            return EpisodePipelineState(
                title: analyzingTitle,
                steps: [EpisodePipelineStep(kind: .detectAds, status: .running(fraction: nil, detail: nil))],
                footnote: nil,
                action: nil
            )
        case .failed(_, isStale: false):
            return soloFailure(kind: .detectAds, title: analysisFailedTitle, message: analysisFailedMessage, action: .retryAnalysis)
        case .failed, .completed, .unavailable, .ready, nil:
            return nil
        }
    }

    private static func activePassState(
        stage: EpisodeAdFreePassStage?,
        downloadRecord: EpisodeDownloadRecord?
    ) -> EpisodePipelineState? {
        switch stage {
        case .downloadingEpisode, .idle, .unavailable, nil:
            return EpisodePipelineState(
                title: passTitle,
                steps: passSteps(
                    download: .running(fraction: downloadFraction(downloadRecord), detail: nil),
                    transcribe: .waiting,
                    detect: .waiting
                ),
                footnote: nil,
                action: .cancelPass
            )
        case .awaitingModelDownloadConsent(let byteCount):
            return EpisodePipelineState(
                title: passTitle,
                steps: passSteps(download: .done, transcribe: .waiting, detect: .waiting),
                footnote: modelConsentFootnote,
                action: .downloadModel(byteCount: byteCount)
            )
        case .installingModel(let progress):
            let fraction = progress.totalByteCount > 0
                ? Double(progress.completedByteCount) / Double(progress.totalByteCount)
                : nil
            return preparingModelState(fraction: fraction)
        case .installingSpeechAssets(let fraction):
            return preparingModelState(fraction: fraction)
        case .transcribing(let progress):
            return EpisodePipelineState(
                title: passTitle,
                steps: passSteps(
                    download: .done,
                    transcribe: .running(fraction: progress.fractionCompleted, detail: transcribingDetail(progress)),
                    detect: .waiting
                ),
                footnote: nil,
                action: .cancelPass
            )
        case .analyzing:
            return EpisodePipelineState(
                title: passTitle,
                steps: passSteps(download: .done, transcribe: .done, detect: .running(fraction: nil, detail: nil)),
                footnote: nil,
                action: .cancelPass
            )
        case .interrupted:
            return EpisodePipelineState(
                title: passTitle,
                steps: passSteps(download: completedOrWaiting(downloadRecord), transcribe: .waiting, detect: .waiting),
                footnote: pausedFootnote,
                action: .resumeQueue
            )
        case .failed(let message):
            return failedPassState(message: message, downloadRecord: downloadRecord, transcription: .unavailable, analysis: nil)
        case .completed:
            return nil
        }
    }

    private static func failedPassState(
        message: String,
        downloadRecord: EpisodeDownloadRecord?,
        transcription: EpisodeTranscriptionJobState,
        analysis: EpisodeAdAnalysisJobState?
    ) -> EpisodePipelineState {
        var download: EpisodePipelineStepStatus = switch downloadRecord?.state {
        case .completed: .done
        case .failed: .failed(message: downloadFailedMessage)
        case .missing: .failed(message: downloadMissingMessage)
        case .downloading, .paused, nil: .waiting
        }
        var transcribe: EpisodePipelineStepStatus = switch transcription {
        case .completed: .done
        case .failed: .failed(message: transcriptFailedMessage)
        case .cancelled: .failed(message: transcriptCancelledMessage)
        default: .waiting
        }
        var detect: EpisodePipelineStepStatus = .waiting
        if case .failed(_, isStale: false) = analysis {
            detect = .failed(message: analysisFailedMessage)
        }

        // The queue outcome message names the failure when no persisted store
        // state does; pin it on the first step that never completed.
        if !download.isFailed, !transcribe.isFailed, !detect.isFailed {
            if download != .done {
                download = .failed(message: message)
            } else if transcribe != .done {
                transcribe = .failed(message: message)
            } else {
                detect = .failed(message: message)
            }
        }

        return EpisodePipelineState(
            title: passFailedTitle,
            steps: passSteps(download: download, transcribe: transcribe, detect: detect),
            footnote: nil,
            action: .retryPass
        )
    }

    private static func preparingModelState(fraction: Double?) -> EpisodePipelineState {
        let detail = if let fraction {
            "Preparing speech model… \(Int((fraction * 100).rounded()))%"
        } else {
            "Preparing speech model…"
        }
        return EpisodePipelineState(
            title: passTitle,
            steps: passSteps(
                download: .done,
                transcribe: .running(fraction: fraction, detail: detail),
                detect: .waiting
            ),
            footnote: nil,
            action: .cancelPass
        )
    }

    private static func soloFailure(
        kind: EpisodePipelineStepKind,
        title: String,
        message: String,
        action: EpisodePipelineAction
    ) -> EpisodePipelineState {
        EpisodePipelineState(
            title: title,
            steps: [EpisodePipelineStep(kind: kind, status: .failed(message: message))],
            footnote: nil,
            action: action
        )
    }

    private static func passSteps(
        download: EpisodePipelineStepStatus,
        transcribe: EpisodePipelineStepStatus,
        detect: EpisodePipelineStepStatus
    ) -> [EpisodePipelineStep] {
        [
            EpisodePipelineStep(kind: .download, status: download),
            EpisodePipelineStep(kind: .transcribe, status: transcribe),
            EpisodePipelineStep(kind: .detectAds, status: detect)
        ]
    }

    private static func completedOrWaiting(_ record: EpisodeDownloadRecord?) -> EpisodePipelineStepStatus {
        record?.state == .completed ? .done : .waiting
    }

    private static func transcriptDone(_ transcription: EpisodeTranscriptionJobState) -> Bool {
        if case .completed = transcription {
            return true
        }
        return false
    }

    private static func downloadFraction(_ record: EpisodeDownloadRecord?) -> Double? {
        guard let record, let expected = record.bytesExpected, expected > 0 else {
            return nil
        }
        return min(max(Double(record.bytesReceived) / Double(expected), 0), 1)
    }

    private static func transcribingDetail(_ progress: EpisodeTranscriptionProgress) -> String? {
        guard progress.audioDuration > 0 else {
            return nil
        }
        return "\(progress.completedDuration.formattedPlaybackDuration) of \(progress.audioDuration.formattedPlaybackDuration)"
    }
}
