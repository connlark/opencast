import Foundation
#if os(iOS)
import NowPlaying
#endif

final class SystemPlaybackMediaSession {
    #if os(iOS)
    private let adapter: PlaybackMediaSessionAdapter
    private let session: MediaSession<PlaybackMediaSessionAdapter>
    #else
    // The host package intentionally keeps its macOS 15 deployment floor.
    private let publisher: NowPlayingInfoPublisher
    private let commands = RemoteCommandController()
    #endif

    init(artworkLoader: any NowPlayingArtworkLoading) {
        #if os(iOS)
        let adapter = PlaybackMediaSessionAdapter(artworkLoader: artworkLoader)
        self.adapter = adapter
        session = MediaSession(adapter)
        #else
        publisher = NowPlayingInfoPublisher(artworkLoader: artworkLoader)
        #endif
    }

    func install(_ handlers: RemoteCommandHandlers) {
        #if os(iOS)
        adapter.install(handlers)
        #else
        commands.install(handlers)
        #endif
    }

    func publish(_ snapshot: PlaybackSnapshot, resolvedDuration: TimeInterval?) {
        #if os(iOS)
        adapter.publish(snapshot, resolvedDuration: resolvedDuration)
        #else
        publisher.publish(snapshot, resolvedDuration: resolvedDuration)
        commands.updateAvailability(for: snapshot, resolvedDuration: resolvedDuration)
        #endif
    }

    func clear() {
        #if os(iOS)
        adapter.clear()
        #else
        publisher.clear()
        commands.updateAvailability(for: PlaybackSnapshot(), resolvedDuration: nil)
        #endif
    }

    func setSkipIntervals(backward: TimeInterval, forward: TimeInterval) {
        #if os(iOS)
        adapter.setSkipIntervals(backward: backward, forward: forward)
        #else
        commands.setSkipIntervals(backward: backward, forward: forward)
        #endif
    }
}
