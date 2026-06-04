import Foundation

enum EpisodeSearchMode: String, CaseIterable, Identifiable, Sendable {
    case episodes
    case fullText

    var id: Self {
        self
    }

    var title: String {
        switch self {
        case .episodes:
            "Episodes"
        case .fullText:
            "Full Text"
        }
    }
}
