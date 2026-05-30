import Foundation

nonisolated struct ArtworkDiskCacheEntry: Sendable {
    var data: Data
    var metadata: ArtworkDiskCacheMetadata
}
