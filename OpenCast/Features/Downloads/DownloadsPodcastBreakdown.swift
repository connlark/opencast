struct DownloadsPodcastBreakdown: Identifiable {
    let podcastID: String
    let title: String
    /// The newest download's artwork, for a show the library no longer has.
    let artworkURL: String?
    let episodeCount: Int
    let byteCount: Int64
    let isOrphaned: Bool

    var id: String {
        podcastID
    }

    /// `items` are completed downloads, newest first.
    static func make(
        items: [DownloadListItem],
        isSubscribed: (String) -> Bool
    ) -> [DownloadsPodcastBreakdown] {
        Dictionary(grouping: items, by: { $0.episode.podcastID })
            .map { podcastID, podcastItems in
                DownloadsPodcastBreakdown(
                    podcastID: podcastID,
                    title: podcastItems.first?.episode.podcastTitle ?? "Removed Podcast",
                    artworkURL: podcastItems.first?.episode.artworkURL,
                    episodeCount: podcastItems.count,
                    byteCount: podcastItems.reduce(0) { $0 + max($1.record.bytesReceived, 0) },
                    isOrphaned: !isSubscribed(podcastID)
                )
            }
            .sorted {
                let comparison = $0.title.localizedStandardCompare($1.title)
                return comparison == .orderedSame ? $0.podcastID < $1.podcastID : comparison == .orderedAscending
            }
    }
}
