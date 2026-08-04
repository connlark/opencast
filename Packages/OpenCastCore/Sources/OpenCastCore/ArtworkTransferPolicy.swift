import Foundation

/// One app-wide admission policy for fetched artwork (security triage P1 #4):
/// a network byte ceiling and a header-declared pixel ceiling, applied on
/// receive — before decode, before any cache — so oversized payloads never
/// reach the expensive stages. Shared by the app's artwork loader and the
/// Now Playing loader so both transfer paths enforce the same bounds.
///
/// Deliberately no MIME policing: real CDNs mislabel valid images (pinned by
/// "MIME mismatch does not override image byte validation" in the loader
/// suite), and the image decoder is the actual content gate.
public enum ArtworkTransferPolicy {
    /// Generous DoS bound, not a quality bar: real feed artwork tops out
    /// around 5–10 MB; past this the payload is hostile or broken.
    public static let maximumByteCount = 20 * 1_024 * 1_024

    /// Header-declared dimension ceiling. ImageIO's thumbnail decode already
    /// bounds decoded output, but parsing a hostile many-hundred-megapixel
    /// canvas is still work worth refusing up front.
    public static let maximumPixelDimension = 12_000

    /// Largest pixel edge any Now Playing surface renders (lock screen /
    /// CarPlay); the full-size decode downsamples to this.
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
