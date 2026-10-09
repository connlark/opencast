import SwiftUI

/// A decoded artwork image with the identity the loader caches it under.
nonisolated struct DecodedArtwork: Sendable {
    var image: UIImage
    /// Content hash plus pixel size; the memory cache's pixel-store key.
    var contentKey: String
    /// Hex SHA-256 of the source bytes, shared with the generated preview.
    var sourceHash: String
    static func contentKey(for request: ArtworkRequest, sourceHash: String) -> String {
        "\(sourceHash)#\(request.pixelWidth)x\(request.pixelHeight)"
    }
}
