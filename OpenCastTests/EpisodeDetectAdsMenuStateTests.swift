import Testing
@testable import OpenCast

@MainActor
@Suite("Episode context menu action states")
struct EpisodeDetectAdsMenuStateTests {
    @Test("Detect Ads label follows the per-episode queue status")
    func detectAdsLabelFollowsQueueStatus() {
        let cases: [(AdFreePassQueueEpisodeStatus, Bool, EpisodeDetectAdsMenuState)] = [
            (.notQueued, false, .detect),
            (.notQueued, true, .detected),
            (.queued(ahead: 2), false, .queued),
            (.queued(ahead: 0), true, .queued),
            (.running, false, .detecting),
            (.running, true, .detecting),
            // A retained completed outcome is decided like `.notQueued`.
            (.completed(zoneCount: 3), false, .detect),
            (.failed(message: "probe"), false, .detect),
            (.failed(message: "probe"), true, .detected),
            (.keyRequired(.noKey), false, .detect),
            (.keyRequired(.trialExhausted), true, .detected),
            (.remoteParked(.parked), false, .queued)
        ]

        for (status, hasAnalysis, expected) in cases {
            let state = EpisodeDetectAdsMenuState(
                queueStatus: status,
                hasCurrentCompletedAnalysis: hasAnalysis,
                isAnalysisAttached: true
            )
            #expect(state == expected, "status \(status) hasAnalysis \(hasAnalysis)")
        }
    }

    @Test(
        "Ads Detected needs the analysis current and attached; current and detached offers Detect Ads Again",
        arguments: [
            (AdFreePassQueueEpisodeStatus.notQueued, true, false, EpisodeDetectAdsMenuState.detectAgain),
            (.notQueued, true, true, .detected),
            (.completed(zoneCount: 2), true, false, .detectAgain),
            (.completed(zoneCount: 2), true, true, .detected),
            (.completed(zoneCount: 2), false, true, .detect),
            (.completed(zoneCount: 0), false, false, .detect),
            (.failed(message: "probe"), true, false, .detectAgain),
            (.keyRequired(.noKey), true, false, .detectAgain)
        ]
    )
    func attachmentDecidesDetectedOrDetectAgain(
        status: AdFreePassQueueEpisodeStatus,
        isCurrent: Bool,
        isAttached: Bool,
        expected: EpisodeDetectAdsMenuState
    ) {
        let state = EpisodeDetectAdsMenuState(
            queueStatus: status,
            hasCurrentCompletedAnalysis: isCurrent,
            isAnalysisAttached: isAttached
        )
        #expect(state == expected)
    }

    @Test(
        "Attachment is read only for a current analysis that is not in the queue",
        arguments: [
            (AdFreePassQueueEpisodeStatus.notQueued, false),
            (.completed(zoneCount: 1), false),
            (.running, true),
            (.queued(ahead: 1), true),
            (.remoteParked(.parked), true)
        ]
    )
    func attachmentIsReadOnlyWhenItDecides(status: AdFreePassQueueEpisodeStatus, isCurrent: Bool) {
        var reads = 0
        _ = EpisodeDetectAdsMenuState(
            queueStatus: status,
            hasCurrentCompletedAnalysis: isCurrent,
            isAnalysisAttached: {
                reads += 1
                return true
            }()
        )
        #expect(reads == 0)
    }

    @Test("Detect Ads titles and enablement match the settled copy")
    func detectAdsTitlesAndEnablement() {
        #expect(EpisodeDetectAdsMenuState.detect.title == "Detect Ads")
        #expect(EpisodeDetectAdsMenuState.detect.isEnabled)
        #expect(EpisodeDetectAdsMenuState.detecting.title == "Detecting…")
        #expect(!EpisodeDetectAdsMenuState.detecting.isEnabled)
        #expect(EpisodeDetectAdsMenuState.queued.title == "Queued")
        #expect(!EpisodeDetectAdsMenuState.queued.isEnabled)
        #expect(EpisodeDetectAdsMenuState.detected.title == "Ads Detected")
        #expect(!EpisodeDetectAdsMenuState.detected.isEnabled)
        #expect(EpisodeDetectAdsMenuState.detectAgain.title == "Detect Ads Again")
        #expect(EpisodeDetectAdsMenuState.detectAgain.isEnabled)
    }

    @Test("Episode Actions offers Detect Ads Again only while detached, and Detect Ads Only only for Detect Ads")
    func episodeActionsItems() {
        let all: [EpisodeDetectAdsMenuState] = [.detect, .detecting, .queued, .detected, .detectAgain]
        #expect(all.filter(\.offersDetectAgain) == [.detectAgain])
        #expect(all.filter(\.enablesAnalysisOnly) == [.detect])
    }

    @Test("Make Ad-Free reads a value for every state; a detached analysis reads that its skips are unavailable")
    func makeAdFreeAccessibilityValues() {
        let values = [EpisodeDetectAdsMenuState.detect, .detecting, .queued, .detected, .detectAgain]
            .map(EpisodeActionBar.makeAdFreeAccessibilityValue(for:))
        #expect(values == ["", "In progress", "Queued", "Ads detected", "Ad skips unavailable"])
    }

    @Test("Download action hides when downloaded and disables while downloading")
    func downloadMenuStateVisibilityTable() {
        #expect(EpisodeDownloadMenuState.available.showsDownloadAction)
        #expect(EpisodeDownloadMenuState.available.isDownloadActionEnabled)
        #expect(EpisodeDownloadMenuState.downloading.showsDownloadAction)
        #expect(!EpisodeDownloadMenuState.downloading.isDownloadActionEnabled)
        #expect(!EpisodeDownloadMenuState.downloaded.showsDownloadAction)
    }
}
