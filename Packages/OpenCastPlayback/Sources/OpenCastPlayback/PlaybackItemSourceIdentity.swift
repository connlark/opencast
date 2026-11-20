import Foundation

/// Read from the live `AVPlayerItem`, never episode metadata: only the item proves what is
/// loaded.
public struct PlaybackItemSourceIdentity: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        case localFile
        case networkStream
    }

    public var assetURL: URL
    public var kind: Kind
    /// Nil while AVFoundation reports it unknown or indefinite.
    public var itemDuration: TimeInterval?

    public init(assetURL: URL, kind: Kind, itemDuration: TimeInterval?) {
        self.assetURL = assetURL
        self.kind = kind
        self.itemDuration = itemDuration
    }
}
