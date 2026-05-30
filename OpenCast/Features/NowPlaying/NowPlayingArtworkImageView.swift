import SwiftUI

struct NowPlayingArtworkImageView: View {
    let title: String
    let image: UIImage?

    var body: some View {
        ArtworkPlaceholderVisual(title: title, image: image)
            .accessibilityHidden(true)
    }
}
