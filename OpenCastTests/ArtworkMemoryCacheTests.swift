import CoreGraphics
import SwiftUI
import Testing
@testable import OpenCast

@Suite("Artwork memory cache")
struct ArtworkMemoryCacheTests {
    private let pixelSize = CGSize(width: 112, height: 112)

    @Test("URL aliases of one decoded image share a single cache entry")
    func aliasesShareOneEntry() {
        // With one slot, per-URL entries would evict each other; one content
        // entry serves every alias.
        let cache = ArtworkMemoryCache(countLimit: 1, memoryWarningName: nil)
        let image = UIImage()
        let requests = (0..<3).map { index in
            ArtworkRequest(url: URL(string: "https://example.com/episode-\(index).png")!, targetPixelSize: pixelSize)
        }
        cache.store(image, forContentKey: "content#112x112")
        for request in requests {
            cache.alias(request, toContentKey: "content#112x112")
        }

        #expect(requests.allSatisfy { cache.image(for: $0) === image })
        #expect(cache.image(forContentKey: "content#112x112") === image)
    }

    @Test("The latest alias serves another size until the exact size decodes")
    func latestAliasServesOtherSizes() {
        let cache = ArtworkMemoryCache(memoryWarningName: nil)
        let url = URL(string: "https://example.com/sizes.png")!
        let small = ArtworkRequest(url: url, targetPixelSize: CGSize(width: 48, height: 48))
        let large = ArtworkRequest(url: url, targetPixelSize: CGSize(width: 240, height: 240))
        let image = UIImage()
        cache.store(image, forContentKey: "content#48x48")
        cache.alias(small, toContentKey: "content#48x48")

        #expect(cache.image(for: large) == nil)
        #expect(cache.bestImage(for: large) === image)
    }

    @Test("An alias whose image is gone resolves to nothing")
    func staleAliasMisses() {
        let cache = ArtworkMemoryCache(memoryWarningName: nil)
        let request = ArtworkRequest(url: URL(string: "https://example.com/evicted.png")!, targetPixelSize: pixelSize)
        cache.alias(request, toContentKey: "missing#112x112")

        #expect(cache.image(for: request) == nil)
        #expect(cache.bestImage(for: request) == nil)
    }

    @Test("A thumbnail never satisfies a larger request")
    func thumbnailDoesNotSatisfyLargerRequest() {
        let cache = ArtworkMemoryCache(memoryWarningName: nil)
        let url = URL(string: "https://example.com/qualified.png")!
        let small = ArtworkRequest(url: url, targetPixelSize: CGSize(width: 48, height: 48))
        let large = ArtworkRequest(url: url, targetPixelSize: CGSize(width: 240, height: 240))
        let thumbnail = makeImage(pixelSize: 48)
        cache.store(thumbnail, forContentKey: "content#48x48")
        cache.alias(small, toContentKey: "content#48x48")

        #expect(cache.imageMeetingSize(for: small) === thumbnail)
        #expect(cache.imageMeetingSize(for: large) == nil)
    }

    @Test("The biggest decode satisfies a request the exact size misses")
    func biggestDecodeSatisfiesSmallerRequest() {
        let cache = ArtworkMemoryCache(memoryWarningName: nil)
        let url = URL(string: "https://example.com/biggest.png")!
        let small = ArtworkRequest(url: url, targetPixelSize: CGSize(width: 48, height: 48))
        let large = ArtworkRequest(url: url, targetPixelSize: CGSize(width: 240, height: 240))
        let largeImage = makeImage(pixelSize: 240)
        cache.store(largeImage, forContentKey: "content#240x240")
        cache.alias(large, toContentKey: "content#240x240")

        #expect(cache.imageMeetingSize(for: large) === largeImage)
        #expect(cache.imageMeetingSize(for: small) === largeImage)
    }

    @Test("A thumbnail decoded later does not displace the biggest decode")
    func laterThumbnailDoesNotDisplaceBiggestDecode() {
        let cache = ArtworkMemoryCache(memoryWarningName: nil)
        let url = URL(string: "https://example.com/displaced.png")!
        let small = ArtworkRequest(url: url, targetPixelSize: CGSize(width: 48, height: 48))
        let medium = ArtworkRequest(url: url, targetPixelSize: CGSize(width: 128, height: 128))
        let large = ArtworkRequest(url: url, targetPixelSize: CGSize(width: 240, height: 240))
        let largeImage = makeImage(pixelSize: 240)
        let thumbnail = makeImage(pixelSize: 48)
        cache.store(largeImage, forContentKey: "content#240x240")
        cache.alias(large, toContentKey: "content#240x240")
        cache.store(thumbnail, forContentKey: "content#48x48")
        cache.alias(small, toContentKey: "content#48x48")

        // Nothing was decoded at 128, so only the biggest-decode record can answer.
        #expect(cache.imageMeetingSize(for: medium) === largeImage)
    }

    @Test("New bytes at a URL replace its biggest decode at an equal or smaller size", arguments: [240, 160])
    func replacementContentDisplacesBiggestDecode(replacementPixelSize: Int) {
        let cache = ArtworkMemoryCache(memoryWarningName: nil)
        let url = URL(string: "https://example.com/revalidated.png")!
        let original = ArtworkRequest(url: url, targetPixelSize: CGSize(width: 240, height: 240))
        let replacement = ArtworkRequest(
            url: url,
            targetPixelSize: CGSize(width: replacementPixelSize, height: replacementPixelSize)
        )
        let medium = ArtworkRequest(url: url, targetPixelSize: CGSize(width: 128, height: 128))
        let originalKey = DecodedArtwork.contentKey(for: original, sourceHash: "original")
        let replacementKey = DecodedArtwork.contentKey(for: replacement, sourceHash: "replacement")
        let originalImage = makeImage(pixelSize: 240)
        let replacementImage = makeImage(pixelSize: replacementPixelSize)
        cache.store(originalImage, forContentKey: originalKey)
        cache.alias(original, toContentKey: originalKey)
        cache.store(replacementImage, forContentKey: replacementKey)
        cache.alias(replacement, toContentKey: replacementKey)

        // The original bitmap is still resident but is no longer the URL's content.
        #expect(cache.imageMeetingSize(for: medium) === replacementImage)
    }

    @Test("Clearing drops images and aliases together")
    func removeAllClearsAliases() {
        let cache = ArtworkMemoryCache(memoryWarningName: nil)
        let request = ArtworkRequest(url: URL(string: "https://example.com/cleared.png")!, targetPixelSize: pixelSize)
        cache.store(UIImage(), forContentKey: "content#112x112")
        cache.alias(request, toContentKey: "content#112x112")

        cache.removeAll()

        #expect(cache.image(for: request) == nil)
        #expect(cache.image(forContentKey: "content#112x112") == nil)
        #expect(cache.imageMeetingSize(for: request) == nil)
    }

    /// A bitmap with a known pixel size, independent of the device scale.
    private func makeImage(pixelSize: Int) -> UIImage {
        guard let context = CGContext(
            data: nil,
            width: pixelSize,
            height: pixelSize,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ), let cgImage = context.makeImage() else {
            return UIImage()
        }

        return UIImage(cgImage: cgImage, scale: 1, orientation: .up)
    }
}
