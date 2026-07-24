import Foundation
import OpenCastCore

nonisolated struct EpisodeListItemSnapshot: Identifiable, Equatable, Sendable {
    let episodeID: String
    let podcastID: String
    let podcastTitle: String
    let title: String
    let summary: String?
    let publishedAt: Date?
    let duration: TimeInterval?
    let audioURL: String?
    let artworkURL: String?
    var artworkPreview: ArtworkPreview?
    let guid: String?
    let cachedAt: Date

    var id: String {
        episodeID
    }

    init(
        episodeID: String,
        podcastID: String,
        podcastTitle: String,
        title: String,
        summary: String?,
        publishedAt: Date?,
        duration: TimeInterval?,
        audioURL: String?,
        artworkURL: String?,
        artworkPreview: ArtworkPreview?,
        guid: String?,
        cachedAt: Date
    ) {
        self.episodeID = episodeID
        self.podcastID = podcastID
        self.podcastTitle = podcastTitle
        self.title = title
        self.summary = summary
        self.publishedAt = publishedAt
        self.duration = duration
        self.audioURL = audioURL
        self.artworkURL = artworkURL
        self.artworkPreview = artworkPreview
        self.guid = guid
        self.cachedAt = cachedAt
    }

    init(episode: Episode, cachedAt: Date = .now) {
        self.init(
            episodeID: episode.id.rawValue,
            podcastID: episode.podcastID.rawValue,
            podcastTitle: episode.podcastTitle,
            title: episode.title,
            summary: episode.summary,
            publishedAt: episode.publishedAt,
            duration: episode.duration,
            audioURL: episode.audioURL?.absoluteString,
            artworkURL: episode.artworkURL?.absoluteString,
            artworkPreview: nil,
            guid: episode.guid,
            cachedAt: cachedAt
        )
    }

    init(downloadRecord: EpisodeDownloadRecord, podcastCache: PodcastCacheSnapshot?) {
        self.init(
            episodeID: downloadRecord.episodeID,
            podcastID: downloadRecord.podcastID,
            podcastTitle: Self.nonempty(downloadRecord.podcastTitle) ?? podcastCache?.title ?? "Removed Podcast",
            title: Self.nonempty(downloadRecord.episodeTitle)
                ?? Self.humanizedAudioTitle(downloadRecord.sourceAudioURL),
            summary: nil,
            publishedAt: downloadRecord.publishedAt,
            duration: downloadRecord.duration,
            audioURL: Self.nonempty(downloadRecord.sourceAudioURL),
            artworkURL: Self.nonempty(downloadRecord.artworkURLString) ?? podcastCache?.artworkURL,
            artworkPreview: podcastCache?.artworkPreview,
            guid: nil,
            cachedAt: downloadRecord.updatedAt
        )
    }

    static func newestFirst(_ lhs: EpisodeListItemSnapshot, _ rhs: EpisodeListItemSnapshot) -> Bool {
        switch (lhs.publishedAt, rhs.publishedAt) {
        case let (lhsDate?, rhsDate?):
            lhsDate > rhsDate
        case (.some, .none):
            true
        case (.none, .some):
            false
        case (.none, .none):
            lhs.title.localizedStandardCompare(rhs.title) == .orderedAscending
        }
    }

    static func oldestFirst(_ lhs: EpisodeListItemSnapshot, _ rhs: EpisodeListItemSnapshot) -> Bool {
        switch (lhs.publishedAt, rhs.publishedAt) {
        case let (lhsDate?, rhsDate?):
            if lhsDate != rhsDate {
                return lhsDate < rhsDate
            }
            return sortsByTitleThenEpisodeID(lhs, rhs)
        case (.some, .none):
            return true
        case (.none, .some):
            return false
        case (.none, .none):
            return sortsByTitleThenEpisodeID(lhs, rhs)
        }
    }

    static func longestFirst(_ lhs: EpisodeListItemSnapshot, _ rhs: EpisodeListItemSnapshot) -> Bool {
        switch (lhs.sortableDuration, rhs.sortableDuration) {
        case let (lhsDuration?, rhsDuration?):
            if lhsDuration != rhsDuration {
                return lhsDuration > rhsDuration
            }
            return sortsByNewestFirstThenEpisodeID(lhs, rhs)
        case (.some, .none):
            return true
        case (.none, .some):
            return false
        case (.none, .none):
            return sortsByNewestFirstThenEpisodeID(lhs, rhs)
        }
    }

    static func shortestFirst(_ lhs: EpisodeListItemSnapshot, _ rhs: EpisodeListItemSnapshot) -> Bool {
        switch (lhs.sortableDuration, rhs.sortableDuration) {
        case let (lhsDuration?, rhsDuration?):
            if lhsDuration != rhsDuration {
                return lhsDuration < rhsDuration
            }
            return sortsByNewestFirstThenEpisodeID(lhs, rhs)
        case (.some, .none):
            return true
        case (.none, .some):
            return false
        case (.none, .none):
            return sortsByNewestFirstThenEpisodeID(lhs, rhs)
        }
    }

    private var sortableDuration: TimeInterval? {
        guard let duration, duration > 0 else {
            return nil
        }
        return duration
    }

    private static func nonempty(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
            return nil
        }

        return value
    }

    private static func humanizedAudioTitle(_ sourceAudioURL: String) -> String {
        guard let url = URL(string: sourceAudioURL),
              let decodedName = url.deletingPathExtension().lastPathComponent.removingPercentEncoding
        else {
            return "Downloaded Episode"
        }

        let words = decodedName
            .replacing("-", with: " ")
            .replacing("_", with: " ")
            .split(whereSeparator: \Character.isWhitespace)
            .joined(separator: " ")
        return words.isEmpty ? "Downloaded Episode" : words.capitalized
    }

    private static func sortsByTitleThenEpisodeID(
        _ lhs: EpisodeListItemSnapshot,
        _ rhs: EpisodeListItemSnapshot
    ) -> Bool {
        let titleComparison = lhs.title.localizedStandardCompare(rhs.title)
        if titleComparison != .orderedSame {
            return titleComparison == .orderedAscending
        }
        return lhs.episodeID < rhs.episodeID
    }

    private static func sortsByNewestFirstThenEpisodeID(
        _ lhs: EpisodeListItemSnapshot,
        _ rhs: EpisodeListItemSnapshot
    ) -> Bool {
        if newestFirst(lhs, rhs) {
            return true
        }
        if newestFirst(rhs, lhs) {
            return false
        }
        return lhs.episodeID < rhs.episodeID
    }
}
