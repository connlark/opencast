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

    @Test("Clearing drops images and aliases together")
    func removeAllClearsAliases() {
        let cache = ArtworkMemoryCache(memoryWarningName: nil)
        let request = ArtworkRequest(url: URL(string: "https://example.com/cleared.png")!, targetPixelSize: pixelSize)
        cache.store(UIImage(), forContentKey: "content#112x112")
        cache.alias(request, toContentKey: "content#112x112")

        cache.removeAll()

        #expect(cache.image(for: request) == nil)
        #expect(cache.image(forContentKey: "content#112x112") == nil)
    }
}
