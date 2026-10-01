import SwiftUI

/// A playlist's cover for its kind: the shows' mosaic for a manual playlist,
/// the tinted symbol tile for a smart one. It fills the square it is
/// offered; callers set the size, corner radius and any shadow.
struct PlaylistCoverView: View {
    let summary: PlaylistSummary
    let sources: PlaylistCoverSources
    let cornerRadius: Double

    var body: some View {
        switch summary.kind {
        case .manual:
            PlaylistArtworkMosaic(sources: sources, cornerRadius: cornerRadius)
        case .smart:
            PlaylistSymbolCover(
                tint: summary.tint ?? .blue,
                symbolName: summary.symbolName,
                cornerRadius: cornerRadius
            )
        }
    }
}
