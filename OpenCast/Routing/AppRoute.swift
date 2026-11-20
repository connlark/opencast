import Foundation

enum AppRoute: Hashable {
    /// A nil `episodeListOverride` keeps the show's own stored filter.
    case podcastDetail(feedURL: String, episodeListOverride: PodcastEpisodeListOverride? = nil)
    case episodeDetail(id: String)
    case episodeArtwork(id: String)
    case episodeTranscript(id: String)
    case adDetectionQueue
    case playlists
    case playlistDetail(id: String)
    case notes
    case settings(SettingsRoute)
    case downloadSettings
    case downloadStorage
    case podcastDownloadSettings(feedURL: String)

    var isSettingsScreen: Bool {
        if case .settings = self {
            return true
        }
        return false
    }

    /// A show is the same screen whichever list settings it was opened under.
    func opensSameScreen(as other: AppRoute) -> Bool {
        switch (self, other) {
        case (.podcastDetail(let feedURL, _), .podcastDetail(let otherFeedURL, _)):
            feedURL == otherFeedURL
        default:
            self == other
        }
    }
}
