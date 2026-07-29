import Foundation

protocol ArtworkPreviewStoring: AnyObject {
    var artworkPreviewVersion: Int? { get set }
    var artworkPreviewCanonicalURLKey: String? { get set }
    var artworkPreviewSourceHash: String? { get set }
    var artworkPreviewPixelWidth: Int? { get set }
    var artworkPreviewPixelHeight: Int? { get set }
    var artworkPreviewRGBData: Data? { get set }
}

extension ArtworkPreviewStoring {
    var artworkPreview: ArtworkPreview? {
        ArtworkPreview(
            storedVersion: artworkPreviewVersion,
            canonicalArtworkURLKey: artworkPreviewCanonicalURLKey,
            sourceHash: artworkPreviewSourceHash,
            pixelWidth: artworkPreviewPixelWidth,
            pixelHeight: artworkPreviewPixelHeight,
            rgbData: artworkPreviewRGBData
        )
    }

    var artworkPreviewStorageSignature: ArtworkPreviewStorageSignature? {
        guard let artworkPreviewVersion,
              let artworkPreviewCanonicalURLKey,
              let artworkPreviewSourceHash,
              let artworkPreviewPixelWidth,
              let artworkPreviewPixelHeight
        else {
            return nil
        }

        return ArtworkPreviewStorageSignature(
            version: artworkPreviewVersion,
            canonicalArtworkURLKey: artworkPreviewCanonicalURLKey,
            sourceHash: artworkPreviewSourceHash,
            pixelWidth: artworkPreviewPixelWidth,
            pixelHeight: artworkPreviewPixelHeight
        )
    }

    @discardableResult
    func storeArtworkPreviewIfChanged(_ preview: ArtworkPreview) -> Bool {
        guard artworkPreviewStorageSignature != preview.storageSignature else {
            return false
        }

        artworkPreviewVersion = preview.version
        artworkPreviewCanonicalURLKey = preview.canonicalArtworkURLKey
        artworkPreviewSourceHash = preview.sourceHash
        artworkPreviewPixelWidth = preview.pixelWidth
        artworkPreviewPixelHeight = preview.pixelHeight
        artworkPreviewRGBData = preview.rgbData
        return true
    }

}

extension PodcastCacheRecord: ArtworkPreviewStoring {}
extension EpisodeCacheRecord: ArtworkPreviewStoring {}
