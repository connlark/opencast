import Foundation

enum PlaybackMediaCommand {
    case play, pause, togglePlayPause, skipForward, skipBackward, next, previous
    case seek(TimeInterval)
    case changeRate(Float)

    enum Kind: CaseIterable {
        case play, pause, togglePlayPause, skipForward, skipBackward, next, previous, seek, changeRate
    }

    var kind: Kind {
        switch self {
        case .play: .play
        case .pause: .pause
        case .togglePlayPause: .togglePlayPause
        case .skipForward: .skipForward
        case .skipBackward: .skipBackward
        case .next: .next
        case .previous: .previous
        case .seek: .seek
        case .changeRate: .changeRate
        }
    }
}
