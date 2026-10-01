import AppIntents
import Foundation

nonisolated struct OpenCastPlaylistEntity: AppEntity {
    static var typeDisplayRepresentation: TypeDisplayRepresentation { "Playlist" }
    static let defaultQuery = OpenCastPlaylistQuery()

    let id: String
    let name: String
    let episodeCount: Int
    let episodeCountText: String
    let isSmart: Bool
    let updatedAt: Date

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(
            title: "\(name)",
            subtitle: "\(episodeCountText)",
            image: .init(systemName: "music.note.list")
        )
    }

    @MainActor
    init(summary: PlaylistSummary, episodeCount: Int) {
        id = summary.playlistID
        name = String(summary.name.prefix(512))
        self.episodeCount = episodeCount
        episodeCountText = PlaylistSummaryText.line(itemCount: episodeCount, totalDuration: 0)
        isSmart = summary.kind == .smart
        updatedAt = summary.updatedAt
    }

    /// Every playlist as an entity, most recently updated first (the store's
    /// array follows the collection's sort preference, so the order is made
    /// here), ties by id.
    @MainActor
    static func entities(
        for summaries: [PlaylistSummary],
        episodeCount: (PlaylistSummary) -> Int
    ) -> [OpenCastPlaylistEntity] {
        summaries.map { OpenCastPlaylistEntity(summary: $0, episodeCount: episodeCount($0)) }
            .sorted { ($0.updatedAt, $1.id) > ($1.updatedAt, $0.id) }
    }
}
