import Foundation

nonisolated struct SmartPlaylistCoverSources: Equatable, Sendable {
    static let maximumShowCount = 3
    static let empty = SmartPlaylistCoverSources(artworkURLs: [])

    /// At most three, most dominant first.
    let artworkURLs: [URL]

    static func make(
        episodes: [EpisodeListItemSnapshot],
        podcastArtworkURL: (String) -> URL?
    ) -> SmartPlaylistCoverSources {
        var tallies: [String: Tally] = [:]
        for (index, episode) in episodes.enumerated() {
            tallies[episode.podcastID, default: Tally(firstIndex: index)].count(episode)
        }

        var artworkURLs: [URL] = []
        for (podcastID, tally) in tallies.sorted(by: { $0.value.outranks($1.value) }) {
            guard let url = podcastArtworkURL(podcastID) ?? tally.episodeArtworkURL,
                  !artworkURLs.contains(url)
            else {
                continue
            }
            artworkURLs.append(url)
            if artworkURLs.count == maximumShowCount {
                break
            }
        }
        return SmartPlaylistCoverSources(artworkURLs: artworkURLs)
    }

    private nonisolated struct Tally {
        let firstIndex: Int
        private(set) var episodeCount = 0
        private(set) var episodeArtworkURL: URL?

        init(firstIndex: Int) {
            self.firstIndex = firstIndex
        }

        mutating func count(_ episode: EpisodeListItemSnapshot) {
            episodeCount += 1
            if episodeArtworkURL == nil {
                episodeArtworkURL = episode.artworkURL.flatMap(URL.init(string:))
            }
        }

        func outranks(_ other: Tally) -> Bool {
            episodeCount != other.episodeCount
                ? episodeCount > other.episodeCount
                : firstIndex < other.firstIndex
        }
    }
}
