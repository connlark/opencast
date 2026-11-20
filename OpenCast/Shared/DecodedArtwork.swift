import SwiftUI

nonisolated struct DecodedArtwork: Sendable {
    var image: UIImage
    var contentKey: String
    /// Hex SHA-256 of the source bytes.
    var sourceHash: String
    static func contentKey(for request: ArtworkRequest, sourceHash: String) -> String {
        "\(sourceHash)#\(request.pixelWidth)x\(request.pixelHeight)"
    }

    static func sourceHash(fromContentKey key: String) -> Substring {
        key[..<(key.lastIndex(of: "#") ?? key.endIndex)]
    }
}
