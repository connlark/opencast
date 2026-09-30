import Foundation

enum AppRoute: Hashable {
    /// `episodeListOverride` opens the show's episode list under the Inbox's
    /// filter and Hide Up Next for this visit only, so a Group by Podcast tap
    /// lists the episodes the group counted. Nil keeps the show's own
    /// stored filter.
    case podcastDetail(feedURL: String, episodeListOverride: PodcastEpisodeListOverride? = nil)
    case episodeDetail(id: String)
    case episodeArtwork(id: String)
    case episodeTranscript(id: String)
    case adDetectionQueue
    case settings(SettingsRoute)
}
