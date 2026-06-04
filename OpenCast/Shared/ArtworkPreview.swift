import Foundation
import OpenCastCore

nonisolated struct ArtworkPreview: Codable, Equatable, Sendable {
    static let currentVersion = 2
    static let maxPixelEdge = 8
    static let fixedPixelWidth = 8
    static let fixedPixelHeight = 8
    static let rgbBytesPerPixel = 3

    var version: Int
    var canonicalArtworkURLKey: String
    var sourceHash: String
    var pixelWidth: Int
    var pixelHeight: Int
    var rgbData: Data

    private enum CodingKeys: String, CodingKey {
        case version
        case canonicalArtworkURLKey
        case sourceHash
        case pixelWidth
        case pixelHeight
        case rgbData
    }

    init?(
        version: Int,
        canonicalArtworkURLKey: String,
        sourceHash: String,
        pixelWidth: Int,
        pixelHeight: Int,
        rgbData: Data
    ) {
        guard version == Self.currentVersion,
              pixelWidth > 0,
              pixelHeight > 0,
              pixelWidth <= Self.maxPixelEdge,
              pixelHeight <= Self.maxPixelEdge,
              max(pixelWidth, pixelHeight) == Self.maxPixelEdge,
              rgbData.count == Self.requiredRGBByteCount(width: pixelWidth, height: pixelHeight),
              !canonicalArtworkURLKey.isEmpty,
              !sourceHash.isEmpty
        else {
            return nil
        }

        self.version = version
        self.canonicalArtworkURLKey = canonicalArtworkURLKey
        self.sourceHash = sourceHash
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.rgbData = rgbData
    }

    init?(
        storedVersion: Int?,
        canonicalArtworkURLKey: String?,
        sourceHash: String?,
        pixelWidth: Int?,
        pixelHeight: Int?,
        rgbData: Data?
    ) {
        guard let storedVersion,
              let canonicalArtworkURLKey,
              let sourceHash,
              let pixelWidth,
              let pixelHeight,
              let rgbData
        else {
            return nil
        }

        self.init(
            version: storedVersion,
            canonicalArtworkURLKey: canonicalArtworkURLKey,
            sourceHash: sourceHash,
            pixelWidth: pixelWidth,
            pixelHeight: pixelHeight,
            rgbData: rgbData
        )
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let version = try container.decode(Int.self, forKey: .version)
        let canonicalArtworkURLKey = try container.decode(String.self, forKey: .canonicalArtworkURLKey)
        let sourceHash = try container.decode(String.self, forKey: .sourceHash)
        let pixelWidth = try container.decode(Int.self, forKey: .pixelWidth)
        let pixelHeight = try container.decode(Int.self, forKey: .pixelHeight)
        let rgbData = try container.decode(Data.self, forKey: .rgbData)

        guard let preview = ArtworkPreview(
            version: version,
            canonicalArtworkURLKey: canonicalArtworkURLKey,
            sourceHash: sourceHash,
            pixelWidth: pixelWidth,
            pixelHeight: pixelHeight,
            rgbData: rgbData
        ) else {
            throw DecodingError.dataCorruptedError(
                forKey: .rgbData,
                in: container,
                debugDescription: "Artwork preview metadata is not a supported RGB grid."
            )
        }

        self = preview
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(version, forKey: .version)
        try container.encode(canonicalArtworkURLKey, forKey: .canonicalArtworkURLKey)
        try container.encode(sourceHash, forKey: .sourceHash)
        try container.encode(pixelWidth, forKey: .pixelWidth)
        try container.encode(pixelHeight, forKey: .pixelHeight)
        try container.encode(rgbData, forKey: .rgbData)
    }

    var storageSignature: ArtworkPreviewStorageSignature {
        ArtworkPreviewStorageSignature(
            version: version,
            canonicalArtworkURLKey: canonicalArtworkURLKey,
            sourceHash: sourceHash,
            pixelWidth: pixelWidth,
            pixelHeight: pixelHeight
        )
    }

    func matchesArtworkURLString(_ artworkURLString: String?) -> Bool {
        canonicalArtworkURLKey == Self.canonicalArtworkURLKey(for: artworkURLString)
    }

    static func canonicalArtworkURLKey(for artworkURLString: String?) -> String? {
        guard let artworkURLString,
              let artworkURL = URL(string: artworkURLString)
        else {
            return nil
        }

        return URLCanonicalizer.canonicalString(for: artworkURL)
    }

    static func requiredRGBByteCount(width: Int, height: Int) -> Int {
        max(width, 0) * max(height, 0) * rgbBytesPerPixel
    }
}
