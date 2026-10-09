import SwiftUI

// NSCache synchronizes the pixel store; aliasLock protects the key maps.
// MemoryWarningObserver only stores its token for deinit removal.
nonisolated final class ArtworkMemoryCache: @unchecked Sendable {
    /// Decoded pixels keyed by content hash and pixel size. Different episodes
    /// often publish identical cover bytes at different URLs; keying by content
    /// retains and charges such an image once however many URLs alias it.
    private let images = NSCache<NSString, UIImage>()
    /// `ArtworkRequest.cacheKey` (URL and size) to content key.
    private var exactAliases: [String: String] = [:]
    /// `ArtworkRequest.imageKey` (URL) to the content key of its latest decode at any size.
    private var latestAliases: [String: String] = [:]
    private let aliasLock = NSLock()
    private let aliasLimit: Int
    private var memoryWarningObserver: MemoryWarningObserver?

    init(
        countLimit: Int = 200,
        totalCostLimit: Int = 48 * 1_024 * 1_024,
        notificationCenter: NotificationCenter = .default,
        memoryWarningName: Notification.Name? = UIApplication.didReceiveMemoryWarningNotification
    ) {
        images.countLimit = countLimit
        images.totalCostLimit = totalCostLimit
        // Aliases are small strings; a loose bound keeps a long session from
        // accumulating keys for images the store evicted long ago.
        aliasLimit = max(countLimit, 1) * 8

        memoryWarningObserver = MemoryWarningObserver(
            notificationCenter: notificationCenter,
            name: memoryWarningName
        ) { [weak self] in
            self?.removeAll()
        }
    }

    func image(for request: ArtworkRequest) -> UIImage? {
        let contentKey = aliasLock.withLock { exactAliases[request.cacheKey] }
        return contentKey.flatMap(image(forContentKey:))
    }

    func bestImage(for request: ArtworkRequest) -> UIImage? {
        if let image = image(for: request) {
            return image
        }
        let contentKey = aliasLock.withLock { latestAliases[request.imageKey] }
        return contentKey.flatMap(image(forContentKey:))
    }

    func image(forContentKey key: String) -> UIImage? {
        images.object(forKey: key as NSString)
    }

    func store(_ image: UIImage, forContentKey key: String) {
        images.setObject(image, forKey: key as NSString, cost: Self.cost(for: image))
    }

    func alias(_ request: ArtworkRequest, toContentKey key: String) {
        aliasLock.withLock {
            exactAliases[request.cacheKey] = key
            latestAliases[request.imageKey] = key
            trimAliasesIfNeeded()
        }
    }

    func removeAll() {
        images.removeAllObjects()
        aliasLock.withLock {
            exactAliases.removeAll()
            latestAliases.removeAll()
        }
    }

    /// Drops aliases whose image the store evicted; if live aliases alone exceed
    /// the bound, arbitrary ones go. A dropped live alias costs one disk read
    /// and hash on its next request, never a decode.
    private func trimAliasesIfNeeded() {
        if exactAliases.count > aliasLimit {
            exactAliases = exactAliases.filter { image(forContentKey: $0.value) != nil }
            while exactAliases.count > aliasLimit, let key = exactAliases.keys.first {
                exactAliases[key] = nil
            }
        }
        if latestAliases.count > aliasLimit {
            latestAliases = latestAliases.filter { image(forContentKey: $0.value) != nil }
            while latestAliases.count > aliasLimit, let key = latestAliases.keys.first {
                latestAliases[key] = nil
            }
        }
    }

    private static func cost(for image: UIImage) -> Int {
        if let cgImage = image.cgImage {
            return max(cgImage.bytesPerRow * cgImage.height, 1)
        }

        let pixelWidth = Int((image.size.width * image.scale).rounded(.up))
        let pixelHeight = Int((image.size.height * image.scale).rounded(.up))
        return max(pixelWidth * pixelHeight * 4, 1)
    }
}
