import Foundation
import OpenCastCore

enum DirectoryFeedChoicePreviewSamples {
    static let promoted = makePendingChoice(reason: .fullerFeedPromoted)
    static let stale = makePendingChoice(reason: .fullerFeedStale)
    static let salvaged = makePendingChoice(reason: .fullerFeedSalvaged)

    private static let newestEpisodeDate = Date(timeIntervalSince1970: 1_781_744_400)
    private static let appleURL = URL(string: "https://feeds.example.com/serial")!
    private static let podcastIndexURL = URL(
        string: "https://full-archive-for-serial.feeds.podcast-hosting.example.com/archive.xml"
    )!

    private static func makePendingChoice(
        reason: DirectoryFeedChoice.Reason
    ) -> DirectorySubscriptionFlowStore.PendingChoice {
        let apple = resolvedCandidate(
            source: .apple,
            feedURL: appleURL,
            episodeCount: 33
        )
        let fuller = resolvedCandidate(
            source: .podcastIndex,
            feedURL: podcastIndexURL,
            episodeCount: 124,
            isSalvaged: reason == .fullerFeedSalvaged,
            newestEpisodeDate: reason == .fullerFeedStale
                ? newestEpisodeDate.addingTimeInterval(-45 * 24 * 60 * 60)
                : newestEpisodeDate
        )
        let choice = switch reason {
        case .fullerFeedPromoted:
            DirectoryFeedChoice(primary: fuller, secondary: apple, reason: reason)
        case .fullerFeedStale, .fullerFeedSalvaged:
            DirectoryFeedChoice(primary: apple, secondary: fuller, reason: reason)
        }
        let result = DirectoryPodcastResult(
            id: "apple:917918570",
            title: "Serial",
            artistName: "Serial Productions",
            feedURL: appleURL,
            appleID: 917_918_570,
            sources: [.apple, .podcastIndex],
            feedCandidates: [apple.candidate, fuller.candidate]
        )
        return DirectorySubscriptionFlowStore.PendingChoice(result: result, choice: choice)
    }

    private static func resolvedCandidate(
        source: PodcastDirectorySource,
        feedURL: URL,
        episodeCount: Int,
        isSalvaged: Bool = false,
        newestEpisodeDate: Date = DirectoryFeedChoicePreviewSamples.newestEpisodeDate
    ) -> ResolvedFeedCandidate {
        let podcastID = PodcastID(rawValue: feedURL.absoluteString)
        let podcast = Podcast(id: podcastID, feedURL: feedURL, title: "Serial")
        let episodes = (0..<episodeCount).map { index in
            Episode(
                id: EpisodeID(rawValue: "preview-\(source.rawValue)-\(index)"),
                podcastID: podcastID,
                podcastTitle: podcast.title,
                title: "Episode \(index + 1)",
                publishedAt: index == 0 ? newestEpisodeDate : nil
            )
        }
        return ResolvedFeedCandidate(
            candidate: DirectoryFeedCandidate(source: source, feedURL: feedURL),
            snapshot: FeedSnapshot(
                podcast: podcast,
                episodes: episodes,
                isSalvaged: isSalvaged
            )
        )
    }
}
