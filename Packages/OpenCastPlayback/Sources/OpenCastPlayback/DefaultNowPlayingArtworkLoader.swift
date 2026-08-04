import Foundation
@preconcurrency import MediaPlayer
import OpenCastCore

#if os(macOS)
import AppKit
typealias NowPlayingArtworkImage = NSImage
#else
import UIKit
typealias NowPlayingArtworkImage = UIImage
#endif

public final class DefaultNowPlayingArtworkLoader: NowPlayingArtworkLoading {
    private let cache = NSCache<NSURL, MPMediaItemArtwork>()

    public init(cacheLimit: Int = 16) {
        cache.countLimit = cacheLimit
    }

    public func cachedArtwork(for url: URL) -> MPMediaItemArtwork? {
        cache.object(forKey: url as NSURL)
    }

    public func artwork(for url: URL) async throws -> MPMediaItemArtwork {
        if let cachedArtwork = cachedArtwork(for: url) {
            return cachedArtwork
        }

        let image = try await artworkImage(from: url)

        let artwork = makeNowPlayingArtwork(from: image)
        cache.setObject(artwork, forKey: url as NSURL)
        return artwork
    }

    @concurrent
    private func artworkImage(from url: URL) async throws -> NowPlayingArtworkImage {
        let data = try await artworkData(from: url)
        try Task.checkCancellation()

        // Downsampled ImageIO decode to the largest rendered edge — never a
        // full-size image construction (security triage P1 #4).
        guard let image = NowPlayingArtworkDecoding.downsampledImage(from: data) else {
            throw NowPlayingArtworkError.invalidImageData
        }

        return image
    }

    @concurrent
    private func artworkData(from url: URL) async throws -> Data {
        if url.isFileURL {
            return try Data(contentsOf: url)
        }

        let request = URLRequest(
            url: url,
            cachePolicy: .returnCacheDataElseLoad,
            timeoutInterval: 15
        )
        let (data, response) = try await URLSession.shared.data(for: request)
        if let httpResponse = response as? HTTPURLResponse,
           !(200..<300).contains(httpResponse.statusCode) {
            throw NowPlayingArtworkError.unsuccessfulResponse(httpResponse.statusCode)
        }
        guard ArtworkTransferPolicy.admitsByteCount(data.count) else {
            throw NowPlayingArtworkError.invalidImageData
        }

        return data
    }
}
