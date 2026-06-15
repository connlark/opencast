import Foundation

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
