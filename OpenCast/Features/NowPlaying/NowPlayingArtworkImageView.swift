import SwiftUI

struct NowPlayingArtworkImageView: View {
    let title: String
    let image: UIImage?

    var body: some View {
        ZStack {
            Color.black
            ArtworkPlaceholderVisual(title: title, image: image, preview: nil)
        }
            .accessibilityHidden(true)
    }
}
