import Foundation

/// The token makes repeat requests for one episode unequal, so each one still fires.
nonisolated struct AddToPlaylistPresentationRequest: Equatable, Sendable {
    let episodeID: String
    let token: UUID
}
