import Foundation
import Testing
@testable import OpenCast

@MainActor
@Suite("Ad detection queue presentation")
struct AdDetectionQueuePresentationTests {
    @Test("Indicator variant follows the queue state")
    func indicatorVariantTable() {
        let idle = makePresentation(state: .idle)
        #expect(idle.indicator == .hidden)

        let finished = makePresentation(
            state: .idle,
            completedCount: 2,
            outcomes: [completedOutcome(episodeID: "a"), completedOutcome(episodeID: "b")]
        )
        #expect(finished.indicator == .finished(hasFailures: false))

        let finishedWithFailure = makePresentation(
            state: .idle,
            completedCount: 1,
            failedCount: 1,
            outcomes: [completedOutcome(episodeID: "a"), failedOutcome(episodeID: "b")]
        )
        #expect(finishedWithFailure.indicator == .finished(hasFailures: true))

        let running = makePresentation(
            state: .running,
            activeEpisodeID: "a",
            fractionCompleted: 0.42
        )
        #expect(running.indicator == .running(fractionCompleted: 0.42, hasFailures: false))

        let runningWithFailure = makePresentation(
            state: .running,
            activeEpisodeID: "b",
            failedCount: 1,
            fractionCompleted: 0.5
        )
        #expect(runningWithFailure.indicator == .running(fractionCompleted: 0.5, hasFailures: true))

        for state in [AdFreePassQueueState.pausedInterrupted, .awaitingModelConsent] {
            let paused = makePresentation(state: state, pendingItems: [makeItem(episodeID: "head")])
            #expect(paused.indicator == .paused(hasFailures: false), "state \(state)")
        }
    }

    @Test("Affordance follows the queue state and the armed bit")
    func affordanceTable() {
        #expect(makePresentation(state: .idle).affordance == nil)
        #expect(
            makePresentation(state: .running, activeEpisodeID: "a").affordance
                == .continueInBackground
        )
        #expect(
            makePresentation(state: .running, activeEpisodeID: "a", isArmed: true).affordance
                == .backgroundContinuationArmed
        )
        #expect(
            makePresentation(state: .pausedInterrupted, pendingItems: [makeItem(episodeID: "a")]).affordance
                == .resumeInterrupted
        )
        #expect(
            makePresentation(
                state: .awaitingModelConsent,
                pendingItems: [makeItem(episodeID: "a")],
                pendingModelConsentByteCount: 78_900_000
            ).affordance
                == .downloadModelConsent(byteCount: 78_900_000)
        )
    }

    @Test("Rows carry the active stage text, queue positions, and pause reasons")
    func rowTable() {
        let running = makePresentation(
            state: .running,
            activeEpisodeID: "active",
            activeEpisodeTitle: "Active Episode",
            currentStage: .analyzing(steps: EpisodeAdFreePassAnalysisSteps(completed: 1, total: 3)),
            pendingItems: [makeItem(episodeID: "next"), makeItem(episodeID: "later")]
        )
        #expect(running.rows.map(\.episodeID) == ["active", "next", "later"])
        #expect(running.rows[0].status == .running(statusText: "Detecting ads"))
        #expect(running.rows[0].episodeTitle == "Active Episode")
        #expect(running.rows[1].status == .queued(ahead: 1))
        #expect(running.rows[1].statusText == "Queued — 1 ahead")
        #expect(running.rows[2].status == .queued(ahead: 2))

        let consent = makePresentation(
            state: .awaitingModelConsent,
            pendingItems: [makeItem(episodeID: "head")],
            pendingModelConsentByteCount: 1_000
        )
        #expect(consent.rows[0].status == .awaitingConsent)

        let interrupted = makePresentation(
            state: .pausedInterrupted,
            pendingItems: [makeItem(episodeID: "head")]
        )
        #expect(interrupted.rows[0].status == .interrupted)
    }

    @Test("Finished rows map outcomes and the screen empties only with nothing to show")
    func finishedRowsAndEmptiness() {
        let presentation = makePresentation(
            state: .idle,
            completedCount: 1,
            failedCount: 1,
            outcomes: [
                completedOutcome(episodeID: "done", zoneCount: 3),
                failedOutcome(episodeID: "broken", message: "Download failed.")
            ]
        )
        #expect(presentation.finishedRows.map(\.episodeID) == ["done", "broken"])
        #expect(presentation.finishedRows[0].status == .completed(zoneCount: 3))
        #expect(presentation.finishedRows[0].statusText == "3 zones marked.")
        #expect(presentation.finishedRows[1].status == .failed(message: "Download failed."))
        #expect(!presentation.isEmpty)

        #expect(makePresentation(state: .idle).isEmpty)
    }

    // MARK: - Fixtures

    @Test("A parked cloud head renders as still running on the server with the queue-level Resume")
    func parkedCloudHeadRendersRemoteParkedRow() {
        var parked = makeItem(episodeID: "parked")
        parked.remoteParkReason = .connectionLost
        let presentation = makePresentation(
            state: .pausedInterrupted,
            pendingItems: [parked, makeItem(episodeID: "behind")]
        )

        #expect(presentation.indicator == .paused(hasFailures: false))
        #expect(presentation.affordance == .resumeInterrupted)
        #expect(presentation.rows.map(\.status) == [.remoteParked(.connectionLost), .queued(ahead: 1)])
        #expect(presentation.rows[0].statusText == RemoteTranscriptionStatusPresentation.parkedTitle)
        #expect(presentation.rows[0].statusText != EpisodeAdFreePassPresentation.interrupted.statusText)
        #expect(
            AdDetectionQueuePresentation.statusText(for: .cloudParked(.parked))
                == RemoteTranscriptionStatusPresentation.parkedTitle
        )
    }

    @Test("Cloud-unavailable outcomes surface as their own finished row status")
    func cloudUnavailableFinishedRow() {
        let presentation = makePresentation(
            state: .idle,
            failedCount: 1,
            outcomes: [AdFreePassQueueItemOutcome(
                episodeID: "a",
                episodeTitle: "Episode a",
                artworkURL: nil,
                kind: .cloudUnavailable(message: "Cloud detection is off."),
                completionDeliveryOwner: .local
            )]
        )
        #expect(presentation.finishedRows.count == 1)
        #expect(
            presentation.finishedRows[0].status
                == .cloudUnavailable(message: "Cloud detection is off.")
        )
        #expect(presentation.finishedRows[0].statusText == "Cloud detection is off.")
        #expect(presentation.indicator == .finished(hasFailures: true))
    }

    @Test("A key-required item says what to do above the queue in every state and fails its row with the reason")
    func keyRequiredOutcomeShowsNoticeAndReasonRow() {
        let keyRequired = AdFreePassQueueItemOutcome(
            episodeID: "needs-key",
            episodeTitle: "Episode needs-key",
            artworkURL: nil,
            kind: .keyRequired(.trialExhausted),
            completionDeliveryOwner: .local
        )
        let finished = makePresentation(
            state: .idle,
            completedCount: 1,
            failedCount: 1,
            outcomes: [completedOutcome(episodeID: "done"), keyRequired]
        )
        #expect(finished.keyRequiredNotice == "Add a key in Settings › AI Services to keep detecting ads")
        #expect(finished.finishedRows[1].status == .failed(
            message: "Your free analyses are used. Add a key in Settings › AI Services."
        ))
        #expect(finished.indicator == .finished(hasFailures: true))

        let stillRunning = makePresentation(
            state: .running,
            activeEpisodeID: "next",
            failedCount: 1,
            outcomes: [keyRequired]
        )
        #expect(stillRunning.keyRequiredNotice == AdDetectionQueuePresentation.keyRequiredNotice)
        #expect(stillRunning.affordance == .continueInBackground)

        #expect(makePresentation(
            state: .idle,
            failedCount: 1,
            outcomes: [failedOutcome(episodeID: "broken")]
        ).keyRequiredNotice == nil)
    }

    private func makePresentation(
        state: AdFreePassQueueState,
        activeEpisodeID: String? = nil,
        activeEpisodeTitle: String? = nil,
        currentStage: EpisodeAdFreePassStage? = nil,
        completedCount: Int = 0,
        failedCount: Int = 0,
        fractionCompleted: Double = 0,
        outcomes: [AdFreePassQueueItemOutcome] = [],
        pendingItems: [AdFreePassQueueItem] = [],
        pendingModelConsentByteCount: Int64? = nil,
        isArmed: Bool = false
    ) -> AdDetectionQueuePresentation {
        AdDetectionQueuePresentation(
            snapshot: AdFreePassQueueSnapshot(
                state: state,
                activeEpisodeID: activeEpisodeID,
                activeEpisodeTitle: activeEpisodeTitle,
                activeArtworkURL: nil,
                currentStage: currentStage,
                finishedItemCount: completedCount + failedCount,
                totalItemCount: completedCount + failedCount
                    + (activeEpisodeID != nil ? 1 : 0) + pendingItems.count,
                completedCount: completedCount,
                failedCount: failedCount,
                fractionCompleted: fractionCompleted,
                outcomes: outcomes,
                pendingItems: pendingItems,
                pendingModelConsentByteCount: pendingModelConsentByteCount
            ),
            isBackgroundSessionArmed: isArmed
        )
    }

    private func makeItem(episodeID: String) -> AdFreePassQueueItem {
        AdFreePassQueueItem(
            episode: EpisodeListItemSnapshot(
                episodeID: episodeID,
                podcastID: "https://example.com/feed.xml",
                podcastTitle: "Example Show",
                title: "Episode \(episodeID)",
                summary: nil,
                publishedAt: nil,
                duration: 60,
                audioURL: "https://example.com/\(episodeID).mp3",
                artworkURL: nil,
                artworkPreview: nil,
                guid: episodeID,
                cachedAt: .now
            ),
            origin: .manual,
            enqueuedAt: .now,
            sequence: 0
        )
    }

    private func completedOutcome(episodeID: String, zoneCount: Int = 1) -> AdFreePassQueueItemOutcome {
        AdFreePassQueueItemOutcome(
            episodeID: episodeID,
            episodeTitle: "Episode \(episodeID)",
            artworkURL: nil,
            kind: .completed(zoneCount: zoneCount),
            completionDeliveryOwner: .local
        )
    }

    private func failedOutcome(episodeID: String, message: String = "probe") -> AdFreePassQueueItemOutcome {
        AdFreePassQueueItemOutcome(
            episodeID: episodeID,
            episodeTitle: "Episode \(episodeID)",
            artworkURL: nil,
            kind: .failed(message: message),
            completionDeliveryOwner: .local
        )
    }
}
