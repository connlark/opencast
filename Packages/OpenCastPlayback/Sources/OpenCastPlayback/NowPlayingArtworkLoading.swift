import Foundation
@preconcurrency import MediaPlayer

public protocol NowPlayingArtworkLoading: AnyObject {
    func cachedArtwork(for url: URL) -> MPMediaItemArtwork?
    func artwork(for url: URL) async throws -> MPMediaItemArtwork
}
