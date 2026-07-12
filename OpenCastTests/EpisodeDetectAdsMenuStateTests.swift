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
            (.completed(zoneCount: 3), false, .detected),
            (.failed(message: "probe"), false, .detect),
            (.failed(message: "probe"), true, .detected),
            (.capDeferred, false, .queued)
        ]

        for (status, hasAnalysis, expected) in cases {
            let state = EpisodeDetectAdsMenuState(
                queueStatus: status,
                hasCurrentCompletedAnalysis: hasAnalysis
            )
            #expect(state == expected, "status \(status) hasAnalysis \(hasAnalysis)")
        }
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
