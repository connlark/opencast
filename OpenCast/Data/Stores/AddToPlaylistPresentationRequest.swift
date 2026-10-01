import Foundation

/// Asks the root to present the Add to Playlist sheet. The token makes two
/// requests for the same episode distinct, so a repeat request still fires
/// the root's change observer.
nonisolated struct AddToPlaylistPresentationRequest: Equatable, Sendable {
    let episodeID: String
    let token: UUID
}
