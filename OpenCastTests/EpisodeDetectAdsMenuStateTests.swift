import Testing
@testable import OpenCast

@MainActor
@Suite("Episode context menu action states")
struct EpisodeDetectAdsMenuStateTests {
    @Test(
        "Detect Ads label follows the per-episode queue status",
        arguments: [
            (AdFreePassQueueEpisodeStatus.notQueued, false, true, EpisodeDetectAdsMenuState.detect),
            (.notQueued, true, true, .detected),
            (.notQueued, true, false, .detectAgain),
            (.running, true, true, .detecting),
            (.queued(ahead: 0), true, true, .queued),
            (.remoteParked(.parked), false, true, .queued),
            (.completed(zoneCount: 3), false, true, .detect),
            (.failed(message: "probe"), true, true, .detected),
            (.cloudUnavailable(message: "No credits."), false, false, .detect),
            (.keyRequired(.noKey), true, false, .detectAgain)
        ]
    )
    func detectAdsLabelFollowsQueueStatus(
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
