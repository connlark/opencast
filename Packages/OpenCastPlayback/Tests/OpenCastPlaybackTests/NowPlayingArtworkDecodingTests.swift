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
        // Aspect ratio survives the downsample.
        #expect(abs((image.size.width / image.size.height) - 2.0) < 0.01)
    }

    @Test("An extreme declared canvas is refused before pixel work")
    func extremeDeclaredCanvasIsRefused() throws {
        let data = Self.syntheticPNGHeader(width: 100_000, height: 100_000)

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

    /// A tiny synthetic payload whose IHDR declares an absurd canvas — the
    /// compressed-bomb shape from the triage, without a large fixture.
    private static func syntheticPNGHeader(width: UInt32, height: UInt32) -> Data {
        var data = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
        var chunk = Data("IHDR".utf8)
        for value in [width, height] {
            chunk.append(contentsOf: [
                UInt8((value >> 24) & 0xFF),
                UInt8((value >> 16) & 0xFF),
                UInt8((value >> 8) & 0xFF),
                UInt8(value & 0xFF),
            ])
        }
        // bit depth 8, color type 6 (RGBA), compression 0, filter 0, interlace 0
        chunk.append(contentsOf: [8, 6, 0, 0, 0])
        var length = Data()
        let payloadLength = UInt32(chunk.count - 4)
        length.append(contentsOf: [
            UInt8((payloadLength >> 24) & 0xFF),
            UInt8((payloadLength >> 16) & 0xFF),
            UInt8((payloadLength >> 8) & 0xFF),
            UInt8(payloadLength & 0xFF),
        ])
        data.append(length)
        data.append(chunk)
        data.append(contentsOf: crc32(chunk))
        return data
    }

    private static func crc32(_ chunk: Data) -> [UInt8] {
        var crc: UInt32 = 0xFFFFFFFF
        for byte in chunk {
            crc ^= UInt32(byte)
            for _ in 0..<8 {
                crc = (crc & 1) != 0 ? (crc >> 1) ^ 0xEDB88320 : crc >> 1
            }
        }
        crc ^= 0xFFFFFFFF
        return [
            UInt8((crc >> 24) & 0xFF),
            UInt8((crc >> 16) & 0xFF),
            UInt8((crc >> 8) & 0xFF),
            UInt8(crc & 0xFF),
        ]
    }
}
