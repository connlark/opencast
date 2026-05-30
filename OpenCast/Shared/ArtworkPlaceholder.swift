import SwiftUI

struct ArtworkPlaceholder: View {
    let title: String
    let imageURL: String?
    let displaySize: CGSize
    let cacheKind: ArtworkCacheKind

    @State private var imageState = ArtworkImageState()
    @Environment(\.displayScale) private var displayScale

    init(title: String, imageURL: String?, size: CGFloat, cacheKind: ArtworkCacheKind = .show) {
        self.title = title
        self.imageURL = imageURL
        displaySize = CGSize(width: size, height: size)
        self.cacheKind = cacheKind
    }

    init(title: String, imageURL: String?, displaySize: CGSize, cacheKind: ArtworkCacheKind = .show) {
        self.title = title
        self.imageURL = imageURL
        self.displaySize = displaySize
        self.cacheKind = cacheKind
    }

    var body: some View {
        let request = artworkRequest

        ArtworkPlaceholderVisual(title: title, image: imageState.resolvedImage(for: request))
            .frame(width: displaySize.width, height: displaySize.height)
            .clipShape(.rect(cornerRadius: 8))
            .accessibilityHidden(true)
            .task(id: request) {
                await imageState.loadArtwork(for: request, cacheKind: cacheKind)
            }
    }

    private var artworkURL: URL? {
        guard let imageURL else {
            return nil
        }

        return URL(string: imageURL)
    }

    private var targetPixelSize: CGSize {
        CGSize(
            width: displaySize.width * displayScale,
            height: displaySize.height * displayScale
        )
    }

    private var artworkRequest: ArtworkRequest? {
        guard let artworkURL else {
            return nil
        }

        return ArtworkRequest(url: artworkURL, targetPixelSize: targetPixelSize)
    }
}
