nonisolated enum PodcastEpisodeSortOrder: String, CaseIterable, Identifiable, Sendable {
    case newestFirst
    case oldestFirst
    case longestFirst
    case shortestFirst

    var id: String {
        rawValue
    }

    var title: String {
        switch self {
        case .newestFirst:
            "Newest First"
        case .oldestFirst:
            "Oldest First"
        case .longestFirst:
            "Longest First"
        case .shortestFirst:
            "Shortest First"
        }
    }

    func areInIncreasingOrder(
        _ lhs: EpisodeListItemSnapshot,
        _ rhs: EpisodeListItemSnapshot
    ) -> Bool {
        switch self {
        case .newestFirst:
            EpisodeListItemSnapshot.newestFirst(lhs, rhs)
        case .oldestFirst:
            EpisodeListItemSnapshot.oldestFirst(lhs, rhs)
        case .longestFirst:
            EpisodeListItemSnapshot.longestFirst(lhs, rhs)
        case .shortestFirst:
            EpisodeListItemSnapshot.shortestFirst(lhs, rhs)
        }
    }
}
