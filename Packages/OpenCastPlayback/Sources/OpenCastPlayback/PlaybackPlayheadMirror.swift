import Foundation
import OpenCastCore
import Synchronization

/// The current episode and its position, readable from any thread, for work
/// the system runs off the main thread (a share sheet minting a "Share from
/// Current Time" link). The controller's observable state is main-actor only.
public nonisolated final class PlaybackPlayheadMirror: Sendable {
    public struct Reading: Equatable, Sendable {
        public let episodeID: EpisodeID?
        public let position: TimeInterval
    }

    private let reading = Mutex(Reading(episodeID: nil, position: 0))

    func update(_ newReading: Reading) {
        reading.withLock {
            $0 = newReading
        }
    }

    public func read() -> Reading {
        reading.withLock { $0 }
    }
}
