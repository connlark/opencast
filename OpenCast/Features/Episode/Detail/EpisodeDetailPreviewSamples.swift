import Foundation

extension ArtworkPreview {
    /// Warm 8×8 gradient used only by episode-detail `#Preview`s.
    static var previewSample: ArtworkPreview? {
        var rgbData = Data(capacity: 8 * 8 * 3)
        for row in 0..<8 {
            for column in 0..<8 {
                rgbData.append(UInt8(120 + row * 14))
                rgbData.append(UInt8(60 + column * 10))
                rgbData.append(UInt8(180 - row * 12))
            }
        }
        return ArtworkPreview(
            version: ArtworkPreview.currentVersion,
            canonicalArtworkURLKey: "preview-artwork",
            sourceHash: "preview-hash",
            pixelWidth: 8,
            pixelHeight: 8,
            rgbData: rgbData
        )
    }
}

extension EpisodeListItemSnapshot {
    static var previewSample: EpisodeListItemSnapshot {
        EpisodeListItemSnapshot(
            episodeID: "preview-episode",
            podcastID: "https://example.com/feed.xml",
            podcastTitle: "Example Tech Show",
            title: "Ghosts in the Instruction Cache",
            summary: "A tour of the strangest cache-coherency bugs we have ever chased.",
            publishedAt: Date(timeIntervalSince1970: 1_780_000_000),
            duration: 10_020,
            audioURL: "https://example.com/episode-48.mp3",
            artworkURL: nil,
            artworkPreview: .previewSample,
            guid: "preview-episode",
            cachedAt: .now
        )
    }
}
