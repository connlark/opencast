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
}
