import Foundation

/// Identity of the asset the player is actually playing, read from the live
/// `AVPlayerItem` rather than episode metadata. Metadata records what was
/// requested; only the item proves what is loaded, and source-identity
/// decisions must never trust the weaker of the two.
public struct PlaybackItemSourceIdentity: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        case localFile
        case networkStream
        case streamingCache
    }

    /// The `AVURLAsset` URL backing the current item. For streaming-cache
    /// items this is the opaque cache scheme, never the enclosure URL.
    public var assetURL: URL
    public var kind: Kind
    /// The item's own timeline duration once AVFoundation has established
    /// it; nil while unknown or indefinite.
    public var itemDuration: TimeInterval?

    public init(assetURL: URL, kind: Kind, itemDuration: TimeInterval?) {
        self.assetURL = assetURL
        self.kind = kind
        self.itemDuration = itemDuration
    }
}
