import Foundation

nonisolated struct ArtworkSource: Sendable {
    let data: Data
    let sourceHash: String
    let metadata: ArtworkDiskCacheMetadata
    let firstDecode: DecodedArtwork
}
