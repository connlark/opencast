struct DownloadsShowGroup: Identifiable {
    let podcastID: String
    let title: String
    let artworkURL: String?
    let items: [DownloadListItem]
    let isOrphaned: Bool

    var id: String {
        podcastID
    }

    var episodeCount: Int {
        items.count
    }

    var byteCount: Int64 {
        items.reduce(0) { $0 + max($1.record.bytesReceived, 0) }
    }

    /// `items` are completed downloads, newest first.
    static func make(
        items: [DownloadListItem],
        isSubscribed: (String) -> Bool
    ) -> [DownloadsShowGroup] {
        var orderedPodcastIDs: [String] = []
        var itemsByPodcastID: [String: [DownloadListItem]] = [:]
        for item in items {
            let podcastID = item.episode.podcastID
            if itemsByPodcastID[podcastID] == nil {
                orderedPodcastIDs.append(podcastID)
            }
            itemsByPodcastID[podcastID, default: []].append(item)
        }

        return orderedPodcastIDs.map { podcastID in
            let showItems = itemsByPodcastID[podcastID, default: []]
            return DownloadsShowGroup(
                podcastID: podcastID,
                title: showItems.first?.episode.podcastTitle ?? "Removed Podcast",
                artworkURL: showItems.first?.episode.artworkURL,
                items: showItems,
                isOrphaned: !isSubscribed(podcastID)
            )
        }
    }
}
