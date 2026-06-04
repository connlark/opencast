import Foundation

nonisolated struct ArtworkPreviewStorageSignature: Equatable, Sendable {
    var version: Int
    var canonicalArtworkURLKey: String
    var sourceHash: String
    var pixelWidth: Int
    var pixelHeight: Int
}
