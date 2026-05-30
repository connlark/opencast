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
struct NowPlayingInfoPublisherTests {
    @Test
    func includesArtworkWhenLoaderReturnsArtwork() async throws {
        let infoCenter = FakeNowPlayingInfoCenter()
        let loader = ImmediateArtworkLoader()
        let artworkURL = try #require(URL(string: "https://example.com/artwork.png"))
        let artwork = makeArtwork()
        loader.artworks[artworkURL] = artwork
        let publisher = NowPlayingInfoPublisher(infoCenter: infoCenter, artworkLoader: loader)

        publisher.publish(
            PlaybackSnapshot(
                state: .playing,
                currentEpisode: episode(duration: 300, artworkURL: artworkURL),
                position: 12,
                duration: 300
            ),
            resolvedDuration: 300
        )

        await publisher.inFlightArtworkTask?.value
        #expect(loader.loadCount[artworkURL] == 1)
        #expect(infoCenter.artwork === artwork)
    }

    @Test
    func doesNotRefetchArtworkForProgressOnlyUpdates() async throws {
        let infoCenter = FakeNowPlayingInfoCenter()
        let loader = ImmediateArtworkLoader()
        let artworkURL = try #require(URL(string: "https://example.com/artwork.png"))
        let artwork = makeArtwork()
        loader.artworks[artworkURL] = artwork
        let publisher = NowPlayingInfoPublisher(infoCenter: infoCenter, artworkLoader: loader)
        let currentEpisode = episode(duration: 300, artworkURL: artworkURL)

        publisher.publish(
            PlaybackSnapshot(state: .playing, currentEpisode: currentEpisode, position: 10, duration: 300),
            resolvedDuration: 300
        )
        await publisher.inFlightArtworkTask?.value

        publisher.publish(
            PlaybackSnapshot(state: .playing, currentEpisode: currentEpisode, position: 20, duration: 300),
            resolvedDuration: 300
        )

        #expect(loader.loadCount[artworkURL] == 1)
        #expect(infoCenter.artwork === artwork)
        #expect(doubleValue(infoCenter.nowPlayingInfo?[MPNowPlayingInfoPropertyElapsedPlaybackTime]) == 20)
    }

    @Test
    func staleArtworkResultDoesNotOverwriteNewerEpisode() async throws {
        let infoCenter = FakeNowPlayingInfoCenter()
        let loader = ControlledArtworkLoader()
        let firstURL = try #require(URL(string: "https://example.com/first.png"))
        let secondURL = try #require(URL(string: "https://example.com/second.png"))
        let firstArtwork = makeArtwork()
        let secondArtwork = makeArtwork()
        let publisher = NowPlayingInfoPublisher(infoCenter: infoCenter, artworkLoader: loader)

        publisher.publish(
            PlaybackSnapshot(
                state: .playing,
                currentEpisode: episode(id: "first", duration: 300, artworkURL: firstURL),
                position: 10,
                duration: 300
            ),
            resolvedDuration: 300
        )
        await loader.waitForPendingLoad(for: firstURL)
        let firstArtworkTask = publisher.inFlightArtworkTask

        publisher.publish(
            PlaybackSnapshot(
                state: .playing,
                currentEpisode: episode(id: "second", duration: 300, artworkURL: secondURL),
                position: 20,
                duration: 300
            ),
            resolvedDuration: 300
        )
        await loader.waitForPendingLoad(for: secondURL)
        let secondArtworkTask = publisher.inFlightArtworkTask

        loader.complete(firstURL, with: firstArtwork)
        await firstArtworkTask?.value
        #expect(infoCenter.artwork !== firstArtwork)

        loader.complete(secondURL, with: secondArtwork)
        await secondArtworkTask?.value
        #expect(infoCenter.artwork === secondArtwork)
        #expect(infoCenter.artwork !== firstArtwork)
    }
}

@MainActor
final class FakeNowPlayingInfoCenter: NowPlayingInfoPublishing {
    var nowPlayingInfo: [String: Any]?

    var artwork: MPMediaItemArtwork? {
        nowPlayingInfo?[MPMediaItemPropertyArtwork] as? MPMediaItemArtwork
    }
}

@MainActor
final class ImmediateArtworkLoader: NowPlayingArtworkLoading {
    var artworks: [URL: MPMediaItemArtwork] = [:]
    var loadCount: [URL: Int] = [:]

    func cachedArtwork(for url: URL) -> MPMediaItemArtwork? {
        nil
    }

    func artwork(for url: URL) async throws -> MPMediaItemArtwork {
        loadCount[url, default: 0] += 1
        guard let artwork = artworks[url] else {
            throw TestArtworkError.missingArtwork
        }

        return artwork
    }
}

@MainActor
final class ControlledArtworkLoader: NowPlayingArtworkLoading {
    private var continuations: [URL: CheckedContinuation<MPMediaItemArtwork, Error>] = [:]
    private var pendingLoadWaiters: [URL: [CheckedContinuation<Void, Never>]] = [:]

    func cachedArtwork(for url: URL) -> MPMediaItemArtwork? {
        nil
    }

    func artwork(for url: URL) async throws -> MPMediaItemArtwork {
        try await withCheckedThrowingContinuation { continuation in
            continuations[url] = continuation
            let waiters = pendingLoadWaiters.removeValue(forKey: url) ?? []
            for waiter in waiters {
                waiter.resume()
            }
        }
    }

    func waitForPendingLoad(for url: URL) async {
        if continuations[url] != nil {
            return
        }

        await withCheckedContinuation { continuation in
            pendingLoadWaiters[url, default: []].append(continuation)
        }
    }

    func complete(_ url: URL, with artwork: MPMediaItemArtwork) {
        continuations.removeValue(forKey: url)?.resume(returning: artwork)
    }
}

enum TestArtworkError: Error {
    case missingArtwork
}

func makeArtwork() -> MPMediaItemArtwork {
    #if os(macOS)
    let image = NSImage(size: CGSize(width: 64, height: 64))
    #else
    let renderer = UIGraphicsImageRenderer(size: CGSize(width: 64, height: 64))
    let image = renderer.image { context in
        UIColor.systemTeal.setFill()
        context.fill(CGRect(origin: .zero, size: CGSize(width: 64, height: 64)))
    }
    #endif

    return makeNowPlayingArtwork(from: image)
}
