import Foundation

/// `excludedPositions` is a snapshot from when the list opened.
nonisolated struct PlaylistProposalAddEpisodesRequest: Hashable, Sendable {
    let draftID: UUID
    let query: String
    let excludedPositions: Set<Int>
}
