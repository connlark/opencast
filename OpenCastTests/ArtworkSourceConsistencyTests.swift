import CoreGraphics
import Foundation
import ImageIO
import OpenCastCore
import SwiftUI
import Testing
import UniformTypeIdentifiers
@testable import OpenCast

@Suite("Artwork source consistency")
struct ArtworkSourceConsistencyTests {
    @Test("Preview pixels are independent of the first display size", arguments: [24, 112, 1_024])
    func previewDoesNotDependOnDisplaySize(firstSize: Int) async throws {
        let data = try patternedArtwork()
        let url = URL(string: "https://example.com/patterned.png")!
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let loader = ArtworkLoader(diskCache: ArtworkDiskCache(directory: directory), dataLoader: { _ in
            ArtworkDataResponse(data: data, response: OpenCastHTTPResponse(
                url: url, mimeType: "image/png", expectedContentLength: Int64(data.count), statusCode: 200, headers: [:]
            ))
        })
        let expected = try #require(await ArtworkPreviewGenerator.generate(from: data, canonicalArtworkURLKey: url.absoluteString))
        for size in [firstSize, 24, 112, 1_024] {
            let result = try #require(try await loader.loadResult(for: ArtworkRequest(
                url: url, targetPixelSize: CGSize(width: size, height: size)
            )))
            #expect(result.preview == expected, "Preview differs after first size \(firstSize), requested size \(size)")
        }
    }

    @Test("Concurrent display sizes share hashing and preview publication", arguments: [false, true])
    func concurrentSizesShareSource(fromDisk: Bool) async throws {
        let data = try patternedArtwork()
        let url = URL(string: "https://example.com/shared-source.png")!
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let disk = ArtworkDiskCache(directory: directory)
        if fromDisk { _ = try await disk.store(data: data, response: response(url, data), for: url) }
        let work = ArtworkSourceWorkProbe()
        let network = ArtworkDataLoaderProbe(responses: [(data, nil)])
        let loader = ArtworkLoader(diskCache: disk, dataLoader: network.load, sourceHasher: work.hash, previewBuilder: work.preview)
        defer { Task { await work.previewGate.release() } }
        let first = Task { try await loader.loadResult(for: request(url, size: 24)) }
        try #require(await waitUntil { work.previewCount == 1 })
        // Join after decode has finished but while preview publication is held.
        let readers = (0..<12).map { index in
            Task { try await loader.loadResult(for: request(url, size: [24, 112, 1_024][index % 3])) }
        }
        await work.previewGate.release()
        let expected = try #require(try await first.value?.preview)
        for reader in readers {
            let result = try #require(try await reader.value)
            #expect(result.preview == expected)
        }
        #expect(work.hashCount == 1)
        #expect(work.previewCount == 1)
        #expect(await network.requestCount == (fromDisk ? 0 : 1))
        #expect(try await disk.metadata(for: url)?.preview == expected)
    }

    @Test("Identical sources at different URLs share one canonical preview")
    func aliasesShareCanonicalPreview() async throws {
        let data = try patternedArtwork()
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let work = ArtworkSourceWorkProbe()
        await work.previewGate.release()
        let network = ArtworkDataLoaderProbe(responses: [(data, nil)])
        let loader = ArtworkLoader(diskCache: ArtworkDiskCache(directory: directory), dataLoader: network.load,
                                   sourceHasher: work.hash, previewBuilder: work.preview)
        var previews: [ArtworkPreview] = []
        for size in [24, 112, 1_024] {
            let url = URL(string: "https://example.com/alias-\(size).png")!
            let preview = try #require(try await loader.loadResult(for: request(url, size: size))?.preview)
            #expect(preview.canonicalArtworkURLKey == url.absoluteString)
            previews.append(preview)
        }
        #expect(previews.allSatisfy { $0.rgbData == previews.first?.rgbData && $0.sourceHash == previews.first?.sourceHash })
        #expect(work.previewCount == 1)
        #expect(work.hashCount == 3) // Unrelated URLs require inspecting their bytes to discover the alias.
    }

    @Test("A delayed backfill cannot overwrite a refreshed source's preview")
    func backfillDoesNotOverwriteRefreshedSource() async throws {
        let original = try patternedArtwork()
        let refreshed = try patternedArtwork(inverted: true)
        let url = URL(string: "https://example.com/replaced.png")!
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let disk = ArtworkDiskCache(directory: directory)
        _ = try await disk.store(data: original, response: response(url, original), for: url)
        let work = ArtworkSourceWorkProbe()
        let network = ArtworkDataLoaderProbe(responses: [(original, nil)])
        let loader = ArtworkLoader(diskCache: disk, dataLoader: network.load, sourceHasher: work.hash, previewBuilder: work.preview)
        defer { Task { await work.previewGate.release() } }
        let first = Task { try await loader.loadResult(for: request(url, size: 112)) }
        try #require(await waitUntil { work.previewCount == 1 })
        let refreshedPreview = try #require(await ArtworkPreviewGenerator.generate(from: refreshed, canonicalArtworkURLKey: url.absoluteString))
        _ = try await disk.store(data: refreshed, response: response(url, refreshed), for: url, preview: refreshedPreview)
        await work.previewGate.release()
        let originalResult = try #require(try await first.value)
        #expect(originalResult.preview?.sourceHash == ArtworkPreviewGenerator.sourceHash(for: original))
        #expect(try await disk.metadata(for: url)?.preview == refreshedPreview)
        let next = try #require(try await loader.loadResult(for: request(url, size: 112)))
        #expect(next.preview == refreshedPreview)
        #expect(next.image !== originalResult.image)
        #expect(await network.requestCount == 0)
    }

    @Test("Cancelling one reader preserves the image and preview for surviving readers")
    func cancelledReaderDoesNotCancelSource() async throws {
        let data = try patternedArtwork()
        let url = URL(string: "https://example.com/cancel-source.png")!
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let work = ArtworkSourceWorkProbe()
        let network = ArtworkDataLoaderProbe(responses: [(data, nil)])
        let loader = ArtworkLoader(diskCache: ArtworkDiskCache(directory: directory), dataLoader: network.load,
                                   sourceHasher: work.hash, previewBuilder: work.preview)
        defer { Task { await work.previewGate.release() } }
        let cancelled = Task { try await loader.loadResult(for: request(url, size: 112)) }
        try #require(await waitUntil { work.previewCount == 1 })
        cancelled.cancel()
        let survivor = Task { try await loader.loadResult(for: request(url, size: 112)) }
        await work.previewGate.release()
        await #expect(throws: CancellationError.self) { try await cancelled.value }
        let result = try #require(try await survivor.value)
        #expect(result.preview != nil)
        #expect(loader.cachedImage(for: request(url, size: 112)) === result.image)
        let alreadyCancelled = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await loader.loadResult(for: request(url, size: 112))
        }
        await #expect(throws: CancellationError.self) { try await alreadyCancelled.value }
        #expect(await network.requestCount == 1)
        #expect(work.previewCount == 1)
    }

    @Test("A warm alias follows refreshed metadata to already-cached pixels")
    func warmAliasFollowsRefreshedContent() async throws {
        let original = try patternedArtwork()
        let refreshed = try patternedArtwork(inverted: true)
        let firstURL = URL(string: "https://example.com/first.png")!
        let aliasURL = URL(string: "https://example.com/alias.png")!
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let disk = ArtworkDiskCache(directory: directory)
        let network = ArtworkDataLoaderProbe(responses: [(original, nil), (refreshed, nil)])
        let loader = ArtworkLoader(diskCache: disk, dataLoader: network.load)
        let firstRequest = request(firstURL, size: 112)
        let originalResult = try #require(try await loader.loadResult(for: firstRequest))
        let alias = try #require(try await loader.loadResult(for: request(aliasURL, size: 112)))
        var preview = try #require(alias.preview)
        preview.canonicalArtworkURLKey = firstURL.absoluteString
        _ = try await disk.store(data: refreshed, response: response(firstURL, refreshed), for: firstURL, preview: preview)
        let result = try #require(try await loader.loadResult(for: firstRequest))
        #expect(result.image === alias.image)
        #expect(result.image !== originalResult.image)
        #expect(result.preview == preview)
        #expect(loader.cachedImage(for: firstRequest) === result.image)
        #expect(await network.requestCount == 2)
    }

    private func request(_ url: URL, size: Int) -> ArtworkRequest {
        ArtworkRequest(url: url, targetPixelSize: CGSize(width: size, height: size))
    }

    private func response(_ url: URL, _ data: Data) -> OpenCastHTTPResponse {
        OpenCastHTTPResponse(url: url, mimeType: "image/png", expectedContentLength: Int64(data.count), statusCode: 200, headers: [:])
    }

    private func patternedArtwork(inverted: Bool = false) throws -> Data {
        let width = 2_048
        let height = 1_024
        var pixels = [UInt8](repeating: 255, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let offset = (y * width + x) * 4
                pixels[offset] = (x / 3).isMultiple(of: 2) != inverted ? 255 : 0
                pixels[offset + 1] = UInt8((y * 255) / height)
                pixels[offset + 2] = (x / 7 + y / 5).isMultiple(of: 2) ? 255 : 0
            }
        }
        let provider = try #require(CGDataProvider(data: Data(pixels) as CFData))
        let image = try #require(CGImage(
            width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
            bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent
        ))
        let data = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        #expect(CGImageDestinationFinalize(destination))
        return data as Data
    }
}
