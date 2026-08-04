import Foundation

public enum PlaybackSleepTimerMode: Equatable, Sendable {
    case off
    case duration(TimeInterval)
    case endOfEpisode
}
