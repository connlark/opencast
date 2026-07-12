import Foundation

enum AppRoute: Hashable {
    case podcastDetail(feedURL: String)
    case episodeDetail(id: String)
    case episodeTranscript(id: String)
    case adDetectionQueue
}
