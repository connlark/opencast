import Foundation

nonisolated enum EpisodeNotesLibrarySortOrder: String, CaseIterable, Identifiable, Sendable {
    case recent
    case show

    var id: String {
        rawValue
    }

    var title: String {
        switch self {
        case .recent:
            "Most Recent"
        case .show:
            "Show"
        }
    }
}
