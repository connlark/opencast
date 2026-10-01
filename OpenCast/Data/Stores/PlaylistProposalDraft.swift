import Foundation

/// One proposal as the sheet edits it, built once by validation.
nonisolated struct PlaylistProposalDraft: Identifiable, Equatable, Sendable {
    let id: UUID
    var title: String
    var rationale: String
    var episodes: [EpisodeListItemSnapshot]

    /// A draft the Save button would write: non-empty trimmed title and at least one episode.
    var isSaveable: Bool {
        !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !episodes.isEmpty
    }
}
