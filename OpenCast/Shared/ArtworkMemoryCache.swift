import SwiftUI

// NSCache synchronizes storage; MemoryWarningObserver only stores its token for deinit removal.
nonisolated final class ArtworkMemoryCache: @unchecked Sendable {
    private let exactCache = NSCache<NSString, UIImage>()
    private let latestImageCache = NSCache<NSString, UIImage>()
    private var memoryWarningObserver: MemoryWarningObserver?

    init(
        countLimit: Int = 200,
        totalCostLimit: Int = 48 * 1_024 * 1_024,
        notificationCenter: NotificationCenter = .default,
        memoryWarningName: Notification.Name? = UIApplication.didReceiveMemoryWarningNotification
    ) {
        let countLimits = Self.splitLimit(countLimit)
        let costLimits = Self.splitLimit(totalCostLimit)

        exactCache.countLimit = countLimits.exact
        exactCache.totalCostLimit = costLimits.exact
        latestImageCache.countLimit = countLimits.latest
        latestImageCache.totalCostLimit = costLimits.latest

        memoryWarningObserver = MemoryWarningObserver(
            notificationCenter: notificationCenter,
            name: memoryWarningName
        ) { [weak self] in
            self?.removeAll()
        }
    }

    func image(for request: ArtworkRequest) -> UIImage? {
        exactCache.object(forKey: request.cacheKey as NSString)
    }

    func bestImage(for request: ArtworkRequest) -> UIImage? {
        image(for: request) ?? latestImageCache.object(forKey: request.imageKey as NSString)
    }

    func insert(_ image: UIImage, for request: ArtworkRequest) {
        let cost = Self.cost(for: image)
        exactCache.setObject(image, forKey: request.cacheKey as NSString, cost: cost)
        latestImageCache.setObject(image, forKey: request.imageKey as NSString, cost: cost)
    }

    func removeAll() {
        exactCache.removeAllObjects()
        latestImageCache.removeAllObjects()
    }

    private static func cost(for image: UIImage) -> Int {
        if let cgImage = image.cgImage {
            return max(cgImage.bytesPerRow * cgImage.height, 1)
        }

        let pixelWidth = Int((image.size.width * image.scale).rounded(.up))
        let pixelHeight = Int((image.size.height * image.scale).rounded(.up))
        return max(pixelWidth * pixelHeight * 4, 1)
    }

    private static func splitLimit(_ limit: Int) -> (exact: Int, latest: Int) {
        guard limit > 1 else {
            return (limit, limit)
        }

        return ((limit + 1) / 2, limit / 2)
    }
}
