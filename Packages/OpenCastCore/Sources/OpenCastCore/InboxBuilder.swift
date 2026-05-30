import Foundation

public enum InboxBuilder {
    public static func buildInbox(
        episodes: [Episode],
        progressByEpisodeID: [EpisodeID: EpisodeProgress] = [:],
        includePlayed: Bool = false
    ) -> [Episode] {
        episodes
            .filter { episode in
                guard !includePlayed else {
                    return true
                }
                return progressByEpisodeID[episode.id]?.isPlayed != true
            }
            .sorted { lhs, rhs in
                switch (lhs.publishedAt, rhs.publishedAt) {
                case let (lhsDate?, rhsDate?):
                    return lhsDate > rhsDate
                case (.some, .none):
                    return true
                case (.none, .some):
                    return false
                case (.none, .none):
                    return lhs.title.localizedStandardCompare(rhs.title) == .orderedAscending
                }
            }
    }
}
