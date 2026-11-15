import Foundation

/// What an automatic skip did with the skip cue, as the event log records it.
enum PlaybackAutoSkipCueOutcome: Equatable {
    enum Reason: String {
        /// Playback was not requested, so nothing was heard.
        case paused
        /// The skip ends the episode.
        case ending
        /// The previous cue is still sounding.
        case busy
        /// Playback was requested but the controller does not hold the session yet.
        case inactive
        /// No cue could be opened, or it did not start.
        case failed
    }

    case played
    case none(Reason)

    var logSuffix: String {
        switch self {
        case .played:
            " cue=played"
        case .none(let reason):
            " cue=none(\(reason.rawValue))"
        }
    }
}
