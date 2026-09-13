import Foundation
import ImageIO
import UniformTypeIdentifiers

nonisolated enum ResumeWidgetArtwork {
    @concurrent
    static func load(_ url: URL?) async -> Data? {
        guard let url,
              let entry = try? await ArtworkDiskCache().cachedEntry(for: url),
              let source = CGImageSourceCreateWithData(entry.data as CFData, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: 320,
                kCGImageSourceShouldCacheImmediately: true,
              ] as CFDictionary)
        else { return nil }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.75] as CFDictionary)
        guard CGImageDestinationFinalize(destination), data.length <= 128 * 1024 else { return nil }
        return data as Data
    }
}
