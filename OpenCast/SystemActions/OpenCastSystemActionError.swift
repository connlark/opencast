import Foundation

nonisolated enum OpenCastSystemActionError: Error, CustomLocalizedStringResourceConvertible {
    case unavailable
    case noUnplayedEpisode
    case libraryUnavailable
    case playbackFailed
    case queueFailed
    case queryTooLarge
    case unsupportedPlaybackOptions

    var localizedStringResource: LocalizedStringResource {
        switch self {
        case .unavailable: "This content is no longer available in OpenCast."
        case .noUnplayedEpisode: "This show has no cached unplayed episodes."
        case .libraryUnavailable: "OpenCast could not load your library. Open the app and try again."
        case .playbackFailed: "OpenCast could not start playback."
        case .queueFailed: "OpenCast could not save Up Next."
        case .queryTooLarge: "Choose up to 100 items at a time."
        case .unsupportedPlaybackOptions: "OpenCast cannot apply those playback or queue options to this content."
        }
    }
}
