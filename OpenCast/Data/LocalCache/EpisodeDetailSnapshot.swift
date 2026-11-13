import Foundation

nonisolated struct EpisodeDetailSnapshot: Identifiable, Equatable, Sendable {
    var listItem: EpisodeListItemSnapshot
    let showNotesHTML: String?
    /// The declared `podcast:chapters` document URL; detail-only like show
    /// notes. A declaration suppresses generated chapters unless this device
    /// has read the document and found nothing usable in it
    /// (`PublisherChaptersStore.isDocumentKnownEmpty`).
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
