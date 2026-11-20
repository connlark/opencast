import SwiftData

/// Taken when the dialog opens, so confirming unarchives the rows its message counted and never
/// a row archived since.
struct InboxUnarchiveAllConfirmation {
    let podcastTitle: String
    let episodes: [EpisodeListItemSnapshot]

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
