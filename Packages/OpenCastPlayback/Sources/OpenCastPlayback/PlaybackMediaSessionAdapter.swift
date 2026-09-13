import Foundation
import Observation

@Observable
final class PlaybackMediaSessionAdapter {
    let id = UUID().uuidString
    private(set) var values: PlaybackMediaSessionValues?
    private(set) var snapshotTimestamp = Date.now
    private(set) var artworkRequest: MediaSessionArtworkRequest?
    private(set) var skipBackwardInterval = PlaybackSkipInterval.backward
    private(set) var skipForwardInterval = PlaybackSkipInterval.forward
    @ObservationIgnored private let artworkLoader: any NowPlayingArtworkLoading
    @ObservationIgnored private var handlers: RemoteCommandHandlers?

    enum CommandError: Error, Equatable {
        case unavailable, invalidValue
    }

    init(artworkLoader: any NowPlayingArtworkLoading) {
        self.artworkLoader = artworkLoader
    }

    isolated deinit {
        artworkRequest?.cancel()
    }

    func install(_ handlers: RemoteCommandHandlers) {
        guard self.handlers == nil else {
            assertionFailure("Media session commands installed twice")
            return
        }
        self.handlers = handlers
    }

    func publish(_ snapshot: PlaybackSnapshot, resolvedDuration: TimeInterval?) {
        let updated = PlaybackMediaSessionValues(snapshot, resolvedDuration: resolvedDuration)
        guard updated != values else { return }
        if updated?.episodeID != values?.episodeID || updated?.artworkURL != values?.artworkURL {
            artworkRequest?.cancel()
            artworkRequest = if let updated, let url = updated.artworkURL {
                MediaSessionArtworkRequest(
                    id: updated.episodeID.rawValue + ":" + url.absoluteString,
                    url: url,
                    loader: artworkLoader
                )
            } else {
                nil
            }
        }
        snapshotTimestamp = .now
        values = updated
    }

    func clear() {
        artworkRequest?.cancel()
        artworkRequest = nil
        values = nil
    }

    func setSkipIntervals(backward: TimeInterval, forward: TimeInterval) {
        guard backward.isFinite, backward > 0, forward.isFinite, forward > 0 else { return }
        if skipBackwardInterval != backward { skipBackwardInterval = backward }
        if skipForwardInterval != forward { skipForwardInterval = forward }
    }

    var availableCommands: Set<PlaybackMediaCommand.Kind> {
        values?.availableCommands ?? []
    }

    func perform(_ command: PlaybackMediaCommand) throws {
        guard let values, let handlers, availableCommands.contains(command.kind) else {
            throw CommandError.unavailable
        }
        switch command {
        case .play: handlers.play()
        case .pause: handlers.pause()
        case .togglePlayPause: handlers.togglePlayPause()
        case .skipForward: handlers.skipForward()
        case .skipBackward, .previous: handlers.skipBackward()
        case .next: handlers.nextTrack()
        case .seek(let position):
            guard position.isFinite else { throw CommandError.invalidValue }
            handlers.seek(clampPlaybackPosition(position, to: values.duration))
        case .changeRate(let rate):
            guard rate.isFinite, rate > 0 else { throw CommandError.invalidValue }
            handlers.changeRate(rate)
        }
    }
}
