import Foundation

nonisolated struct EpisodeDetailSnapshot: Identifiable, Equatable, Sendable {
    var listItem: EpisodeListItemSnapshot
    let showNotesHTML: String?
    var chaptersURL: String?

    var id: String {
        listItem.episodeID
    }

    init(
        listItem: EpisodeListItemSnapshot,
        showNotesHTML: String?,
        chaptersURL: String? = nil
    ) {
        self.listItem = listItem
        self.showNotesHTML = showNotesHTML
        self.chaptersURL = chaptersURL
    }
}
