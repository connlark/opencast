import SwiftUI

/// Reads the evaluation itself, so only visible covers evaluate and the screens around them
/// observe no smart-list dependencies.
struct SmartPlaylistCover: View {
    @Environment(OpenCastAppModel.self) private var appModel

    let summary: PlaylistSummary
    let cornerRadius: Double

    var body: some View {
        let sources = SmartPlaylistCoverSources.make(
            episodes: appModel.smartPlaylistEvaluation(for: summary).episodes,
            podcastArtworkURL: podcastArtworkURL
        )
        PlaylistCardStackCover(
            artworkURLs: sources.artworkURLs,
            fallbackTitle: summary.name,
            tint: summary.tint ?? .blue,
            symbolName: nil,
            cornerRadius: cornerRadius
        )
    }

    private func podcastArtworkURL(for podcastID: String) -> URL? {
        appModel.library.podcastCache(for: podcastID)?.artworkURL.flatMap(URL.init(string:))
    }
}
