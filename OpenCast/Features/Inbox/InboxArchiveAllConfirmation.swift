import SwiftData

/// Archive All's confirmation, taken when the dialog opens: the group's
/// rows that were archivable then. The message counts them and confirming
/// archives them, so the dialog archives what it showed. The current
/// episode counts like any other row. The app model still drops any that
/// were archived since, and a row that became archivable meanwhile (one
/// unarchived elsewhere) is never added.
struct InboxArchiveAllConfirmation {
    let podcastTitle: String
    let episodes: [EpisodeListItemSnapshot]

    /// Nil when the group has nothing to archive.
    init?(group: InboxPodcastGroup, appModel: OpenCastAppModel) {
        let episodes = appModel.archivableEpisodes(group.episodes)
        guard !episodes.isEmpty else {
            return nil
        }
        podcastTitle = group.subscription.title
        self.episodes = episodes
    }

    var message: String {
        let count = episodes.count == 1 ? "1 episode" : "\(episodes.count) episodes"
        return "\(count) of \(podcastTitle) will leave the Inbox. Listening progress is unchanged."
    }

    @discardableResult
    func archive(appModel: OpenCastAppModel, modelContext: ModelContext) -> Bool {
        appModel.archiveEpisodes(episodes, modelContext: modelContext)
    }
}
