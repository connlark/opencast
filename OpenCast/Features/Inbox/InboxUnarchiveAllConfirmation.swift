import SwiftData

/// Unarchive All's confirmation, the archive view's counterpart of
/// `InboxArchiveAllConfirmation`, taken when the dialog opens: the group's
/// rows that were archived then. The message counts them and confirming
/// returns them to the Inbox, so the dialog unarchives what it showed. The
/// app model still drops any that were unarchived since, and a row archived
/// meanwhile is never added.
struct InboxUnarchiveAllConfirmation {
    let podcastTitle: String
    let episodes: [EpisodeListItemSnapshot]

    /// Nil when the group has nothing archived.
    init?(group: InboxPodcastGroup, appModel: OpenCastAppModel) {
        let episodes = appModel.unarchivableEpisodes(group.episodes)
        guard !episodes.isEmpty else {
            return nil
        }
        podcastTitle = group.subscription.title
        self.episodes = episodes
    }

    var message: String {
        let count = episodes.count == 1 ? "1 episode" : "\(episodes.count) episodes"
        return "\(count) of \(podcastTitle) will return to the Inbox."
    }

    @discardableResult
    func unarchive(appModel: OpenCastAppModel, modelContext: ModelContext) -> Bool {
        appModel.unarchiveEpisodes(episodes, modelContext: modelContext)
    }
}
