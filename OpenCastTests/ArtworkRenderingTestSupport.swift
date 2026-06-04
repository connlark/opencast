import CoreGraphics
import Foundation
import SwiftUI
@testable import OpenCast

func artworkTestPreview(
    width: Int = 8,
    height: Int = 8,
    red: UInt8 = 240,
    green: UInt8 = 40,
    blue: UInt8 = 36
) throws -> ArtworkPreview {
    let rgbData = Data((0..<(width * height)).flatMap { _ in [red, green, blue] })
    guard let preview = ArtworkPreview(
        version: ArtworkPreview.currentVersion,
        canonicalArtworkURLKey: "https://example.com/preview.png",
        sourceHash: "preview-source",
        pixelWidth: width,
        pixelHeight: height,
        rgbData: rgbData
    ) else {
        throw CocoaError(.fileReadCorruptFile)
    }

    return preview
}

func artworkTestWideSplitPreview(width: Int, height: Int) throws -> ArtworkPreview {
    var rgbData: [UInt8] = []
    rgbData.reserveCapacity(width * height * ArtworkPreview.rgbBytesPerPixel)
    for _ in 0..<height {
        for x in 0..<width {
            let isLeftHalf = x < width / 2
            rgbData.append(isLeftHalf ? 255 : 0)
            rgbData.append(0)
            rgbData.append(isLeftHalf ? 0 : 255)
        }
    }

    guard let preview = ArtworkPreview(
        version: ArtworkPreview.currentVersion,
        canonicalArtworkURLKey: "https://example.com/wide-preview.png",
        sourceHash: "wide-preview-source",
        pixelWidth: width,
        pixelHeight: height,
        rgbData: Data(rgbData)
    ) else {
        throw CocoaError(.fileReadCorruptFile)
    }

    return preview
}

func artworkTestTransparentImage(width: Int, height: Int) throws -> UIImage {
    let bytesPerPixel = 4
    let bytesPerRow = width * bytesPerPixel
    let pixels = [UInt8](repeating: 0, count: height * bytesPerRow)
    return try artworkTestImage(width: width, height: height, pixels: pixels, shouldInterpolate: true)
}

func artworkTestWideSplitImage(width: Int, height: Int) throws -> UIImage {
    let bytesPerPixel = 4
    let bytesPerRow = width * bytesPerPixel
    var pixels = [UInt8](repeating: 0, count: height * bytesPerRow)
    for y in 0..<height {
        for x in 0..<width {
            let offset = y * bytesPerRow + x * bytesPerPixel
            let isLeftHalf = x < width / 2
            pixels[offset] = isLeftHalf ? 255 : 0
            pixels[offset + 1] = 0
            pixels[offset + 2] = isLeftHalf ? 0 : 255
            pixels[offset + 3] = 255
        }
    }

    return try artworkTestImage(width: width, height: height, pixels: pixels, shouldInterpolate: false)
}

func artworkTestPixel(in image: UIImage, x: Int, y: Int) throws -> (red: UInt8, green: UInt8, blue: UInt8, alpha: UInt8) {
    let cgImage = try requireCGImage(image)
    let width = cgImage.width
    let height = cgImage.height
    let bytesPerPixel = 4
    let bytesPerRow = width * bytesPerPixel
    var pixels = [UInt8](repeating: 0, count: height * bytesPerRow)

    let didDraw = pixels.withUnsafeMutableBytes { buffer in
        guard let context = CGContext(
            data: buffer.baseAddress,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: artworkTestBitmapInfo().rawValue
        ) else {
            return false
        }

        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
        return true
    }
    guard didDraw else {
        throw CocoaError(.fileReadCorruptFile)
    }

    let offset = y * bytesPerRow + x * bytesPerPixel
    return (
        red: pixels[offset],
        green: pixels[offset + 1],
        blue: pixels[offset + 2],
        alpha: pixels[offset + 3]
    )
}

private func artworkTestImage(
    width: Int,
    height: Int,
    pixels: [UInt8],
    shouldInterpolate: Bool
) throws -> UIImage {
    guard let provider = CGDataProvider(data: Data(pixels) as CFData),
          let image = CGImage(
              width: width,
              height: height,
              bitsPerComponent: 8,
              bitsPerPixel: 32,
              bytesPerRow: width * 4,
              space: CGColorSpaceCreateDeviceRGB(),
              bitmapInfo: artworkTestBitmapInfo(),
              provider: provider,
              decode: nil,
              shouldInterpolate: shouldInterpolate,
              intent: .defaultIntent
          )
    else {
        throw CocoaError(.fileWriteUnknown)
    }

    return UIImage(cgImage: image, scale: 1, orientation: .up)
}

private func requireCGImage(_ image: UIImage) throws -> CGImage {
    guard let cgImage = image.cgImage else {
        throw CocoaError(.fileReadCorruptFile)
    }

    return cgImage
}

private func artworkTestBitmapInfo() -> CGBitmapInfo {
    CGBitmapInfo.byteOrder32Big.union(
        CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue)
    )
}
