import Foundation
import ImageIO
import OpenCastCore

#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// ImageIO downsampling for Now Playing artwork: decodes straight to the
/// largest pixel edge any Now Playing surface renders instead of
/// constructing a full-size image first (security triage P1 #4).
enum NowPlayingArtworkDecoding {
    nonisolated static func downsampledImage(
        from data: Data,
        maximumPixelSize: Int = ArtworkTransferPolicy.nowPlayingMaximumPixelSize
    ) -> NowPlayingArtworkImage? {
        let sourceOptions = [
            kCGImageSourceShouldCache: false
        ] as CFDictionary
        guard let source = CGImageSourceCreateWithData(data as CFData, sourceOptions) else {
            return nil
        }

        // Header-only dimension read; refuses extreme canvases before any
        // pixel work.
        if let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, sourceOptions) as? [CFString: Any] {
            guard ArtworkTransferPolicy.admitsPixelDimensions(
                width: properties[kCGImagePropertyPixelWidth] as? Int,
                height: properties[kCGImagePropertyPixelHeight] as? Int
            ) else {
                return nil
            }
        }

        let thumbnailOptions = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: max(maximumPixelSize, 1)
        ] as CFDictionary
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbnailOptions) else {
            return nil
        }

        #if os(macOS)
        return NSImage(
            cgImage: image,
            size: NSSize(width: image.width, height: image.height)
        )
        #else
        return UIImage(cgImage: image, scale: 1, orientation: .up)
        #endif
    }
}
