import Foundation

/// Opens the Add Episodes list for one proposal. The excluded positions are
/// the proposal's episodes at the moment it was opened.
nonisolated struct PlaylistProposalAddEpisodesRequest: Hashable, Sendable {
    let draftID: UUID
    let query: String
    let excludedPositions: Set<Int>
}
