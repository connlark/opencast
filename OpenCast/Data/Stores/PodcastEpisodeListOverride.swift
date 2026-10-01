/// Inbox list settings carried into a show's episode list for one visit: a
/// Group by Podcast tap opens the show listing the episodes the group
/// counted. Nothing here is written to the show's own stored settings.
nonisolated struct PodcastEpisodeListOverride: Hashable, Sendable {
    let filter: PodcastEpisodeFilter
    let hidesQueuedEpisodes: Bool
}
