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

        for state in [AdFreePassQueueState.pausedInterrupted, .awaitingModelConsent, .capDeferred] {
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
        #expect(
            makePresentation(state: .capDeferred, pendingItems: [makeItem(episodeID: "a")]).affordance
                == .retryCapDeferred
        )
    }

    @Test("Rows carry the active stage text, queue positions, and pause reasons")
    func rowTable() {
        let running = makePresentation(
            state: .running,
            activeEpisodeID: "active",
            activeEpisodeTitle: "Active Episode",
            currentStage: .analyzing,
            pendingItems: [makeItem(episodeID: "next"), makeItem(episodeID: "later")]
        )
        #expect(running.rows.map(\.episodeID) == ["active", "next", "later"])
        #expect(running.rows[0].status == .running(statusText: "Analyzing promos and ads..."))
        #expect(running.rows[0].episodeTitle == "Active Episode")
        #expect(running.rows[1].status == .queued(ahead: 1))
        #expect(running.rows[1].statusText == "Queued — 1 ahead")
        #expect(running.rows[2].status == .queued(ahead: 2))

        let capDeferred = makePresentation(
            state: .capDeferred,
            pendingItems: [makeItem(episodeID: "head"), makeItem(episodeID: "second")]
        )
        #expect(capDeferred.rows[0].status == .capDeferred)
        #expect(capDeferred.rows[0].statusText == "Daily detection limit reached — continues tomorrow")
        #expect(capDeferred.rows[1].status == .queued(ahead: 1))

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

    @Test("Stage status text matches the per-episode presentation copy")
    func stageStatusTextTable() {
        #expect(AdDetectionQueuePresentation.statusText(for: nil) == "Preparing...")
        #expect(AdDetectionQueuePresentation.statusText(for: .idle) == "Preparing...")
        #expect(AdDetectionQueuePresentation.statusText(for: .downloadingEpisode) == "Downloading episode...")
        #expect(AdDetectionQueuePresentation.statusText(for: .analyzing) == "Analyzing promos and ads...")
        #expect(AdDetectionQueuePresentation.statusText(for: .completed(zoneCount: 2)) == "2 zones marked.")
        #expect(AdDetectionQueuePresentation.statusText(for: .failed(message: "probe")) == "probe")
        #expect(
            AdDetectionQueuePresentation.statusText(for: .interrupted)
                == EpisodeAdFreePassPresentation.interrupted.statusText
        )
        #expect(
            AdDetectionQueuePresentation.statusText(for: .awaitingModelDownloadConsent(byteCount: 1_000))
                == EpisodeAdFreePassPresentation.awaitingModelConsent(byteCount: 1_000).statusText
        )
    }

    @Test("Accessibility value carries percent and state")
    func accessibilityValueTable() {
        #expect(makePresentation(state: .idle).accessibilityValue == "Idle")
        #expect(
            makePresentation(state: .running, activeEpisodeID: "a", fractionCompleted: 0.42).accessibilityValue
                == "42% — detecting ads"
        )
        #expect(
            makePresentation(
                state: .idle,
                completedCount: 2,
                failedCount: 1,
                outcomes: [completedOutcome(episodeID: "a")]
            ).accessibilityValue
                == "Finished — 2 detected, 1 failed"
        )
        #expect(
            makePresentation(
                state: .capDeferred,
                fractionCompleted: 0.25,
                pendingItems: [makeItem(episodeID: "a")]
            ).accessibilityValue
                == "25% — Daily detection limit reached — continues tomorrow"
        )
    }

    // MARK: - Fixtures

    @Test("Cloud items hide the background-continuation affordance while running")
    func cloudRunningHidesBackgroundAffordance() {
        let cloud = makePresentation(
            state: .running,
            activeEpisodeID: "a",
            activeItemMode: .cloud
        )
        #expect(cloud.affordance == nil)

        let device = makePresentation(
            state: .running,
            activeEpisodeID: "a",
            activeItemMode: .onDevice
        )
        #expect(device.affordance == .continueInBackground)
    }

    @Test("Cloud stages render their own status text")
    func cloudStageStatusText() {
        #expect(
            AdDetectionQueuePresentation.statusText(for: .cloudQueued)
                == EpisodeAdFreePassPresentation.cloudQueued.statusText
        )
        #expect(
            AdDetectionQueuePresentation.statusText(for: .cloudTranscribing(nil))
                == "Transcribing on the server..."
        )
        #expect(
            AdDetectionQueuePresentation.statusText(for: .cloudDetectingAds)
                == EpisodeAdFreePassPresentation.cloudDetectingAds.statusText
        )
        #expect(
            AdDetectionQueuePresentation.statusText(for: .cloudUnavailable(message: "No credits."))
                == "No credits."
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
                kind: .cloudUnavailable(message: "Cloud detection is off.")
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

    private func makePresentation(
        state: AdFreePassQueueState,
        activeEpisodeID: String? = nil,
        activeEpisodeTitle: String? = nil,
        activeItemMode: AdDetectionMode? = nil,
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
                activeItemMode: activeItemMode,
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
            kind: .completed(zoneCount: zoneCount)
        )
    }

    private func failedOutcome(episodeID: String, message: String = "probe") -> AdFreePassQueueItemOutcome {
        AdFreePassQueueItemOutcome(
            episodeID: episodeID,
            episodeTitle: "Episode \(episodeID)",
            artworkURL: nil,
            kind: .failed(message: message)
        )
    }
}
