import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import OpenCast

@Suite("Artwork preview generator")
struct ArtworkPreviewGeneratorTests {
    @Test("Generates square RGB preview data")
    func generatesSquareRGBPreviewData() async throws {
        let data = try pngData(width: 32, height: 32, red: 210, green: 60, blue: 24)
        let preview = try #require(await ArtworkPreviewGenerator.generate(
            from: data,
            canonicalArtworkURLKey: "https://example.com/art.png"
        ))

        #expect(preview.version == ArtworkPreview.currentVersion)
        #expect(preview.pixelWidth == 8)
        #expect(preview.pixelHeight == 8)
        #expect(preview.rgbData.count == 8 * 8 * 3)
        #expect(preview.rgbData.first == 210)
    }

    @Test("Generates wide RGB preview dimensions")
    func generatesWideRGBPreviewDimensions() async throws {
        let data = try pngData(width: 64, height: 32, red: 210, green: 60, blue: 24)
        let preview = try #require(await ArtworkPreviewGenerator.generate(
            from: data,
            canonicalArtworkURLKey: "https://example.com/wide-art.png"
        ))

        #expect(preview.version == ArtworkPreview.currentVersion)
        #expect(preview.pixelWidth == 8)
        #expect(preview.pixelHeight == 4)
        #expect(preview.rgbData.count == 8 * 4 * 3)
        #expect(preview.rgbData.first == 210)
    }

    @Test("Corrupt artwork data does not produce a preview")
    func corruptArtworkDataDoesNotProducePreview() async {
        let preview = await ArtworkPreviewGenerator.generate(
            from: Data("not-image".utf8),
            canonicalArtworkURLKey: "https://example.com/corrupt.png"
        )

        #expect(preview == nil)
    }

    @MainActor
    @Test("A precomputed hash preserves preview color, aspect and source identity off-main")
    func suppliedHashProducesPreview() async throws {
        let data = try pngData(width: 64, height: 32, red: 210, green: 60, blue: 24)
        let key = "https://example.com/reused-thumbnail.png"
        let expected = await ArtworkPreviewGenerator.generate(from: data, canonicalArtworkURLKey: key)
        let probe = ArtworkPreviewThreadProbe()
        let actual = try #require(await ArtworkPreviewGenerator.generate(
            from: data,
            sourceHash: ArtworkPreviewGenerator.sourceHash(for: data),
            canonicalArtworkURLKey: key,
            threadObserver: probe.record
        ))

        #expect(actual == expected)
        #expect(actual.pixelWidth == 8)
        #expect(actual.pixelHeight == 4)
        #expect(probe.observedMainThreadValues == [false])
    }

    @Test("A canonical thumbnail averages fine source stripes")
    func canonicalThumbnailAveragesFineStripes() async throws {
        // Two-pixel stripes: a cell that samples instead of averaging reads
        // pure red or pure blue; the true mean is an even purple.
        let data = try pngData(width: 1_024, height: 1_024) { x, _ in
            (x / 2).isMultiple(of: 2) ? (255, 0, 0) : (0, 0, 255)
        }
        let preview = try #require(await ArtworkPreviewGenerator.generate(
            from: data,
            sourceHash: ArtworkPreviewGenerator.sourceHash(for: data),
            canonicalArtworkURLKey: "https://example.com/striped.png"
        ))
        let cells = stride(from: 0, to: preview.rgbData.count, by: 3).map { offset in
            (
                red: Int(preview.rgbData[offset]),
                green: Int(preview.rgbData[offset + 1]),
                blue: Int(preview.rgbData[offset + 2])
            )
        }

        #expect(cells.count == 64)
        #expect(
            cells.allSatisfy { abs($0.red - 128) <= 32 && $0.green == 0 && abs($0.blue - 128) <= 32 },
            "\(cells)"
        )
    }

    @MainActor
    @Test("Preview generation leaves the main thread")
    func previewGenerationLeavesMainThread() async throws {
        let data = try pngData(width: 64, height: 64, red: 40, green: 160, blue: 220)
        let probe = ArtworkPreviewThreadProbe()

        let preview = await ArtworkPreviewGenerator.generate(
            from: data,
            canonicalArtworkURLKey: "https://example.com/off-main.png",
            threadObserver: probe.record
        )

        #expect(preview != nil)
        #expect(probe.observedMainThreadValues == [false])
    }

    private func pngData(width: Int, height: Int, red: UInt8, green: UInt8, blue: UInt8) throws -> Data {
        try pngData(width: width, height: height) { _, _ in (red, green, blue) }
    }

    private func pngData(
        width: Int,
        height: Int,
        pixel: (_ x: Int, _ y: Int) -> (red: UInt8, green: UInt8, blue: UInt8)
    ) throws -> Data {
        let bytesPerPixel = 4
        let bytesPerRow = width * bytesPerPixel
        var pixels = [UInt8](repeating: 0, count: height * bytesPerRow)
        for y in 0..<height {
            for x in 0..<width {
                let offset = y * bytesPerRow + x * bytesPerPixel
                let color = pixel(x, y)
                pixels[offset] = color.red
                pixels[offset + 1] = color.green
                pixels[offset + 2] = color.blue
                pixels[offset + 3] = 255
            }
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
}

private final class ArtworkPreviewThreadProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var mainThreadValues: [Bool] = []

    var observedMainThreadValues: [Bool] {
        lock.withLock {
            mainThreadValues
        }
    }

    func record(isMainThread: Bool) {
        lock.withLock {
            mainThreadValues.append(isMainThread)
        }
    }
}
