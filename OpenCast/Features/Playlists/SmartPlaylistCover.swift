import SwiftUI

/// A smart playlist's cover, drawn from the shows its rule matches. Like the
/// collection's summary line, it reads the evaluation itself through the app
/// model's memo, so only visible covers evaluate and the screens around them
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
