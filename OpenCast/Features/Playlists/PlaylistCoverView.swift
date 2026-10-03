import SwiftUI

/// A playlist's cover for its kind: the shows' mosaic for a manual playlist,
/// the matched shows' card stack for a smart one. It fills the square it is
/// offered; callers set the size, corner radius and any shadow.
struct PlaylistCoverView: View {
    let summary: PlaylistSummary
    /// The manual mosaic's shows. A smart cover reads its own from the
    /// playlist's evaluation, so callers pass a smart playlist's (empty)
    /// item sources unchanged.
    let sources: PlaylistCoverSources
    let cornerRadius: Double

    var body: some View {
        switch summary.kind {
        case .manual:
            PlaylistArtworkMosaic(sources: sources, cornerRadius: cornerRadius)
        case .smart:
            SmartPlaylistCover(summary: summary, cornerRadius: cornerRadius)
        }
    }
}
