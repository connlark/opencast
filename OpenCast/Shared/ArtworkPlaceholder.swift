import SwiftUI

struct ArtworkPlaceholder: View {
    let title: String
    let imageURL: String?
    let displaySize: CGSize
    let cacheKind: ArtworkCacheKind
    let preview: ArtworkPreview?
    let onPreviewResolved: ((ArtworkPreview) -> Void)?

    @State private var imageState = ArtworkImageState()
    @Environment(\.displayScale) private var displayScale

    init(
        title: String,
        imageURL: String?,
        size: CGFloat,
        cacheKind: ArtworkCacheKind = .show,
        preview: ArtworkPreview? = nil,
        onPreviewResolved: ((ArtworkPreview) -> Void)? = nil
    ) {
        self.init(
            title: title,
            imageURL: imageURL,
            displaySize: CGSize(width: size, height: size),
            cacheKind: cacheKind,
            preview: preview,
            onPreviewResolved: onPreviewResolved
        )
    }

    init(
        title: String,
        imageURL: String?,
        displaySize: CGSize,
        cacheKind: ArtworkCacheKind = .show,
        preview: ArtworkPreview? = nil,
        onPreviewResolved: ((ArtworkPreview) -> Void)? = nil
    ) {
        self.title = title
        self.imageURL = imageURL
        self.displaySize = displaySize
        self.cacheKind = cacheKind
        self.preview = preview
        self.onPreviewResolved = onPreviewResolved
    }

    var body: some View {
        let request = artworkRequest

        ArtworkPlaceholderVisual(
            title: title,
            image: imageState.resolvedImage(for: request),
            preview: imageState.resolvedPreview(for: request, fallbackPreview: preview)
        )
            .frame(width: displaySize.width, height: displaySize.height)
            .clipShape(.rect(cornerRadius: 8))
            .accessibilityHidden(true)
            .task(id: request) {
                guard let resolvedPreview = await imageState.loadArtwork(for: request, cacheKind: cacheKind) else {
                    return
                }

                onPreviewResolved?(resolvedPreview)
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
