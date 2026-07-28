import Foundation
import Intents

nonisolated enum SiriMediaResolver {
    @concurrent
    static func resolve(
        mediaName: String?,
        mediaType: INMediaItemType,
        subscriptions: [SiriMediaSubscription],
        episodes: [EpisodeListItemSnapshot]
    ) async -> SiriMediaResolution {
        guard isSupported(mediaType) else {
            return .noMatch
        }

        let query = mediaName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !query.isEmpty else {
            return .resume
        }

        if let show = matchingShow(query: query, subscriptions: subscriptions) {
            return .show(podcastID: show.podcastID)
        }

        guard mediaType != .podcastShow else {
            return .noMatch
        }

        let matches = EpisodeSearch.matchingEpisodes(in: episodes, query: query)
        let normalizedQuery = SearchTextNormalization.normalize(query)
        let exactTitleMatches = matches.filter {
            SearchTextNormalization.normalize($0.title) == normalizedQuery
        }
        if exactTitleMatches.count == 1, let episode = exactTitleMatches.first {
            return .episode(episodeID: episode.episodeID)
        }
        if matches.count == 1, let episode = matches.first {
            return .episode(episodeID: episode.episodeID)
        }
        return .noMatch
    }

    private static func isSupported(_ mediaType: INMediaItemType) -> Bool {
        switch mediaType {
        case .unknown, .podcastShow, .podcastEpisode, .podcastPlaylist, .podcastStation:
            true
        default:
            false
        }
    }

    private static func matchingShow(
        query: String,
        subscriptions: [SiriMediaSubscription]
    ) -> SiriMediaSubscription? {
        let normalizedQuery = SearchTextNormalization.normalize(query)
        let queryTokens = tokens(in: query)
        guard !queryTokens.isEmpty else {
            return nil
        }

        let candidates = subscriptions.compactMap { subscription -> (
            subscription: SiriMediaSubscription,
            score: (rank: Int, prefixMatchCount: Int, specificity: Int)
        )? in
            let normalizedTitle = SearchTextNormalization.normalize(subscription.title)
            let titleTokens = tokens(in: subscription.title)
            let prefixMatches = queryTokens.count { queryToken in
                titleTokens.contains { $0.hasPrefix(queryToken) }
            }
            let substringMatches = queryTokens.count { queryToken in
                titleTokens.contains { $0.contains(queryToken) }
            }
            guard substringMatches == queryTokens.count else {
                return nil
            }

            let rank: Int
            if normalizedTitle == normalizedQuery {
                rank = 4
            } else if normalizedTitle.hasPrefix(normalizedQuery) {
                rank = 3
            } else if prefixMatches == queryTokens.count {
                rank = 2
            } else {
                rank = 1
            }

            return (
                subscription,
                (rank, prefixMatches, -abs(titleTokens.count - queryTokens.count))
            )
        }

        guard let best = candidates.max(by: { $0.score < $1.score }) else {
            return nil
        }
        let bestCount = candidates.count { $0.score == best.score }
        return bestCount == 1 ? best.subscription : nil
    }

    private static func tokens(in text: String) -> [String] {
        text.split { !$0.isLetter && !$0.isNumber }
            .map { SearchTextNormalization.normalize(String($0)) }
            .filter { !$0.isEmpty }
    }
}
