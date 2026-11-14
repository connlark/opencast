/// Which of a show's episodes a Group by Podcast visit lists by archive
/// state: the Inbox view hides the archived ones, the archive view lists
/// only them.
nonisolated enum PodcastEpisodeArchiveScope: Hashable, Sendable {
    /// Archived or not, as a show opened any other way lists them.
    case all
    case hidingArchived
    case onlyArchived
}
