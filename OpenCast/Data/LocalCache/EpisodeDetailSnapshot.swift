import Foundation

nonisolated struct EpisodeDetailSnapshot: Identifiable, Equatable, Sendable {
    var listItem: EpisodeListItemSnapshot
    let showNotesHTML: String?
    /// Feed-declared `podcast:chapters` URL; detail-only like show notes.
    /// Presence suppresses generated chapters (creator metadata wins).
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
