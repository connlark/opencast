import Foundation
import Intents

nonisolated enum SiriMediaResolver {
    private typealias TitleMatch = (id: String, score: (rank: Int, prefixMatchCount: Int, specificity: Int))

    @concurrent
    static func resolve(
        mediaName: String?,
        mediaType: INMediaItemType,
        subscriptions: [SiriMediaSubscription],
        episodes: [EpisodeListItemSnapshot],
        playlists: [SiriMediaPlaylist] = []
    ) async -> SiriMediaResolution {
        guard isSupported(mediaType) else {
            return .noMatch
        }

        let query = mediaName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !query.isEmpty else {
            return .resume
        }

        let show = matchingShow(query: query, subscriptions: subscriptions)
        switch mediaType {
        case .podcastPlaylist:
            if let playlist = matchingPlaylist(query: query, playlists: playlists) {
                return .playlist(playlistID: playlist.id)
            }
        case .unknown:
            // A tie goes to the playlist, but a better show match (an exact
            // show title over a prefix playlist match) keeps the show.
            if let playlist = matchingPlaylist(query: query, playlists: playlists),
               show.map({ playlist.score >= $0.score }) ?? true {
                return .playlist(playlistID: playlist.id)
            }
        default:
            break
        }

        if let show {
            return .show(podcastID: show.id)
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
    ) -> TitleMatch? {
        bestTitleMatch(
            query: query,
            candidates: subscriptions.map { (id: $0.podcastID, title: $0.title) }
        )
    }

    private static func matchingPlaylist(
        query: String,
        playlists: [SiriMediaPlaylist]
    ) -> TitleMatch? {
        let candidates = playlists.map { (id: $0.playlistID, title: $0.name) }
        if let match = bestTitleMatch(query: query, candidates: candidates) {
            return match
        }
        guard let queryWithoutPlaylistWord = droppingTrailingPlaylistWord(from: query) else {
            return nil
        }
        return bestTitleMatch(query: queryWithoutPlaylistWord, candidates: candidates)
    }

    /// Cut from the original characters rather than rebuilt from tokens, so a
    /// title with punctuation ("Mom's Mix") keeps its exact-title rank.
    private static func droppingTrailingPlaylistWord(from query: String) -> String? {
        let queryTokens = tokens(in: query)
        guard queryTokens.count > 1, queryTokens.last == "playlist" else {
            return nil
        }

        let isSeparator: (Character) -> Bool = { !$0.isLetter && !$0.isNumber }
        guard let lastWordEnd = query.lastIndex(where: { !isSeparator($0) }),
              let separatorBeforeLastWord = query[..<lastWordEnd].lastIndex(where: isSeparator),
              let remainderEnd = query[..<separatorBeforeLastWord].lastIndex(where: { !isSeparator($0) })
        else {
            return nil
        }
        return String(query[...remainderEnd])
    }

    private static func bestTitleMatch(
        query: String,
        candidates: [(id: String, title: String)]
    ) -> TitleMatch? {
        let normalizedQuery = SearchTextNormalization.normalize(query)
        let queryTokens = tokens(in: query)
        guard !queryTokens.isEmpty else {
            return nil
        }

        let matches = candidates.compactMap { candidate -> TitleMatch? in
            let normalizedTitle = SearchTextNormalization.normalize(candidate.title)
            let titleTokens = tokens(in: candidate.title)
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
                candidate.id,
                (rank, prefixMatches, -abs(titleTokens.count - queryTokens.count))
            )
        }

        guard let best = matches.max(by: { $0.score < $1.score }) else {
            return nil
        }
        let bestCount = matches.count { $0.score == best.score }
        return bestCount == 1 ? best : nil
    }

    private static func tokens(in text: String) -> [String] {
        text.split { !$0.isLetter && !$0.isNumber }
            .map { SearchTextNormalization.normalize(String($0)) }
            .filter { !$0.isEmpty }
    }
}
