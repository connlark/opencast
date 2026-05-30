import Foundation

enum EpisodePlaybackSource {
    case stream
    case downloaded(EpisodeDownloadRecord)
}
