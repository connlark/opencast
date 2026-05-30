import CoreGraphics
import Foundation
import OpenCastCore

nonisolated struct ArtworkRequest: Hashable {
    let url: URL
    let pixelWidth: Int
    let pixelHeight: Int

    private let canonicalURLString: String

    init(url: URL, targetPixelSize: CGSize) {
        self.url = url
        pixelWidth = max(Int(targetPixelSize.width.rounded(.up)), 1)
        pixelHeight = max(Int(targetPixelSize.height.rounded(.up)), 1)
        canonicalURLString = URLCanonicalizer.canonicalString(for: url)
    }

    var pixelSize: CGSize {
        CGSize(width: pixelWidth, height: pixelHeight)
    }

    var imageKey: String {
        canonicalURLString
    }

    var cacheKey: String {
        "\(canonicalURLString)#\(pixelWidth)x\(pixelHeight)"
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(canonicalURLString)
        hasher.combine(pixelWidth)
        hasher.combine(pixelHeight)
    }

    static func == (lhs: ArtworkRequest, rhs: ArtworkRequest) -> Bool {
        lhs.canonicalURLString == rhs.canonicalURLString
            && lhs.pixelWidth == rhs.pixelWidth
            && lhs.pixelHeight == rhs.pixelHeight
    }
}
