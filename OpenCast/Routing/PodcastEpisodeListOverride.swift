/// Inbox list settings carried into a show's episode list for one visit: a
/// Group by Podcast tap opens the show listing the episodes the group
/// counted. Nothing here is written to the show's own stored settings.
nonisolated struct PodcastEpisodeListOverride: Hashable, Sendable {
    var filter: PodcastEpisodeFilter
    var hidesQueuedEpisodes: Bool
    /// The view the group came from: the Inbox hides archived episodes, the
    /// archive lists only them. A show opened any other way lists both.
    var archiveScope = PodcastEpisodeArchiveScope.all
}
