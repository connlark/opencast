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
    /// `ArtworkRequest.imageKey` (URL) to the biggest decode made for it. The
    /// Now Playing surfaces need the largest bitmap the app holds, not the one
    /// a list row happened to decode last.
    private var largestAliases: [String: LargestDecode] = [:]
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

    /// The cached decode for the request's URL that actually reaches the
    /// requested pixel size: the exact entry when one exists, otherwise the
    /// biggest decode that is still large enough.
    ///
    /// A decode is only ever as large as its source, so the check runs against
    /// the decoded bitmap rather than the requested size. Artwork whose source
    /// is smaller than the request never qualifies — the caller has to load it
    /// to find out.
    func imageMeetingSize(for request: ArtworkRequest) -> UIImage? {
        if let image = image(for: request), meetsPixelSize(image, request) {
            return image
        }

        let decode = aliasLock.withLock { largestAliases[request.imageKey] }
        guard let decode,
              let image = image(forContentKey: decode.contentKey),
              meetsPixelSize(image, request)
        else {
            return nil
        }

        return image
    }

    func store(_ image: UIImage, forContentKey key: String) {
        images.setObject(image, forKey: key as NSString, cost: Self.cost(for: image))
    }

    func alias(_ request: ArtworkRequest, toContentKey key: String) {
        aliasLock.withLock {
            exactAliases[request.cacheKey] = key
            latestAliases[request.imageKey] = key
            recordLargestDecode(request, contentKey: key)
            trimAliasesIfNeeded()
        }
    }

    func removeAll() {
        images.removeAllObjects()
        aliasLock.withLock {
            exactAliases.removeAll()
            latestAliases.removeAll()
            largestAliases.removeAll()
        }
    }

    /// Keeps the biggest decode of the URL's current bytes. A thumbnail
    /// decoded after a full-size one must not displace it, but a decode of
    /// different bytes for the URL (a revalidation) does at any size: the
    /// old bitmap can stay resident long after it stopped being the artwork.
    private func recordLargestDecode(_ request: ArtworkRequest, contentKey: String) {
        let candidate = LargestDecode(
            contentKey: contentKey,
            pixelWidth: request.pixelWidth,
            pixelHeight: request.pixelHeight
        )
        if let existing = largestAliases[request.imageKey],
           DecodedArtwork.sourceHash(fromContentKey: existing.contentKey)
               == DecodedArtwork.sourceHash(fromContentKey: contentKey),
           max(existing.pixelWidth, existing.pixelHeight)
               >= max(candidate.pixelWidth, candidate.pixelHeight) {
            return
        }

        largestAliases[request.imageKey] = candidate
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
        if largestAliases.count > aliasLimit {
            largestAliases = largestAliases.filter { image(forContentKey: $0.value.contentKey) != nil }
            while largestAliases.count > aliasLimit, let key = largestAliases.keys.first {
                largestAliases[key] = nil
            }
        }
    }

    private func meetsPixelSize(_ image: UIImage, _ request: ArtworkRequest) -> Bool {
        let scale = image.scale
        guard scale > 0 else {
            return false
        }

        let pixelWidth = Int((image.size.width * scale).rounded(.down))
        let pixelHeight = Int((image.size.height * scale).rounded(.down))
        return pixelWidth >= request.pixelWidth && pixelHeight >= request.pixelHeight
    }

    private static func cost(for image: UIImage) -> Int {
        if let cgImage = image.cgImage {
            return max(cgImage.bytesPerRow * cgImage.height, 1)
        }

        let pixelWidth = Int((image.size.width * image.scale).rounded(.up))
        let pixelHeight = Int((image.size.height * image.scale).rounded(.up))
        return max(pixelWidth * pixelHeight * 4, 1)
    }

    /// The biggest decode recorded for a URL, with the pixel size it was
    /// requested at.
    private struct LargestDecode {
        let contentKey: String
        let pixelWidth: Int
        let pixelHeight: Int
    }
}
