import Foundation

enum AppRoute: Hashable {
    case podcastDetail(feedURL: String)
    case episodeDetail(id: String)
}
