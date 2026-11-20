import Foundation

enum PlaybackAutoSkipCueOutcome: Equatable {
    enum Reason: String {
        case paused
        case ending
        case busy
        case inactive
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
