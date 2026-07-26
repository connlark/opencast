import CarPlay
import Foundation

/// A rendered row still waiting for its exact-size artwork.
struct CarPlayArtworkTarget {
    let item: CPListItem
    let artworkURL: URL
    let cacheKind: ArtworkCacheKind
}
