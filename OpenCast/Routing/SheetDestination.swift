import Foundation

enum SheetDestination: Identifiable {
    case addPodcast
    case importOPMLFile(URL)
    case onboarding

    var id: String {
        switch self {
        case .addPodcast:
            "addPodcast"
        case .importOPMLFile(let url):
            "importOPMLFile-\(url.absoluteString)"
        case .onboarding:
            "onboarding"
        }
    }
}
