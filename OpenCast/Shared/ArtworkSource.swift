import Foundation

/// A source shared until decoding, preview generation and disk publication finish.
nonisolated struct ArtworkSource: Sendable {
    let data: Data
    let sourceHash: String
    let metadata: ArtworkDiskCacheMetadata
    let firstDecode: DecodedArtwork
}
