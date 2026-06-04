import CoreGraphics
import Foundation
import ImageIO
@preconcurrency import MediaPlayer
import OpenCastCore
import SwiftUI
import Testing
import UniformTypeIdentifiers
@testable import OpenCast

@Suite("Artwork loader")
struct ArtworkLoaderTests {
    @Test("Cache hit reuses downsampled artwork")
    func cacheHitReusesDownsampledArtwork() async throws {
        let data = try pngData(width: 400, height: 400)
        let probe = ArtworkDataLoaderProbe(responses: [(data, nil)])
        let loader = try makeLoader(dataLoader: probe.load)
        let url = URL(string: "https://example.com/cache.png")!

        let firstImage = try #require(
            try await loader.image(for: url, targetPixelSize: CGSize(width: 48, height: 48))
        )
        let secondImage = try #require(
            try await loader.image(for: url, targetPixelSize: CGSize(width: 48, height: 48))
        )

        #expect(await probe.requestCount == 1)
        #expect(pixelWidth(of: firstImage) <= 48)
        #expect(pixelWidth(of: secondImage) <= 48)
    }

    @Test("Duplicate in-flight loads coalesce by URL")
    func duplicateInflightLoadsCoalesceByURL() async throws {
        let data = try pngData(width: 400, height: 400)
        let probe = ArtworkDataLoaderProbe(responses: [(data, nil)], waitsForRelease: true)
        let loader = try makeLoader(dataLoader: probe.load)
        let url = URL(string: "https://example.com/coalesced.png")!

        async let firstImage = loader.image(for: url, targetPixelSize: CGSize(width: 52, height: 52))
        async let secondImage = loader.image(for: url, targetPixelSize: CGSize(width: 96, height: 96))

        defer {
            Task {
                await probe.cancelAll()
            }
        }

        #expect(await probe.waitForRequestCount(1))
        #expect(await probe.requestCount == 1)
        await probe.release()

        let images = try await (firstImage, secondImage)
        #expect(images.0 != nil)
        #expect(images.1 != nil)
        #expect(await probe.requestCount == 1)
    }

    @Test("Caller cancellation leaves in-flight artwork available for the cache")
    func callerCancellationLeavesInflightArtworkAvailableForCache() async throws {
        let data = try pngData(width: 400, height: 400)
        let probe = ArtworkDataLoaderProbe(responses: [(data, nil)], waitsForRelease: true)
        let loader = try makeLoader(dataLoader: probe.load)
        let url = URL(string: "https://example.com/cancelled.png")!

        let task = Task {
            try await loader.image(for: url, targetPixelSize: CGSize(width: 48, height: 48))
        }
        #expect(await probe.waitForRequestCount(1))

        task.cancel()
        await probe.release()

        await #expect(throws: CancellationError.self) {
            try await task.value
        }

        let image = try await loader.image(for: url, targetPixelSize: CGSize(width: 48, height: 48))
        #expect(image != nil)
        #expect(await probe.requestCount == 1)
    }

    @Test("Failed HTTP responses are not cached")
    func failedHTTPResponsesAreNotCached() async throws {
        let data = try pngData(width: 400, height: 400)
        let url = URL(string: "https://example.com/missing.png")!
        let response = try #require(HTTPURLResponse(
            url: url,
            statusCode: 404,
            httpVersion: nil,
            headerFields: nil
        ))
        let probe = ArtworkDataLoaderProbe(responses: [(data, response), (data, response)])
        let loader = try makeLoader(dataLoader: probe.load)

        let firstImage = try await loader.image(for: url, targetPixelSize: CGSize(width: 48, height: 48))
        let secondImage = try await loader.image(for: url, targetPixelSize: CGSize(width: 48, height: 48))

        #expect(firstImage == nil)
        #expect(secondImage == nil)
        #expect(await probe.requestCount == 2)
    }

    @Test("Disk bytes satisfy multiple target sizes with one network fetch")
    func diskBytesSatisfyMultipleTargetSizesWithOneNetworkFetch() async throws {
        let data = try pngData(width: 400, height: 400)
        let probe = ArtworkDataLoaderProbe(responses: [(data, nil)])
        let loader = try makeLoader(dataLoader: probe.load)
        let url = URL(string: "https://example.com/sizes.png")!

        let smallImage = try #require(
            try await loader.image(for: url, targetPixelSize: CGSize(width: 48, height: 48))
        )
        let largeImage = try #require(
            try await loader.image(for: url, targetPixelSize: CGSize(width: 96, height: 96))
        )

        #expect(await probe.requestCount == 1)
        #expect(pixelWidth(of: smallImage) <= 48)
        #expect(pixelWidth(of: largeImage) <= 96)
        #expect(pixelWidth(of: largeImage) > pixelWidth(of: smallImage))
    }

    @Test("Cached artwork can fall back across target sizes")
    func cachedArtworkCanFallBackAcrossTargetSizes() async throws {
        let data = try pngData(width: 400, height: 400)
        let probe = ArtworkDataLoaderProbe(responses: [(data, nil)])
        let loader = try makeLoader(dataLoader: probe.load)
        let url = URL(string: "https://example.com/fallback-size.png")!
        let smallRequest = ArtworkRequest(url: url, targetPixelSize: CGSize(width: 42, height: 42))
        let largeRequest = ArtworkRequest(url: url, targetPixelSize: CGSize(width: 240, height: 240))

        let smallImage = try #require(try await loader.image(for: smallRequest))

        #expect(loader.cachedImage(for: largeRequest) == nil)
        #expect(loader.bestCachedImage(for: largeRequest) === smallImage)
    }

    @Test("Memory warning clears decoded artwork caches")
    func memoryWarningClearsDecodedArtworkCaches() async throws {
        let notificationCenter = NotificationCenter()
        let memoryWarningName = Notification.Name("OpenCastArtworkMemoryWarning")
        let memoryCache = ArtworkMemoryCache(
            notificationCenter: notificationCenter,
            memoryWarningName: memoryWarningName
        )
        let diskCache = ArtworkDiskCache(directory: try makeTemporaryDirectory())
        let data = try pngData(width: 400, height: 400)
        let probe = ArtworkDataLoaderProbe(responses: [(data, nil)])
        let loader = ArtworkLoader(
            memoryCache: memoryCache,
            diskCache: diskCache,
            dataLoader: probe.load
        )
        let url = URL(string: "https://example.com/memory-warning.png")!
        let request = ArtworkRequest(url: url, targetPixelSize: CGSize(width: 96, height: 96))

        let image = try #require(try await loader.image(for: request))
        #expect(loader.cachedImage(for: request) === image)
        let cachedArtwork = try await Task { @MainActor in
            let nowPlayingLoader = SharedNowPlayingArtworkLoader(
                artworkLoader: loader,
                targetPixelSize: CGSize(width: 512, height: 512),
                notificationCenter: notificationCenter,
                memoryWarningName: memoryWarningName
            )
            _ = try await nowPlayingLoader.artwork(for: url)
            #expect(nowPlayingLoader.cachedArtwork(for: url) != nil)
            notificationCenter.post(name: memoryWarningName, object: nil)
            return nowPlayingLoader.cachedArtwork(for: url)
        }.value

        #expect(cachedArtwork == nil)
        #expect(loader.cachedImage(for: request) == nil)

        let reloadedImage = try await loader.image(for: request)
        #expect(reloadedImage != nil)
        #expect(await probe.requestCount == 1)
    }

    @Test("Large artwork decoding stays off the main actor")
    func largeArtworkDecodingStaysOffMainActor() async throws {
        let directory = try makeTemporaryDirectory()
        let data = try pngData(width: 1_600, height: 1_600)
        let probe = ArtworkDataLoaderProbe(responses: [(data, nil)])
        let decodeProbe = ArtworkDecodeThreadProbe()
        let loader = ArtworkLoader(
            diskCache: ArtworkDiskCache(directory: directory),
            dataLoader: probe.load,
            imageDecoder: decodeProbe.decode
        )
        let url = URL(string: "https://example.com/large-artwork.png")!
        let largeRequest = ArtworkRequest(url: url, targetPixelSize: CGSize(width: 1_024, height: 1_024))
        let smallerRequest = ArtworkRequest(url: url, targetPixelSize: CGSize(width: 512, height: 512))

        let networkImage = try await Task { @MainActor in
            try await loader.image(for: largeRequest)
        }.value
        let diskImage = try await Task { @MainActor in
            try await loader.image(for: smallerRequest)
        }.value

        #expect(networkImage != nil)
        #expect(diskImage != nil)
        #expect(await probe.requestCount == 1)
        #expect(decodeProbe.observedMainThreadValues == [false, false])
    }

    @Test("Canonical artwork URL variants share cache entries")
    func canonicalArtworkURLVariantsShareCacheEntries() async throws {
        let data = try pngData(width: 400, height: 400)
        let probe = ArtworkDataLoaderProbe(responses: [(data, nil)])
        let loader = try makeLoader(dataLoader: probe.load)
        let firstURL = URL(string: "HTTPS://Example.com/artwork.png/?b=2&a=1#feed")!
        let secondURL = URL(string: "https://example.com/artwork.png?a=1&b=2")!

        let firstImage = try await loader.image(for: firstURL, targetPixelSize: CGSize(width: 48, height: 48))
        let secondImage = try await loader.image(for: secondURL, targetPixelSize: CGSize(width: 48, height: 48))

        #expect(firstImage != nil)
        #expect(secondImage != nil)
        #expect(await probe.requestCount == 1)
    }

    @Test("New loader instance uses disk artwork without refetching")
    func newLoaderInstanceUsesDiskArtworkWithoutRefetching() async throws {
        let directory = try makeTemporaryDirectory()
        let data = try pngData(width: 400, height: 400)
        let probe = ArtworkDataLoaderProbe(responses: [(data, nil)])
        let firstLoader = ArtworkLoader(
            diskCache: ArtworkDiskCache(directory: directory),
            dataLoader: probe.load
        )
        let secondLoader = ArtworkLoader(
            diskCache: ArtworkDiskCache(directory: directory),
            dataLoader: probe.load
        )
        let url = URL(string: "https://example.com/relaunch.png")!

        let firstImage = try await firstLoader.image(for: url, targetPixelSize: CGSize(width: 56, height: 56))
        let secondImage = try await secondLoader.image(for: url, targetPixelSize: CGSize(width: 96, height: 96))

        #expect(firstImage != nil)
        #expect(secondImage != nil)
        #expect(await probe.requestCount == 1)
    }

    @Test("Disk cache stores and returns generated artwork previews")
    func diskCacheStoresAndReturnsGeneratedArtworkPreviews() async throws {
        let directory = try makeTemporaryDirectory()
        let data = try pngData(width: 400, height: 400)
        let probe = ArtworkDataLoaderProbe(responses: [(data, nil)])
        let firstLoader = ArtworkLoader(
            diskCache: ArtworkDiskCache(directory: directory),
            dataLoader: probe.load
        )
        let secondLoader = ArtworkLoader(
            diskCache: ArtworkDiskCache(directory: directory),
            dataLoader: probe.load
        )
        let url = URL(string: "https://example.com/preview-cache.png")!
        let request = ArtworkRequest(url: url, targetPixelSize: CGSize(width: 56, height: 56))

        let networkResult = try #require(try await firstLoader.loadResult(for: request))
        let metadata = try #require(try await ArtworkDiskCache(directory: directory).metadata(for: url))
        let diskResult = try #require(try await secondLoader.loadResult(for: request))

        #expect(networkResult.preview != nil)
        #expect(metadata.preview == networkResult.preview)
        #expect(diskResult.preview == networkResult.preview)
        #expect(await probe.requestCount == 1)
    }

    @Test("Memory cache hit returns preview from disk metadata")
    func memoryCacheHitReturnsPreviewFromDiskMetadata() async throws {
        let directory = try makeTemporaryDirectory()
        let data = try pngData(width: 400, height: 400)
        let probe = ArtworkDataLoaderProbe(responses: [(data, nil)])
        let loader = ArtworkLoader(
            diskCache: ArtworkDiskCache(directory: directory),
            dataLoader: probe.load
        )
        let url = URL(string: "https://example.com/memory-preview-cache.png")!
        let request = ArtworkRequest(url: url, targetPixelSize: CGSize(width: 56, height: 56))

        let networkResult = try #require(try await loader.loadResult(for: request))
        let memoryResult = try #require(try await loader.loadResult(for: request))

        #expect(networkResult.preview != nil)
        #expect(memoryResult.preview == networkResult.preview)
        #expect(await probe.requestCount == 1)
    }

    @Test("Memory cache hit backfills missing disk preview")
    func memoryCacheHitBackfillsMissingDiskPreview() async throws {
        let directory = try makeTemporaryDirectory()
        let data = try pngData(width: 400, height: 400)
        let url = URL(string: "https://example.com/memory-preview-backfill.png")!
        let request = ArtworkRequest(url: url, targetPixelSize: CGSize(width: 56, height: 56))
        let memoryCache = ArtworkMemoryCache()
        let image = try #require(UIImage(data: data))
        memoryCache.insert(image, for: request)
        let diskCache = ArtworkDiskCache(directory: directory)
        _ = try await diskCache.store(
            data: data,
            response: OpenCastHTTPResponse(
                httpResponse(url: url, statusCode: 200, headers: ["Content-Type": "image/png"])
            ),
            for: url
        )
        let probe = ArtworkDataLoaderProbe(responses: [(data, nil)])
        let loader = ArtworkLoader(
            memoryCache: memoryCache,
            diskCache: diskCache,
            dataLoader: probe.load
        )

        let result = try #require(try await loader.loadResult(for: request))
        let metadata = try #require(try await diskCache.metadata(for: url))

        #expect(result.preview != nil)
        #expect(metadata.preview == result.preview)
        #expect(await probe.requestCount == 0)
    }

    @Test("Legacy disk cache hit backfills preview without refetching")
    func legacyDiskCacheHitBackfillsPreviewWithoutRefetching() async throws {
        let directory = try makeTemporaryDirectory()
        let data = try pngData(width: 400, height: 400)
        let url = URL(string: "https://example.com/legacy-preview-backfill.png")!
        let request = ArtworkRequest(url: url, targetPixelSize: CGSize(width: 56, height: 56))
        let diskCache = ArtworkDiskCache(directory: directory)
        _ = try await diskCache.store(
            data: data,
            response: OpenCastHTTPResponse(
                httpResponse(url: url, statusCode: 200, headers: ["Content-Type": "image/png"])
            ),
            for: url
        )
        let probe = ArtworkDataLoaderProbe(responses: [(data, nil)])
        let loader = ArtworkLoader(diskCache: diskCache, dataLoader: probe.load)

        let result = try #require(try await loader.loadResult(for: request))
        let metadata = try #require(try await diskCache.metadata(for: url))

        #expect(result.preview != nil)
        #expect(metadata.preview == result.preview)
        #expect(await probe.requestCount == 0)
    }

    @Test("Invalid disk preview is ignored and backfilled without refetching")
    func invalidDiskPreviewIsIgnoredAndBackfilledWithoutRefetching() async throws {
        let directory = try makeTemporaryDirectory()
        let data = try pngData(width: 400, height: 400)
        let url = URL(string: "https://example.com/invalid-preview-backfill.png")!
        let request = ArtworkRequest(url: url, targetPixelSize: CGSize(width: 56, height: 56))
        let diskCache = ArtworkDiskCache(directory: directory)
        _ = try await diskCache.store(
            data: data,
            response: OpenCastHTTPResponse(
                httpResponse(url: url, statusCode: 200, headers: ["Content-Type": "image/png"])
            ),
            for: url
        )
        let metadataURL = try #require(try cacheFile(in: directory, pathExtension: "json"))
        var metadataJSON = try #require(
            try JSONSerialization.jsonObject(with: Data(contentsOf: metadataURL)) as? [String: Any]
        )
        let oldRGBData = Data((0..<(8 * 8)).flatMap { _ in [UInt8(20), 40, 60] })
        metadataJSON["preview"] = [
            "version": ArtworkPreview.currentVersion - 1,
            "canonicalArtworkURLKey": URLCanonicalizer.canonicalString(for: url),
            "sourceHash": "old-preview-source",
            "pixelWidth": 8,
            "pixelHeight": 8,
            "rgbData": oldRGBData.base64EncodedString()
        ]
        let invalidPreviewMetadata = try JSONSerialization.data(
            withJSONObject: metadataJSON,
            options: [.prettyPrinted, .sortedKeys]
        )
        try invalidPreviewMetadata.write(to: metadataURL, options: .atomic)

        let probe = ArtworkDataLoaderProbe(responses: [(data, nil)])
        let loader = ArtworkLoader(diskCache: diskCache, dataLoader: probe.load)

        let result = try #require(try await loader.loadResult(for: request))
        let metadata = try #require(try await diskCache.metadata(for: url))

        #expect(result.preview != nil)
        #expect(metadata.preview == result.preview)
        #expect(await probe.requestCount == 0)
    }

    @Test("Corrupt disk metadata is purged and refetched")
    func corruptDiskMetadataIsPurgedAndRefetched() async throws {
        let directory = try makeTemporaryDirectory()
        let url = URL(string: "https://example.com/corrupt-metadata.png")!
        let staleData = try pngData(width: 300, height: 300)
        let freshData = try pngData(width: 420, height: 420)
        let diskCache = ArtworkDiskCache(directory: directory)
        _ = try await diskCache.store(
            data: staleData,
            response: OpenCastHTTPResponse(
                httpResponse(url: url, statusCode: 200, headers: ["Content-Type": "image/png"])
            ),
            for: url
        )
        let metadataURL = try #require(try cacheFile(in: directory, pathExtension: "json"))
        try Data("not-json".utf8).write(to: metadataURL, options: .atomic)
        let probe = ArtworkDataLoaderProbe(responses: [(
            freshData,
            httpResponse(url: url, statusCode: 200, headers: ["Content-Type": "image/png"])
        )])
        let loader = ArtworkLoader(diskCache: diskCache, dataLoader: probe.load)

        let image = try await loader.image(for: url, targetPixelSize: CGSize(width: 96, height: 96))
        let entry = try #require(try await diskCache.cachedEntry(for: url))

        #expect(image != nil)
        #expect(entry.data == freshData)
        #expect(await probe.requestCount == 1)
    }

    @Test("Corrupt disk image bytes are purged and refetched")
    func corruptDiskImageBytesArePurgedAndRefetched() async throws {
        let directory = try makeTemporaryDirectory()
        let url = URL(string: "https://example.com/corrupt-image.png")!
        let freshData = try pngData(width: 420, height: 420)
        let diskCache = ArtworkDiskCache(directory: directory)
        _ = try await diskCache.store(
            data: Data("not-image".utf8),
            response: OpenCastHTTPResponse(
                httpResponse(url: url, statusCode: 200, headers: ["Content-Type": "image/png"])
            ),
            for: url
        )
        let probe = ArtworkDataLoaderProbe(responses: [(
            freshData,
            httpResponse(url: url, statusCode: 200, headers: ["Content-Type": "image/png"])
        )])
        let loader = ArtworkLoader(diskCache: diskCache, dataLoader: probe.load)

        let image = try await loader.image(for: url, targetPixelSize: CGSize(width: 96, height: 96))
        let entry = try #require(try await diskCache.cachedEntry(for: url))

        #expect(image != nil)
        #expect(entry.data == freshData)
        #expect(await probe.requestCount == 1)
    }

    @Test("MIME mismatch does not override image byte validation")
    func mimeMismatchDoesNotOverrideImageByteValidation() async throws {
        let directory = try makeTemporaryDirectory()
        let url = URL(string: "https://example.com/mime-mismatch.png")!
        let validData = try pngData(width: 400, height: 400)
        let invalidImageResponse = httpResponse(
            url: url,
            statusCode: 200,
            headers: ["Content-Type": "image/png"]
        )
        let mislabeledImageResponse = httpResponse(
            url: url,
            statusCode: 200,
            headers: ["Content-Type": "text/plain"]
        )
        let probe = ArtworkDataLoaderProbe(responses: [
            (Data("not-image".utf8), invalidImageResponse),
            (validData, mislabeledImageResponse)
        ])
        let diskCache = ArtworkDiskCache(directory: directory)
        let firstLoader = ArtworkLoader(diskCache: diskCache, dataLoader: probe.load)

        let rejectedImage = try await firstLoader.image(
            for: url,
            targetPixelSize: CGSize(width: 96, height: 96)
        )
        let acceptedImage = try await firstLoader.image(
            for: url,
            targetPixelSize: CGSize(width: 96, height: 96)
        )
        let secondLoader = ArtworkLoader(diskCache: diskCache, dataLoader: probe.load)
        let diskImage = try await secondLoader.image(
            for: url,
            targetPixelSize: CGSize(width: 128, height: 128)
        )

        #expect(rejectedImage == nil)
        #expect(acceptedImage != nil)
        #expect(diskImage != nil)
        #expect(await probe.requestCount == 2)
    }

    @Test("Stale cached artwork renders immediately and revalidates")
    func staleCachedArtworkRendersImmediatelyAndRevalidates() async throws {
        let directory = try makeTemporaryDirectory()
        let url = URL(string: "https://example.com/stale.png")!
        let cachedData = try pngData(width: 400, height: 400)
        let diskCache = ArtworkDiskCache(directory: directory)
        let oldDate = Date.now.addingTimeInterval(-31 * 24 * 60 * 60)
        _ = try await diskCache.store(
            data: cachedData,
            response: OpenCastHTTPResponse(
                httpResponse(url: url, statusCode: 200, headers: ["ETag": "\"old\""])
            ),
            for: url,
            now: oldDate
        )
        let probe = ArtworkDataLoaderProbe(responses: [(
            Data(),
            httpResponse(url: url, statusCode: 304, headers: ["ETag": "\"old\""])
        )])
        let loader = ArtworkLoader(diskCache: diskCache, dataLoader: probe.load)

        let image = try await loader.image(
            for: url,
            targetPixelSize: CGSize(width: 56, height: 56),
            cacheKind: .show
        )

        #expect(image != nil)
        #expect(await probe.waitForRequestCount(1))
        await loader.waitForBackgroundRevalidations()
        let metadata = try #require(try await diskCache.metadata(for: url))
        #expect(metadata.lastValidation > oldDate)
    }

    @Test("304 updates metadata without rewriting bytes")
    func notModifiedUpdatesMetadataWithoutRewritingBytes() async throws {
        let directory = try makeTemporaryDirectory()
        let url = URL(string: "https://example.com/not-modified.png")!
        let cachedData = try pngData(width: 400, height: 400)
        let diskCache = ArtworkDiskCache(directory: directory)
        let oldDate = Date.now.addingTimeInterval(-31 * 24 * 60 * 60)
        _ = try await diskCache.store(
            data: cachedData,
            response: OpenCastHTTPResponse(
                httpResponse(url: url, statusCode: 200, headers: ["ETag": "\"old\""])
            ),
            for: url,
            now: oldDate
        )
        let probe = ArtworkDataLoaderProbe(responses: [(
            Data("ignored".utf8),
            httpResponse(url: url, statusCode: 304, headers: ["ETag": "\"old\""])
        )])
        let loader = ArtworkLoader(diskCache: diskCache, dataLoader: probe.load)

        _ = try await loader.image(
            for: url,
            targetPixelSize: CGSize(width: 56, height: 56),
            cacheKind: .show
        )
        await loader.waitForBackgroundRevalidations()
        let entry = try #require(try await diskCache.cachedEntry(for: url))

        #expect(entry.data == cachedData)
        #expect(entry.metadata.byteCount == cachedData.count)
        #expect(entry.metadata.lastValidation > oldDate)
    }

    @Test("UI and Now Playing artwork share disk bytes")
    func uiAndNowPlayingArtworkShareDiskBytes() async throws {
        let data = try pngData(width: 400, height: 400)
        let probe = ArtworkDataLoaderProbe(responses: [(data, nil)])
        let loader = try makeLoader(dataLoader: probe.load)
        let url = URL(string: "https://example.com/shared-now-playing.png")!

        let smallImage = try await loader.image(for: url, targetPixelSize: CGSize(width: 56, height: 56))
        let largeImage = try await loader.image(for: url, targetPixelSize: CGSize(width: 96, height: 96))
        let cachedArtwork = try await Task { @MainActor in
            let nowPlayingLoader = SharedNowPlayingArtworkLoader(
                artworkLoader: loader,
                targetPixelSize: CGSize(width: 512, height: 512)
            )
            _ = try await nowPlayingLoader.artwork(for: url)
            return nowPlayingLoader.cachedArtwork(for: url)
        }.value

        #expect(smallImage != nil)
        #expect(largeImage != nil)
        #expect(cachedArtwork != nil)
        #expect(await probe.requestCount == 1)
    }

    private func pngData(width: Int, height: Int) throws -> Data {
        let bytesPerPixel = 4
        let bytesPerRow = width * bytesPerPixel
        var pixels = [UInt8](repeating: 0, count: height * bytesPerRow)
        for offset in stride(from: 0, to: pixels.count, by: bytesPerPixel) {
            pixels[offset] = 32
            pixels[offset + 1] = 128
            pixels[offset + 2] = 224
            pixels[offset + 3] = 255
        }

        guard let provider = CGDataProvider(data: Data(pixels) as CFData),
              let image = CGImage(
                width: width,
                height: height,
                bitsPerComponent: 8,
                bitsPerPixel: bytesPerPixel * 8,
                bytesPerRow: bytesPerRow,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                provider: provider,
                decode: nil,
                shouldInterpolate: true,
                intent: .defaultIntent
              )
        else {
            throw CocoaError(.fileWriteUnknown)
        }

        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            data,
            UTType.png.identifier as CFString,
            1,
            nil
        ) else {
            throw CocoaError(.fileWriteUnknown)
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw CocoaError(.fileWriteUnknown)
        }

        return data as Data
    }

    private func pixelWidth(of image: UIImage) -> Int {
        Int((image.size.width * image.scale).rounded(.up))
    }

    private func makeLoader(dataLoader: @escaping ArtworkDataLoader) throws -> ArtworkLoader {
        ArtworkLoader(
            diskCache: ArtworkDiskCache(directory: try makeTemporaryDirectory()),
            dataLoader: dataLoader
        )
    }

    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "OpenCastArtworkTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func cacheFile(in directory: URL, pathExtension: String) throws -> URL? {
        try FileManager.default
            .contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .first { $0.pathExtension == pathExtension }
    }

    private func httpResponse(
        url: URL,
        statusCode: Int,
        headers: [String: String]
    ) -> HTTPURLResponse {
        HTTPURLResponse(
            url: url,
            statusCode: statusCode,
            httpVersion: nil,
            headerFields: headers
        )!
    }
}

private final class ArtworkDecodeThreadProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var mainThreadValues: [Bool] = []

    var observedMainThreadValues: [Bool] {
        lock.withLock {
            mainThreadValues
        }
    }

    func decode(data: Data, targetPixelSize: CGSize) -> UIImage? {
        lock.withLock {
            mainThreadValues.append(Thread.isMainThread)
        }
        return UIImage(data: data)
    }
}
