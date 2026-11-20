import SwiftUI

struct PlaylistCoverView: View {
    let summary: PlaylistSummary
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
