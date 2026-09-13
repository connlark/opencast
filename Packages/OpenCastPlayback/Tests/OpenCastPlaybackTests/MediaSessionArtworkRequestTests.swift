import CoreGraphics
import Foundation
@preconcurrency import MediaPlayer
import Testing
@testable import OpenCastPlayback

#if os(macOS)
import AppKit
#else
import UIKit
#endif

@MainActor
@Suite
struct MediaSessionArtworkRequestTests {
    @Test
    func progressUpdatesReuseRequestAndImage() async throws {
        let loader = ImmediateArtworkLoader()
        let url = try #require(URL(string: "https://example.com/artwork.png"))
        loader.artworks[url] = try decodedArtwork()
        let adapter = PlaybackMediaSessionAdapter(artworkLoader: loader)
        let current = episode(duration: 300, artworkURL: url)
        adapter.publish(PlaybackSnapshot(state: .playing, currentEpisode: current, position: 10), resolvedDuration: nil)
        let request = try #require(adapter.artworkRequest)
        let image = try await request.image()
        adapter.publish(PlaybackSnapshot(state: .playing, currentEpisode: current, position: 20), resolvedDuration: nil)
        #expect(adapter.artworkRequest === request)
        #expect(try await request.image() === image)
        #expect(loader.loadCount[url] == 1)
        adapter.clear()
        await #expect(throws: CancellationError.self) { try await request.image() }
    }

    @Test
    func oldEpisodeAndDismissedArtworkRequestsAreCancelled() async throws {
        let loader = ControlledArtworkLoader()
        let firstURL = try #require(URL(string: "https://example.com/first.png"))
        let secondURL = try #require(URL(string: "https://example.com/second.png"))
        let adapter = PlaybackMediaSessionAdapter(artworkLoader: loader)
        adapter.publish(PlaybackSnapshot(currentEpisode: episode(id: "first", duration: 300, artworkURL: firstURL)), resolvedDuration: nil)
        let first = try #require(adapter.artworkRequest)
        await loader.waitForPendingLoad(for: firstURL)
        adapter.publish(PlaybackSnapshot(currentEpisode: episode(id: "second", duration: 300, artworkURL: secondURL)), resolvedDuration: nil)
        let second = try #require(adapter.artworkRequest)
        await loader.waitForPendingLoad(for: secondURL)
        loader.complete(firstURL, with: try decodedArtwork())
        await #expect(throws: CancellationError.self) { try await first.image() }
        #expect(adapter.artworkRequest === second)
        adapter.clear()
        loader.complete(secondURL, with: try decodedArtwork())
        await #expect(throws: CancellationError.self) { try await second.image() }
        #expect(adapter.artworkRequest == nil)
    }

    @Test
    func repeatedEpisodeChangesAtSameURLCancelPreviousRequest() async throws {
        let loader = ImmediateArtworkLoader()
        let url = try #require(URL(string: "https://example.com/shared.png"))
        loader.artworks[url] = try decodedArtwork()
        let adapter = PlaybackMediaSessionAdapter(artworkLoader: loader)
        var previous: MediaSessionArtworkRequest?
        for id in ["one", "two", "one"] {
            adapter.publish(PlaybackSnapshot(currentEpisode: episode(id: id, duration: 300, artworkURL: url)), resolvedDuration: nil)
            if let previous {
                await #expect(throws: CancellationError.self) { try await previous.image() }
            }
            previous = try #require(adapter.artworkRequest)
            _ = try await previous?.image()
        }
        adapter.publish(PlaybackSnapshot(currentEpisode: episode(duration: 300)), resolvedDuration: nil)
        #expect(adapter.artworkRequest == nil)
        await #expect(throws: CancellationError.self) { try await previous?.image() }
    }

    private func decodedArtwork() throws -> MPMediaItemArtwork {
        let context = try #require(CGContext(
            data: nil, width: 16, height: 16, bitsPerComponent: 8, bytesPerRow: 64,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        let cgImage = try #require(context.makeImage())
        #if os(macOS)
        let image = NSImage(cgImage: cgImage, size: CGSize(width: 16, height: 16))
        #else
        let image = UIImage(cgImage: cgImage)
        #endif
        return makeNowPlayingArtwork(from: image)
    }
}
