import Foundation

struct AdFreePassQueueItem: Identifiable, Equatable {
    let episode: EpisodeListItemSnapshot
    let origin: AdFreePassQueueOrigin
    let enqueuedAt: Date
    let sequence: Int
    let mode: AdDetectionMode

    init(
        episode: EpisodeListItemSnapshot,
        origin: AdFreePassQueueOrigin,
        enqueuedAt: Date,
        sequence: Int,
        mode: AdDetectionMode = .onDevice
    ) {
        self.episode = episode
        self.origin = origin
        self.enqueuedAt = enqueuedAt
        self.sequence = sequence
        self.mode = mode
    }

    var id: String {
        episode.episodeID
    }

    var episodeID: String {
        episode.episodeID
    }
}
