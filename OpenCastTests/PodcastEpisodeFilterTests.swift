import Foundation
import Testing
@testable import OpenCast

@MainActor
@Suite("Podcast episode filter")
struct PodcastEpisodeFilterTests {
    private let notStarted = EpisodeProgressSummary(
        position: 0,
        duration: 100,
        fractionCompleted: 0,
        remaining: 100,
        isCompleted: false
    )
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

    @Test("All Episodes includes every episode")
    func allIncludesEverything() {
        for progress in [notStarted, inProgress, completed] {
            #expect(PodcastEpisodeFilter.all.includes(progress: progress, isDownloaded: false))
            #expect(PodcastEpisodeFilter.all.includes(progress: progress, isDownloaded: true))
        }
    }

    @Test("Unplayed and Played split on completion and ignore downloads")
    func unplayedAndPlayedSplitOnCompletion() {
        for isDownloaded in [false, true] {
            #expect(PodcastEpisodeFilter.unplayed.includes(progress: notStarted, isDownloaded: isDownloaded))
            #expect(PodcastEpisodeFilter.unplayed.includes(progress: inProgress, isDownloaded: isDownloaded))
            #expect(!PodcastEpisodeFilter.unplayed.includes(progress: completed, isDownloaded: isDownloaded))

            #expect(!PodcastEpisodeFilter.played.includes(progress: notStarted, isDownloaded: isDownloaded))
            #expect(!PodcastEpisodeFilter.played.includes(progress: inProgress, isDownloaded: isDownloaded))
            #expect(PodcastEpisodeFilter.played.includes(progress: completed, isDownloaded: isDownloaded))
        }
    }

    @Test("In Progress needs visible progress")
    func inProgressNeedsVisibleProgress() {
        // Under a second of playback is not visible progress.
        let barelyStarted = EpisodeProgressSummary(
            position: 0.5,
            duration: 100,
            fractionCompleted: 0.005,
            remaining: 99.5,
            isCompleted: false
        )

        #expect(PodcastEpisodeFilter.inProgress.includes(progress: inProgress, isDownloaded: false))
        #expect(!PodcastEpisodeFilter.inProgress.includes(progress: notStarted, isDownloaded: true))
        #expect(!PodcastEpisodeFilter.inProgress.includes(progress: barelyStarted, isDownloaded: true))
        #expect(!PodcastEpisodeFilter.inProgress.includes(progress: completed, isDownloaded: true))
    }

    @Test("Downloaded ignores progress")
    func downloadedIgnoresProgress() {
        for progress in [notStarted, inProgress, completed] {
            #expect(PodcastEpisodeFilter.downloaded.includes(progress: progress, isDownloaded: true))
            #expect(!PodcastEpisodeFilter.downloaded.includes(progress: progress, isDownloaded: false))
        }
    }

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

    @Test("Inbox empty-state copy is show-neutral")
    func inboxEmptyStateCopy() {
        for filter in PodcastEpisodeFilter.allCases {
            let description = filter.inboxEmptyStateDescription
            #expect(!description.isEmpty)
            #expect(!description.localizedStandardContains("this podcast"))
            #expect(!filter.emptyStateTitle.isEmpty)
        }
        #expect(PodcastEpisodeFilter.all.inboxEmptyStateDescription.contains("Inbox"))
        #expect(PodcastEpisodeFilter.unplayed.inboxEmptyStateDescription.contains("Inbox"))
    }

    /// Stands in for an input the filter must not read; reading it fails the test.
    private func unreached<Value>(_ input: String, fallback: Value) -> Value {
        Issue.record("\(input) was read")
        return fallback
    }
}
