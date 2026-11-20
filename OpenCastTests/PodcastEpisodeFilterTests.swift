import Foundation
import Testing
@testable import OpenCast

@MainActor
@Suite("Podcast episode filter")
struct PodcastEpisodeFilterTests {
    private let inProgress = EpisodeProgressSummary(
        position: 20,
        duration: 100,
        fractionCompleted: 0.2,
        remaining: 80,
        isCompleted: false
    )
    private let completed = EpisodeProgressSummary(
        position: 100,
        duration: 100,
        fractionCompleted: 1,
        remaining: 0,
        isCompleted: true
    )

    @Test("Each filter evaluates only the input it needs")
    func filtersEvaluateOnlyTheirInput() {
        // The calls stay outside `#expect`, which would evaluate every
        // argument itself to capture it for the failure message.
        let allIncludes = PodcastEpisodeFilter.all.includes(
            progress: unreached("progress", fallback: completed),
            isDownloaded: unreached("download state", fallback: false)
        )
        #expect(allIncludes)
        for filter in [PodcastEpisodeFilter.unplayed, .inProgress, .played] {
            _ = filter.includes(
                progress: inProgress,
                isDownloaded: unreached("download state", fallback: false)
            )
        }
        let downloadedIncludes = PodcastEpisodeFilter.downloaded.includes(
            progress: unreached("progress", fallback: completed),
            isDownloaded: true
        )
        #expect(downloadedIncludes)
    }

    private func unreached<Value>(_ input: String, fallback: Value) -> Value {
        Issue.record("\(input) was read")
        return fallback
    }
}
