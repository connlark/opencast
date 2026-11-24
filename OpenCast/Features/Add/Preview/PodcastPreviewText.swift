import Foundation
import OpenCastCore

enum PodcastPreviewText {
    static func rhythmLine(_ digest: FeedDigest) -> String? {
        guard let newest = digest.newestPublishedAt else {
            return nil
        }
        if digest.isStopped {
            return "Nothing since \(newest.formatted(.dateTime.month(.wide).year()))"
        }
        let newestText = PodcastPreviewAge(of: newest).newestText
        guard let cadence = digest.cadence else {
            return newestText
        }
        return "\(cadenceTitle(cadence)) · \(newestText)"
    }

    static func countLine(_ feed: PodcastPreviewFeed) -> String {
        let count = episodeCount(feed.candidate)
        guard feed.digest.isStopped, let span = yearSpan(feed.digest) else {
            return count
        }
        return "\(count) · \(span)"
    }

    static func feedMenuTitle(_ feed: PodcastPreviewFeed, in feeds: PodcastPreviewFeeds) -> String {
        let count = feed.candidate.episodeCount.formatted()
        let amount = feed.candidate.isSalvaged ? "at least \(count)" : count
        let isFullArchive = (feed.id == feeds.recommended.id) == (feeds.reason == .fullerFeedPromoted)
        guard isFullArchive else {
            return "Recent episodes only, \(amount)"
        }
        let archive = "Full archive, \(amount) episodes"
        return feeds.reason == .fullerFeedStale ? "\(archive), no longer updating" : archive
    }

    static func episodeCaption(_ episode: Episode) -> String {
        let age = episode.publishedAt.map { PodcastPreviewAge(of: $0).episodeText }
        let duration = episode.duration
            .flatMap { Int64(exactly: $0.rounded()) }
            .map(durationText)
        return [age, duration].compactMap(\.self).joined(separator: " · ")
    }

    private static func durationText(_ seconds: Int64) -> String {
        let units: Set<Duration.UnitsFormatStyle.Unit> = seconds < 60 ? [.seconds] : [.hours, .minutes]
        return Duration.seconds(seconds).formatted(.units(allowed: units, width: .abbreviated))
    }

    private static func cadenceTitle(_ cadence: FeedCadence) -> String {
        switch cadence {
        case .daily: "Daily"
        case .weekly: "Weekly"
        case .everyTwoWeeks: "Every two weeks"
        case .monthly: "Monthly"
        }
    }

    private static func episodeCount(_ candidate: ResolvedFeedCandidate) -> String {
        let count = candidate.episodeCount
        let text = "\(count.formatted()) \(count == 1 ? "episode" : "episodes")"
        return candidate.isSalvaged ? "At least \(text)" : text
    }

    private static func yearSpan(_ digest: FeedDigest) -> String? {
        guard let newest = digest.newestPublishedAt else {
            return nil
        }
        let newestYear = newest.formatted(.dateTime.year())
        guard let oldestYear = digest.oldestPublishedAt?.formatted(.dateTime.year()), oldestYear != newestYear else {
            return newestYear
        }
        return "\(oldestYear)–\(newestYear)"
    }
}
