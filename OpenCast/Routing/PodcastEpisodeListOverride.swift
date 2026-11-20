/// For one visit only: nothing here is written to the show's own stored
/// settings.
nonisolated struct PodcastEpisodeListOverride: Hashable, Sendable {
    var filter: PodcastEpisodeFilter
    var hidesQueuedEpisodes: Bool
    var archiveScope = PodcastEpisodeArchiveScope.all
}
