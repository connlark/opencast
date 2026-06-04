import SwiftUI

final class NowPlayingArtworkPlaceholderImageFactory {
    static let shared = NowPlayingArtworkPlaceholderImageFactory()

    private let cache = NSCache<NSString, UIImage>()

    private init() {
        cache.countLimit = 32
    }

    func image(title: String, size: CGSize, scale: CGFloat) -> UIImage {
        let pixelWidth = max(Int((size.width * scale).rounded(.up)), 1)
        let pixelHeight = max(Int((size.height * scale).rounded(.up)), 1)
        let cacheKey = "\(title)|\(pixelWidth)x\(pixelHeight)@\(scale)" as NSString
        if let cachedImage = cache.object(forKey: cacheKey) {
            return cachedImage
        }

        let renderer = ImageRenderer(
            content: ArtworkPlaceholderVisual(title: title, image: nil, preview: nil)
                .frame(width: size.width, height: size.height)
                .clipShape(.rect(cornerRadius: 8))
        )
        renderer.scale = scale
        renderer.isOpaque = true

        guard let image = renderer.uiImage else {
            return UIImage()
        }

        cache.setObject(image, forKey: cacheKey)
        return image
    }
}
