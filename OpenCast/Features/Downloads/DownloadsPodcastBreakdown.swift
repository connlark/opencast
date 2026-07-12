struct DownloadsPodcastBreakdown: Identifiable {
    let podcastID: String
    let title: String
    let episodeCount: Int
    let byteCount: Int64

    var id: String {
        podcastID
    }

    static func make(items: [DownloadListItem]) -> [DownloadsPodcastBreakdown] {
        Dictionary(grouping: items, by: { $0.episode.podcastID })
            .map { podcastID, podcastItems in
                DownloadsPodcastBreakdown(
                    podcastID: podcastID,
                    title: podcastItems.first?.episode.podcastTitle ?? "Removed Podcast",
                    episodeCount: podcastItems.count,
                    byteCount: podcastItems.reduce(0) { $0 + max($1.record.bytesReceived, 0) }
                )
            }
            .sorted {
                let comparison = $0.title.localizedStandardCompare($1.title)
                return comparison == .orderedSame ? $0.podcastID < $1.podcastID : comparison == .orderedAscending
            }
    }
}
