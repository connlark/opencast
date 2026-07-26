import CoreGraphics
import SwiftUI

/// The car display's list-image geometry. List rows get their own pixel size —
/// and therefore their own artwork cache entries — rather than reusing the
/// 1024² Now Playing image.
nonisolated struct CarPlayArtworkSizing: Equatable, Sendable {
    static let fallback = CarPlayArtworkSizing(
        pointSize: CGSize(width: 44, height: 44),
        displayScale: 2
    )

    let pointSize: CGSize
    let displayScale: Double

    var pixelSize: CGSize {
        CGSize(width: pointSize.width * displayScale, height: pointSize.height * displayScale)
    }

    /// Decoded artwork carries a scale of 1. Handing that straight to a 2× or 3×
    /// head unit renders it at a fraction of the row height.
    func matchingCarScale(_ image: UIImage) -> UIImage {
        guard let cgImage = image.cgImage, displayScale > 0, image.scale != displayScale else {
            return image
        }

        return UIImage(cgImage: cgImage, scale: displayScale, orientation: image.imageOrientation)
    }
}
