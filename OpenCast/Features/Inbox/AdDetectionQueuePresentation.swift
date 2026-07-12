/// Pure mapping from the coordinator's queue snapshot (plus the background
/// session's armed bit) to everything the Inbox toolbar indicator and the
/// Ad Detection queue screen render. Kept free of view state so the full
/// state table is unit-testable.
struct AdDetectionQueuePresentation: Equatable {
    enum Indicator: Equatable {
        case hidden
        case running(fractionCompleted: Double, hasFailures: Bool)
        case paused(hasFailures: Bool)
        case finished(hasFailures: Bool)
    }

    enum Affordance: Equatable {
        case continueInBackground
        case backgroundContinuationArmed
        case retryCapDeferred
        case resumeInterrupted
        case downloadModelConsent(byteCount: Int64)
    }

    struct Row: Identifiable, Equatable {
        enum Status: Equatable {
            case running(statusText: String)
            case queued(ahead: Int)
            case capDeferred
            case awaitingConsent
            case interrupted
            case completed(zoneCount: Int)
            case failed(message: String)
        }

        let episodeID: String
        let episodeTitle: String
        let artworkURL: String?
        let status: Status

        var id: String {
            episodeID
        }

        var statusText: String {
            switch status {
            case .running(let statusText):
                statusText
            case .queued(let ahead):
                EpisodeAdFreePassPresentation.queued(ahead: ahead).statusText
            case .capDeferred:
                EpisodeAdFreePassPresentation.capDeferred.statusText
            case .awaitingConsent:
                "Waiting for the speech model."
            case .interrupted:
                EpisodeAdFreePassPresentation.interrupted.statusText
            case .completed(let zoneCount):
                EpisodeAdFreePassPresentation.completed(zoneCount: zoneCount).statusText
            case .failed(let message):
                message
            }
        }
    }

    let indicator: Indicator
    let rows: [Row]
    let finishedRows: [Row]
    let affordance: Affordance?
    let fractionCompleted: Double
    let accessibilityValue: String

    var isEmpty: Bool {
        rows.isEmpty && finishedRows.isEmpty
    }

    init(snapshot: AdFreePassQueueSnapshot, isBackgroundSessionArmed: Bool) {
        let hasFailures = snapshot.failedCount > 0
        fractionCompleted = snapshot.fractionCompleted

        switch snapshot.state {
        case .idle:
            indicator = snapshot.outcomes.isEmpty ? .hidden : .finished(hasFailures: hasFailures)
            affordance = nil
        case .running:
            indicator = .running(
                fractionCompleted: snapshot.fractionCompleted,
                hasFailures: hasFailures
            )
            affordance = isBackgroundSessionArmed ? .backgroundContinuationArmed : .continueInBackground
        case .pausedInterrupted:
            indicator = .paused(hasFailures: hasFailures)
            affordance = .resumeInterrupted
        case .awaitingModelConsent:
            indicator = .paused(hasFailures: hasFailures)
            affordance = .downloadModelConsent(byteCount: snapshot.pendingModelConsentByteCount ?? 0)
        case .capDeferred:
            indicator = .paused(hasFailures: hasFailures)
            affordance = .retryCapDeferred
        }

        var rows: [Row] = []
        if let activeEpisodeID = snapshot.activeEpisodeID {
            rows.append(Row(
                episodeID: activeEpisodeID,
                episodeTitle: snapshot.activeEpisodeTitle ?? "",
                artworkURL: snapshot.activeArtworkURL,
                status: .running(statusText: Self.statusText(for: snapshot.currentStage))
            ))
        }
        let aheadOffset = snapshot.activeEpisodeID != nil ? 1 : 0
        for (index, item) in snapshot.pendingItems.enumerated() {
            let status: Row.Status
            if index == 0, snapshot.activeEpisodeID == nil {
                switch snapshot.state {
                case .capDeferred:
                    status = .capDeferred
                case .awaitingModelConsent:
                    status = .awaitingConsent
                case .pausedInterrupted:
                    status = .interrupted
                case .idle, .running:
                    status = .queued(ahead: index + aheadOffset)
                }
            } else {
                status = .queued(ahead: index + aheadOffset)
            }
            rows.append(Row(
                episodeID: item.episodeID,
                episodeTitle: item.episode.title,
                artworkURL: item.episode.artworkURL,
                status: status
            ))
        }
        self.rows = rows

        finishedRows = snapshot.outcomes.map { outcome in
            Row(
                episodeID: outcome.episodeID,
                episodeTitle: outcome.episodeTitle,
                artworkURL: outcome.artworkURL,
                status: {
                    switch outcome.kind {
                    case .completed(let zoneCount):
                        .completed(zoneCount: zoneCount)
                    case .failed(let message):
                        .failed(message: message)
                    }
                }()
            )
        }

        let percent = Int((snapshot.fractionCompleted * 100).rounded())
        switch snapshot.state {
        case .idle:
            accessibilityValue = snapshot.outcomes.isEmpty
                ? "Idle"
                : "Finished — \(snapshot.completedCount) detected, \(snapshot.failedCount) failed"
        case .running:
            accessibilityValue = "\(percent)% — detecting ads"
        case .pausedInterrupted:
            accessibilityValue = "\(percent)% — paused"
        case .awaitingModelConsent:
            accessibilityValue = "\(percent)% — waiting for the speech model"
        case .capDeferred:
            accessibilityValue = "\(percent)% — " + EpisodeAdFreePassPresentation.capDeferred.statusText
        }
    }

    static func statusText(for stage: EpisodeAdFreePassStage?) -> String {
        switch stage {
        case nil, .idle:
            "Preparing..."
        case .awaitingModelDownloadConsent(let byteCount):
            EpisodeAdFreePassPresentation.awaitingModelConsent(byteCount: byteCount).statusText
        case .downloadingEpisode:
            EpisodeAdFreePassPresentation.downloadingEpisode.statusText
        case .installingModel(let progress):
            EpisodeAdFreePassPresentation.installingModel(progress).statusText
        case .installingSpeechAssets(let fractionCompleted):
            EpisodeAdFreePassPresentation.installingSpeechAssets(fractionCompleted: fractionCompleted).statusText
        case .transcribing(let progress):
            EpisodeAdFreePassPresentation.transcribing(progress).statusText
        case .analyzing:
            EpisodeAdFreePassPresentation.analyzing.statusText
        case .completed(let zoneCount):
            EpisodeAdFreePassPresentation.completed(zoneCount: zoneCount).statusText
        case .interrupted:
            EpisodeAdFreePassPresentation.interrupted.statusText
        case .failed(let message):
            message
        case .unavailable(let message):
            message
        }
    }
}
