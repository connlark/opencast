import Foundation

enum AddPodcastMode: String, CaseIterable, Identifiable {
    case rss
    case search

    var id: Self {
        self
    }

    var title: String {
        switch self {
        case .rss:
            "RSS"
        case .search:
            "Search"
        }
    }
}
