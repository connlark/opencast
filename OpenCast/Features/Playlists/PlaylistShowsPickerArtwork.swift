import SwiftUI

/// A show's 40-point rounded artwork in the Shows and Priority pickers.
struct PlaylistShowsPickerArtwork: View {
    @Environment(OpenCastAppModel.self) private var appModel

    let show: SubscriptionRecord

    var body: some View {
        let podcastCache = appModel.library.podcastCache(for: show.feedURL)
        ArtworkPlaceholder(
            title: show.title,
            imageURL: podcastCache?.artworkURL ?? show.artworkURL,
            size: 40,
            preview: podcastCache.flatMap { appModel.library.artworkPreview(for: $0) }
        )
        .clipShape(.rect(cornerRadius: 8))
    }
}
