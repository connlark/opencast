import Foundation

nonisolated struct PlaylistProposalDraft: Identifiable, Equatable, Sendable {
    let id: UUID
    var title: String
    var rationale: String
    var episodes: [EpisodeListItemSnapshot]

    var isSaveable: Bool {
        !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !episodes.isEmpty
    }
}
