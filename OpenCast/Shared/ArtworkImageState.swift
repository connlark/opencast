import Observation
import SwiftUI

@Observable
final class ArtworkImageState {
    private(set) var loadedImage: UIImage?
    private(set) var loadedRequest: ArtworkRequest?

    func resolvedImage(for request: ArtworkRequest?) -> UIImage? {
        guard let request else {
            return nil
        }

        if loadedRequest == request, let loadedImage {
            return loadedImage
        }

        return ArtworkLoader.shared.bestCachedImage(for: request)
    }

    func loadArtwork(for request: ArtworkRequest?, cacheKind: ArtworkCacheKind = .show) async {
        guard let request else {
            loadedRequest = nil
            loadedImage = nil
            return
        }

        if let cachedImage = ArtworkLoader.shared.bestCachedImage(for: request) {
            loadedImage = cachedImage
        }

        do {
            guard let image = try await ArtworkLoader.shared.image(for: request, cacheKind: cacheKind) else {
                return
            }

            try Task.checkCancellation()
            loadedRequest = request
            loadedImage = image
        } catch is CancellationError {
            return
        } catch {
            // Decorative artwork failures leave the generated initials placeholder visible.
        }
    }
}
