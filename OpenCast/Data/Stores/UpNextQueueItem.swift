import Foundation

struct UpNextQueueItem: Identifiable, Equatable {
    var id: String { episodeID }

    let episodeID: String
    let podcastID: String
    var sequence: Int
    let enqueuedAt: Date
}
