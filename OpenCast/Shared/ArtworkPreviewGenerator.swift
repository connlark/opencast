import CoreGraphics
import CryptoKit
import Foundation
import ImageIO

nonisolated struct ArtworkPreviewGenerator {
    typealias ThreadObserver = @Sendable (_ isMainThread: Bool) -> Void

    @concurrent
    static func generate(
        from data: Data,
        canonicalArtworkURLKey: String,
        threadObserver: ThreadObserver? = nil
    ) async -> ArtworkPreview? {
        guard !Task.isCancelled else {
            return nil
        }

        threadObserver?(isRunningOnMainThread())
        return makePreview(from: data, canonicalArtworkURLKey: canonicalArtworkURLKey)
    }

    private nonisolated static func isRunningOnMainThread() -> Bool {
        Thread.isMainThread
    }

    private nonisolated static func makePreview(
        from data: Data,
        canonicalArtworkURLKey: String
    ) -> ArtworkPreview? {
        let sourceOptions = [
            kCGImageSourceShouldCache: false
        ] as CFDictionary
        guard let source = CGImageSourceCreateWithData(data as CFData, sourceOptions) else {
            return nil
        }

        let thumbnailOptions = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: 64
        ] as CFDictionary
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbnailOptions) else {
            return nil
        }

        let previewSize = previewPixelSize(for: image)
        guard let rgbData = makeRGBGrid(
            from: image,
            width: previewSize.width,
            height: previewSize.height
        ) else {
            return nil
        }

        return ArtworkPreview(
            version: ArtworkPreview.currentVersion,
            canonicalArtworkURLKey: canonicalArtworkURLKey,
            sourceHash: sourceHash(for: data),
            pixelWidth: previewSize.width,
            pixelHeight: previewSize.height,
            rgbData: rgbData
        )
    }

    private nonisolated static func previewPixelSize(for image: CGImage) -> (width: Int, height: Int) {
        let imageWidth = max(image.width, 1)
        let imageHeight = max(image.height, 1)
        let maxPixelEdge = ArtworkPreview.maxPixelEdge

        if imageWidth >= imageHeight {
            let height = max(
                Int((Double(maxPixelEdge) * Double(imageHeight) / Double(imageWidth)).rounded()),
                1
            )
            return (width: maxPixelEdge, height: min(height, maxPixelEdge))
        }

        let width = max(
            Int((Double(maxPixelEdge) * Double(imageWidth) / Double(imageHeight)).rounded()),
            1
        )
        return (width: min(width, maxPixelEdge), height: maxPixelEdge)
    }

    private nonisolated static func makeRGBGrid(from image: CGImage, width: Int, height: Int) -> Data? {
        let bytesPerPixel = 4
        let bytesPerRow = width * bytesPerPixel
        var rgbaPixels = [UInt8](repeating: 0, count: height * bytesPerRow)
        let bitmapInfo = CGBitmapInfo.byteOrder32Big.union(
            CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue)
        )

        let didDraw = rgbaPixels.withUnsafeMutableBytes { buffer in
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

            context.interpolationQuality = .medium
            context.draw(image, in: aspectFillRect(for: image, width: width, height: height))
            return true
        }
        guard didDraw else {
            return nil
        }

        var rgbData = Data()
        rgbData.reserveCapacity(ArtworkPreview.requiredRGBByteCount(width: width, height: height))
        for offset in stride(from: 0, to: rgbaPixels.count, by: bytesPerPixel) {
            rgbData.append(rgbaPixels[offset])
            rgbData.append(rgbaPixels[offset + 1])
            rgbData.append(rgbaPixels[offset + 2])
        }
        return rgbData
    }

    private nonisolated static func aspectFillRect(for image: CGImage, width: Int, height: Int) -> CGRect {
        let targetSize = CGSize(width: CGFloat(width), height: CGFloat(height))
        let imageSize = CGSize(width: CGFloat(image.width), height: CGFloat(image.height))
        let scale = max(targetSize.width / imageSize.width, targetSize.height / imageSize.height)
        let scaledSize = CGSize(width: imageSize.width * scale, height: imageSize.height * scale)
        return CGRect(
            x: (targetSize.width - scaledSize.width) / 2,
            y: (targetSize.height - scaledSize.height) / 2,
            width: scaledSize.width,
            height: scaledSize.height
        )
    }

    private nonisolated static func sourceHash(for data: Data) -> String {
        let digest = SHA256.hash(data: data)
        return digest.map { byte in
            let hex = String(byte, radix: 16)
            return hex.count == 1 ? "0\(hex)" : hex
        }.joined()
    }
}
