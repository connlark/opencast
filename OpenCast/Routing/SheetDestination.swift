import Foundation

enum SheetDestination: Identifiable {
    case addPodcast
    case episodeInfo(episodeID: String)
    case importOPMLFile(URL)
    case nukeConfirmation
    case onboarding
    case podcastPlaybackSettings(feedURL: String)

    var id: String {
        switch self {
        case .addPodcast:
            "addPodcast"
        case .episodeInfo(let episodeID):
            "episodeInfo-\(episodeID)"
        case .importOPMLFile(let url):
            "importOPMLFile-\(url.absoluteString)"
        case .nukeConfirmation:
            "nukeConfirmation"
        case .onboarding:
            "onboarding"
        case .podcastPlaybackSettings(let feedURL):
            "podcastPlaybackSettings-\(feedURL)"
        }
    }
}
