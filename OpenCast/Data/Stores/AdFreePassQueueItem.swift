import Foundation

struct AdFreePassQueueItem: Identifiable, Equatable {
    let episode: EpisodeListItemSnapshot
    let origin: AdFreePassQueueOrigin
    let enqueuedAt: Date
    let sequence: Int

    var id: String {
        episode.episodeID
    }

    var episodeID: String {
        episode.episodeID
    }
}
