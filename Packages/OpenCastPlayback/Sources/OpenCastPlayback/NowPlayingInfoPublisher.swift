import Foundation
@preconcurrency import MediaPlayer
import OpenCastCore
import OSLog

final class NowPlayingInfoPublisher {
    private static let logger = Logger(subsystem: "OpenCastPlayback", category: "NowPlayingInfoPublisher")
    private let infoCenter: NowPlayingInfoPublishing
    private let artworkLoader: NowPlayingArtworkLoading
    private let builder: NowPlayingInfoBuilder

    private var artworkTask: Task<Void, Never>?
    private var currentArtwork: MPMediaItemArtwork?
    private var currentArtworkURL: URL?
    private var currentEpisodeID: EpisodeID?
    private var latestSnapshot: PlaybackSnapshot?
    private var latestResolvedDuration: TimeInterval?
    private var latestPublishedSnapshot: PlaybackSnapshot?
    private var latestPublishedResolvedDuration: TimeInterval?
    private var latestPublishedHadArtwork = false

    init(
        infoCenter: NowPlayingInfoPublishing = SystemNowPlayingInfoCenter(),
        artworkLoader: NowPlayingArtworkLoading = DefaultNowPlayingArtworkLoader(),
        builder: NowPlayingInfoBuilder = NowPlayingInfoBuilder()
    ) {
        self.infoCenter = infoCenter
        self.artworkLoader = artworkLoader
        self.builder = builder
    }

    var inFlightArtworkTask: Task<Void, Never>? {
        artworkTask
    }

    isolated deinit {
        artworkTask?.cancel()
        infoCenter.nowPlayingInfo = nil
    }

    func publish(_ snapshot: PlaybackSnapshot, resolvedDuration: TimeInterval?) {
        latestSnapshot = snapshot
        latestResolvedDuration = resolvedDuration

        guard let episode = snapshot.currentEpisode else {
            clear()
            return
        }

        prepareArtwork(for: episode)
        publishInfoIfChanged(for: snapshot, resolvedDuration: resolvedDuration)
    }

    func clear() {
        artworkTask?.cancel()
        artworkTask = nil
        currentArtwork = nil
        currentArtworkURL = nil
        currentEpisodeID = nil
        latestSnapshot = nil
        latestResolvedDuration = nil
        latestPublishedSnapshot = nil
        latestPublishedResolvedDuration = nil
        latestPublishedHadArtwork = false
        infoCenter.nowPlayingInfo = nil
    }

    private func prepareArtwork(for episode: Episode) {
        guard let artworkURL = episode.artworkURL else {
            artworkTask?.cancel()
            artworkTask = nil
            currentArtwork = nil
            currentArtworkURL = nil
            currentEpisodeID = episode.id
            return
        }

        if currentEpisodeID == episode.id, currentArtworkURL == artworkURL {
            return
        }

        artworkTask?.cancel()
        currentArtworkURL = artworkURL
        currentEpisodeID = episode.id
        currentArtwork = artworkLoader.cachedArtwork(for: artworkURL)

        guard currentArtwork == nil else {
            artworkTask = nil
            return
        }

        artworkTask = Task { [weak self, artworkLoader] in
            do {
                let artwork = try await artworkLoader.artwork(for: artworkURL)
                try Task.checkCancellation()
                guard let self else {
                    return
                }

                applyArtwork(artwork, for: episode.id, artworkURL: artworkURL)
            } catch is CancellationError {
                return
            } catch {
                Self.logger.debug("Artwork load failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    private func applyArtwork(
        _ artwork: MPMediaItemArtwork,
        for episodeID: EpisodeID,
        artworkURL: URL
    ) {
        guard currentEpisodeID == episodeID,
              currentArtworkURL == artworkURL,
              let latestSnapshot,
              latestSnapshot.currentEpisode?.id == episodeID
        else {
            return
        }

        currentArtwork = artwork
        publishInfoIfChanged(for: latestSnapshot, resolvedDuration: latestResolvedDuration)
    }

    private func publishInfoIfChanged(
        for snapshot: PlaybackSnapshot?,
        resolvedDuration: TimeInterval?
    ) {
        guard let snapshot else {
            return
        }

        let hasArtwork = currentArtwork != nil
        guard latestPublishedSnapshot != snapshot
            || latestPublishedResolvedDuration != resolvedDuration
            || latestPublishedHadArtwork != hasArtwork
        else {
            return
        }

        infoCenter.nowPlayingInfo = builder.info(
            for: snapshot,
            resolvedDuration: resolvedDuration,
            artwork: currentArtwork
        )
        latestPublishedSnapshot = snapshot
        latestPublishedResolvedDuration = resolvedDuration
        latestPublishedHadArtwork = hasArtwork
    }
}
