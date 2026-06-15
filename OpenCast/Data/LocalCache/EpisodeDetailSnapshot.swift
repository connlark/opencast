import Foundation

nonisolated struct EpisodeDetailSnapshot: Identifiable, Equatable, Sendable {
    var listItem: EpisodeListItemSnapshot
    let showNotesHTML: String?

    var id: String {
        listItem.episodeID
    }
}
