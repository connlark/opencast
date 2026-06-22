import Foundation

nonisolated struct RemoteEpisodeNotificationRoute: Sendable, Equatable {
    let feedURL: String
    let episodeID: String
    let episodeTitle: String?

    init(
        feedURL: String,
        episodeID: String,
        episodeTitle: String? = nil
    ) {
        self.feedURL = feedURL
        self.episodeID = episodeID
        self.episodeTitle = episodeTitle
    }
}
