import Foundation
import OpenCastCore
import Synchronization

/// Readable from any thread, for system work off the main thread such as a share sheet.
/// The controller's observable state is main-actor only.
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
