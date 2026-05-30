import Foundation
@preconcurrency import MediaPlayer
import OpenCastPlayback
import SwiftUI

// NSCache synchronizes storage; MemoryWarningObserver only stores its token for deinit removal.
nonisolated final class SharedNowPlayingArtworkLoader: NowPlayingArtworkLoading, @unchecked Sendable {
    private let artworkLoader: ArtworkLoader
    private let targetPixelSize: CGSize
    private let cache = NSCache<NSString, MPMediaItemArtwork>()
    private var memoryWarningObserver: MemoryWarningObserver?

    init(
        artworkLoader: ArtworkLoader = .shared,
        targetPixelSize: CGSize = CGSize(width: 1_024, height: 1_024),
        notificationCenter: NotificationCenter = .default,
        memoryWarningName: Notification.Name? = UIApplication.didReceiveMemoryWarningNotification
    ) {
        self.artworkLoader = artworkLoader
        self.targetPixelSize = targetPixelSize
        cache.countLimit = 16

        memoryWarningObserver = MemoryWarningObserver(
            notificationCenter: notificationCenter,
            name: memoryWarningName
        ) { [weak self] in
            self?.removeCachedArtwork()
        }
    }

    func removeCachedArtwork() {
        cache.removeAllObjects()
    }

    func cachedArtwork(for url: URL) -> MPMediaItemArtwork? {
        let request = ArtworkRequest(url: url, targetPixelSize: targetPixelSize)
        if let cachedArtwork = cache.object(forKey: request.imageKey as NSString) {
            return cachedArtwork
        }

        guard let image = artworkLoader.bestCachedImage(for: request) else {
            return nil
        }

        let artwork = Self.makeArtwork(from: image)
        cache.setObject(artwork, forKey: request.imageKey as NSString)
        return artwork
    }

    func artwork(for url: URL) async throws -> MPMediaItemArtwork {
        let request = ArtworkRequest(url: url, targetPixelSize: targetPixelSize)
        if let cachedArtwork = cache.object(forKey: request.imageKey as NSString) {
            return cachedArtwork
        }

        guard let image = try await artworkLoader.image(for: request, cacheKind: .episode) else {
            throw SharedNowPlayingArtworkError.missingImage
        }

        let artwork = Self.makeArtwork(from: image)
        cache.setObject(artwork, forKey: request.imageKey as NSString)
        return artwork
    }

    private nonisolated static func makeArtwork(from image: UIImage) -> MPMediaItemArtwork {
        MPMediaItemArtwork(boundsSize: image.size) { _ in
            image
        }
    }
}
