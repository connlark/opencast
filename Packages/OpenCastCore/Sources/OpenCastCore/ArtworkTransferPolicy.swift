import Foundation

/// No MIME check: CDNs mislabel valid images, and the image decoder is the real content gate.
public enum ArtworkTransferPolicy {
    /// A DoS bound, not a quality bar: real feed artwork tops out around 5 to 10 MB.
    public static let maximumByteCount = 20 * 1_024 * 1_024

    /// ImageIO's thumbnail decode bounds its output but still parses a hostile huge canvas, so the
    /// header's declared dimensions are refused up front.
    public static let maximumPixelDimension = 12_000

    public static let nowPlayingMaximumPixelSize = 2_048

    public static func admitsByteCount(_ byteCount: Int) -> Bool {
        byteCount > 0 && byteCount <= maximumByteCount
    }

    public static func admitsPixelDimensions(width: Int?, height: Int?) -> Bool {
        if let width, width > maximumPixelDimension {
            return false
        }
        if let height, height > maximumPixelDimension {
            return false
        }
        return true
    }
}
