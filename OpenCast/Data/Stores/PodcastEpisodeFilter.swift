nonisolated enum PodcastEpisodeFilter: String, CaseIterable, Identifiable, Sendable {
    case all
    case unplayed
    case inProgress
    case played
    case downloaded

    var id: String {
        rawValue
    }

    var title: String {
        switch self {
        case .all:
            "All Episodes"
        case .unplayed:
            "Unplayed"
        case .inProgress:
            "In Progress"
        case .played:
            "Played"
        case .downloaded:
            "Downloaded"
        }
    }

    var systemImage: String {
        switch self {
        case .all:
            "line.3.horizontal.decrease.circle"
        case .unplayed:
            "circle"
        case .inProgress:
            "play.circle"
        case .played:
            "checkmark.circle"
        case .downloaded:
            "arrow.down.circle"
        }
    }

    var emptyStateTitle: String {
        switch self {
        case .all:
            "No Episodes"
        case .unplayed:
            "No Unplayed Episodes"
        case .inProgress:
            "No Episodes in Progress"
        case .played:
            "No Played Episodes"
        case .downloaded:
            "No Downloaded Episodes"
        }
    }

    var emptyStateDescription: String {
        switch self {
        case .all:
            "This podcast does not have any episodes yet."
        case .unplayed:
            "Every episode in this podcast is marked as played."
        case .inProgress:
            "Start listening to an episode and it will appear here."
        case .played:
            "Episodes you finish or mark as played will appear here."
        case .downloaded:
            "Download an episode to listen to it offline."
        }
    }
}
