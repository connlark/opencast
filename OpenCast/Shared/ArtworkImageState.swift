import Observation
import SwiftUI

@Observable
final class ArtworkImageState {
    private(set) var loadedImage: UIImage?
    private(set) var loadedRequest: ArtworkRequest?
    private(set) var loadedPreview: ArtworkPreview?

    func resolvedImage(for request: ArtworkRequest?) -> UIImage? {
        guard let request else {
            return nil
        }

        if loadedRequest == request, let loadedImage {
            return loadedImage
        }

        return ArtworkLoader.shared.bestCachedImage(for: request)
    }

    func resolvedPreview(for request: ArtworkRequest?, fallbackPreview: ArtworkPreview?) -> ArtworkPreview? {
        guard let request else {
            return fallbackPreview
        }

        if loadedRequest == request, let loadedPreview {
            return loadedPreview
        }

        return fallbackPreview
    }

    func loadArtwork(for request: ArtworkRequest?, cacheKind: ArtworkCacheKind = .show) async -> ArtworkPreview? {
        guard let request else {
            loadedRequest = nil
            loadedImage = nil
            loadedPreview = nil
            return nil
        }

        if let cachedImage = ArtworkLoader.shared.bestCachedImage(for: request) {
            loadedRequest = request
            loadedImage = cachedImage
            loadedPreview = nil
        }

        do {
            guard let result = try await ArtworkLoader.shared.loadResult(for: request, cacheKind: cacheKind) else {
                return nil
            }

            try Task.checkCancellation()
            loadedRequest = request
            loadedImage = result.image
            loadedPreview = result.preview
            return result.preview
        } catch is CancellationError {
            return nil
        } catch {
            // Decorative artwork failures leave the generated initials placeholder visible.
            return nil
        }
    }
}
