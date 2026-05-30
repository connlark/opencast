import CoreGraphics
import SwiftUI
import Testing
@testable import OpenCast

@MainActor
@Suite("Artwork placeholder visual")
struct ArtworkPlaceholderVisualTests {
    @Test("Transparent loaded artwork leaves parent background visible")
    func transparentLoadedArtworkLeavesParentBackgroundVisible() throws {
        let renderer = ImageRenderer(
            content: ArtworkPlaceholderVisual(title: "Transparent", image: try transparentImage(width: 24, height: 24))
                .frame(width: 24, height: 24)
                .background(.white)
        )
        renderer.scale = 1
        renderer.isOpaque = true

        let renderedImage = try #require(renderer.uiImage)
        let pixel = try pixel(in: renderedImage, x: 12, y: 12)

        #expect(pixel.red > 245)
        #expect(pixel.green > 245)
        #expect(pixel.blue > 245)
        #expect(pixel.alpha == 255)
    }

    private func transparentImage(width: Int, height: Int) throws -> UIImage {
        let bytesPerPixel = 4
        let bytesPerRow = width * bytesPerPixel
        let pixels = [UInt8](repeating: 0, count: height * bytesPerRow)
        let bitmapInfo = CGBitmapInfo.byteOrder32Big.union(
            CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue)
        )

        guard let provider = CGDataProvider(data: Data(pixels) as CFData),
              let image = CGImage(
                width: width,
                height: height,
                bitsPerComponent: 8,
                bitsPerPixel: bytesPerPixel * 8,
                bytesPerRow: bytesPerRow,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: bitmapInfo,
                provider: provider,
                decode: nil,
                shouldInterpolate: true,
                intent: .defaultIntent
              )
        else {
            throw CocoaError(.fileWriteUnknown)
        }

        return UIImage(cgImage: image, scale: 1, orientation: .up)
    }

    private func pixel(in image: UIImage, x: Int, y: Int) throws -> Pixel {
        let cgImage = try #require(image.cgImage)
        let width = cgImage.width
        let height = cgImage.height
        let bytesPerPixel = 4
        let bytesPerRow = width * bytesPerPixel
        var pixels = [UInt8](repeating: 0, count: height * bytesPerRow)
        let bitmapInfo = CGBitmapInfo.byteOrder32Big.union(
            CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue)
        )

        let didDraw = pixels.withUnsafeMutableBytes { buffer in
            guard let context = CGContext(
                data: buffer.baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: bytesPerRow,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: bitmapInfo.rawValue
            ) else {
                return false
            }

            context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard didDraw else {
            throw CocoaError(.fileReadCorruptFile)
        }

        let offset = (y * width + x) * bytesPerPixel
        return Pixel(
            red: pixels[offset],
            green: pixels[offset + 1],
            blue: pixels[offset + 2],
            alpha: pixels[offset + 3]
        )
    }

    private struct Pixel {
        let red: UInt8
        let green: UInt8
        let blue: UInt8
        let alpha: UInt8
    }
}
