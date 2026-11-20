import SwiftData

/// Taken when the dialog opens, so confirming archives the rows its message counted and never a
/// row that became archivable since.
struct InboxArchiveAllConfirmation {
    let podcastTitle: String
    let episodes: [EpisodeListItemSnapshot]

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
