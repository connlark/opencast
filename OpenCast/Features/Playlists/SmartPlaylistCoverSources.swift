import Foundation

/// The shows a smart playlist's cover draws, most dominant first. A show's
/// dominance is how many of the evaluated episodes it holds; a tie goes to
/// the show whose first episode comes earlier in rule order. Shows without
/// artwork are passed over, and a show whose artwork another drawn show
/// already uses is too, so the cover never stacks the same image twice.
nonisolated struct SmartPlaylistCoverSources: Equatable, Sendable {
    static let maximumShowCount = 3
    static let empty = SmartPlaylistCoverSources(artworkURLs: [])

    /// At most three, most dominant first.
    let artworkURLs: [URL]

    /// Prefers the show's current artwork and falls back to the first of its
    /// episodes that carries artwork, as the manual cover does. One pass over
    /// the episodes, then a sort of the distinct shows.
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

    /// One show's share of a smart playlist's episodes.
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
