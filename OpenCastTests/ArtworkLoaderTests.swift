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

    @Test(
        "Identical network and disk artwork shares one decode across rows and URLs",
        arguments: [
            (fromDisk: false, distinctURLs: false, networkRequests: 1),
            (fromDisk: false, distinctURLs: true, networkRequests: 12),
            (fromDisk: true, distinctURLs: false, networkRequests: 0),
            (fromDisk: true, distinctURLs: true, networkRequests: 0)
        ]
    )
    func concurrentRowsShareDecodedImage(fromDisk: Bool, distinctURLs: Bool, networkRequests: Int) async throws {
        let data = try pngData(width: 1_600, height: 1_600)
        let requests = (0..<12).map { index in
            ArtworkRequest(
                url: URL(string: "https://example.com/shared-row-\(distinctURLs ? index : 0).png")!,
                targetPixelSize: CGSize(width: 112, height: 112)
            )
        }
        let diskCache = ArtworkDiskCache(directory: try makeTemporaryDirectory())
        if fromDisk {
            for url in Set(requests.map(\.url)) {
                _ = try await diskCache.store(
                    data: data,
                    response: OpenCastHTTPResponse(httpResponse(url: url, statusCode: 200, headers: [:])),
                    for: url
                )
            }
        }
        let probe = ArtworkDataLoaderProbe(responses: [(data, nil)], waitsForRelease: !fromDisk)
        let decodeProbe = ArtworkDecodeThreadProbe()
        let loader = ArtworkLoader(
            diskCache: diskCache,
            dataLoader: probe.load,
            imageDecoder: decodeProbe.decode
        )
        let readers = Task {
            try await withThrowingTaskGroup(of: UIImage?.self) { group in
                for request in requests {
                    group.addTask { try await loader.image(for: request) }
                }
                var images: [UIImage] = []
                for try await image in group {
                    images.append(try #require(image))
                }
                return images
            }
        }
        if !fromDisk {
            #expect(await probe.waitForRequestCount(networkRequests))
            await probe.release()
        }
        let images = try await readers.value

        #expect(images.count == requests.count)
        #expect(images.allSatisfy { $0 === images.first })
        #expect(decodeProbe.observedMainThreadValues == [false])
        #expect(await probe.requestCount == networkRequests)
    }

    @Test("Sequential URL aliases reuse pixels while retaining separate preview identities")
    func sequentialAliasesReuseImage() async throws {
        let data = try pngData(width: 400, height: 400)
        let probe = ArtworkDataLoaderProbe(responses: [(data, nil)])
        let decodeProbe = ArtworkDecodeThreadProbe()
        let memoryCache = ArtworkMemoryCache(memoryWarningName: nil)
        let loader = ArtworkLoader(
            memoryCache: memoryCache,
            diskCache: ArtworkDiskCache(directory: try makeTemporaryDirectory()),
            dataLoader: probe.load,
            imageDecoder: decodeProbe.decode
        )
        let firstRequest = ArtworkRequest(
            url: URL(string: "https://example.com/episode-one.png")!,
            targetPixelSize: CGSize(width: 112, height: 112)
        )
        let secondRequest = ArtworkRequest(
            url: URL(string: "https://example.com/episode-two.png")!,
            targetPixelSize: firstRequest.pixelSize
        )
        let first = try #require(try await loader.loadResult(for: firstRequest))
        let second = try #require(try await loader.loadResult(for: secondRequest))

        #expect(first.image === second.image)
        #expect(first.preview?.sourceHash == second.preview?.sourceHash)
        #expect(first.preview?.canonicalArtworkURLKey == firstRequest.imageKey)
        #expect(second.preview?.canonicalArtworkURLKey == secondRequest.imageKey)
        #expect(decodeProbe.observedMainThreadValues == [false])

        memoryCache.removeAll()
        let reloaded = try #require(try await loader.image(for: secondRequest))
        #expect(reloaded !== first.image)
        #expect(decodeProbe.observedMainThreadValues == [false, false])
        #expect(await probe.requestCount == 2)
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

    @Test("Memory cache hit reads metadata only, not the data file")
    func memoryCacheHitReadsMetadataOnlyNotDataFile() async throws {
        let directory = try makeTemporaryDirectory()
        let data = try pngData(width: 400, height: 400)
        let url = URL(string: "https://example.com/memory-metadata-only.png")!
        let request = ArtworkRequest(url: url, targetPixelSize: CGSize(width: 56, height: 56))
        let probe = ArtworkDataLoaderProbe(responses: [(data, nil)])
        let loader = ArtworkLoader(
            diskCache: ArtworkDiskCache(directory: directory),
            dataLoader: probe.load
        )

        let networkResult = try #require(try await loader.loadResult(for: request))
        // Without the data file only the metadata-only warm path keeps the preview.
        let dataFiles = try FileManager.default
            .contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "data" }
        #expect(dataFiles.count == 1)
        for file in dataFiles {
            try FileManager.default.removeItem(at: file)
        }

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
        memoryCache.store(image, forContentKey: "backfill#56x56")
        memoryCache.alias(request, toContentKey: "backfill#56x56")
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

        let image = try await loader.image(
            for: url,
            targetPixelSize: CGSize(width: 56, height: 56),
            cacheKind: .show
        )
        await loader.waitForBackgroundRevalidations()
        let entry = try #require(try await diskCache.cachedEntry(for: url))

        #expect(image != nil)
        #expect(entry.data == cachedData)
        #expect(entry.metadata.byteCount == cachedData.count)
        #expect(entry.metadata.lastValidation > oldDate)
    }

    @Test("Now Playing artwork is not served from a thumbnail cache")
    func nowPlayingArtworkIgnoresThumbnailCache() async throws {
        let data = try pngData(width: 1_600, height: 1_600)
        let probe = ArtworkDataLoaderProbe(responses: [(data, nil)])
        let loader = try makeLoader(dataLoader: probe.load)
        let url = URL(string: "https://example.com/lock-screen.png")!

        _ = try await loader.image(for: url, targetPixelSize: CGSize(width: 114, height: 114))

        let artworkPixelWidth = try await Task { @MainActor in
            let nowPlayingLoader = SharedNowPlayingArtworkLoader(
                artworkLoader: loader,
                targetPixelSize: CGSize(width: 1_024, height: 1_024)
            )

            #expect(nowPlayingLoader.cachedArtwork(for: url) == nil)

            let artwork = try await nowPlayingLoader.artwork(for: url)
            let image = try #require(artwork.image(at: artwork.bounds.size))
            return Int((image.size.width * image.scale).rounded(.up))
        }.value

        #expect(artworkPixelWidth >= 1_024)
        #expect(await probe.requestCount == 1)
    }

    @Test("Artwork wider than the pixel limit is refused and never cached")
    func extremeDeclaredCanvasRefusedBeforeDecode() async throws {
        let oversized = try pngData(width: 12_001, height: 300)
        let probe = ArtworkDataLoaderProbe(responses: [(oversized, nil)])
        let directory = try makeTemporaryDirectory()
        let loader = ArtworkLoader(
            diskCache: ArtworkDiskCache(directory: directory),
            dataLoader: probe.load
        )
        let url = URL(string: "https://example.com/oversized.png")!

        let image = try await loader.image(for: url, targetPixelSize: CGSize(width: 1_024, height: 1_024))

        #expect(image == nil)
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path) == [])
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
