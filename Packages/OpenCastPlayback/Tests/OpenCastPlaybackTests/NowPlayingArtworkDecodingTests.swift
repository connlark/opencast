import CoreGraphics
import Foundation
import ImageIO
import OpenCastCore
import Testing
import UniformTypeIdentifiers
@testable import OpenCastPlayback

@MainActor
@Suite
struct NowPlayingArtworkDecodingTests {
    @Test("A small image decodes at its native size")
    func smallImageDecodesAtNativeSize() throws {
        let data = try Self.pngData(width: 320, height: 240)

        let image = try #require(NowPlayingArtworkDecoding.downsampledImage(from: data))

        #expect(Int(image.size.width) == 320)
        #expect(Int(image.size.height) == 240)
    }

    @Test("An oversized image downsamples to the Now Playing ceiling")
    func oversizedImageDownsamplesToCeiling() throws {
        let data = try Self.pngData(width: 3_000, height: 1_500)

        let image = try #require(NowPlayingArtworkDecoding.downsampledImage(from: data))

        let maxEdge = max(image.size.width, image.size.height)
        #expect(Int(maxEdge) <= ArtworkTransferPolicy.nowPlayingMaximumPixelSize)
        #expect(abs((image.size.width / image.size.height) - 2.0) < 0.01)
    }

    @Test("Artwork over the declared dimension limit is refused")
    func extremeDeclaredCanvasIsRefused() throws {
        let data = try Self.pngData(width: 12_001, height: 300)

        #expect(NowPlayingArtworkDecoding.downsampledImage(from: data) == nil)
    }

    @Test("Malformed data is refused")
    func malformedDataIsRefused() {
        #expect(NowPlayingArtworkDecoding.downsampledImage(from: Data("not an image".utf8)) == nil)
    }

    private static func pngData(width: Int, height: Int) throws -> Data {
        let context = try #require(CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.setFillColor(CGColor(red: 0.2, green: 0.4, blue: 0.6, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let image = try #require(context.makeImage())
        let data = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(
            data as CFMutableData,
            UTType.png.identifier as CFString,
            1,
            nil
        ))
        CGImageDestinationAddImage(destination, image, nil)
        #expect(CGImageDestinationFinalize(destination))
        return data as Data
    }
}
