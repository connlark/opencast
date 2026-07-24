struct DownloadListItem: Identifiable {
    let record: EpisodeDownloadRecord
    let episode: EpisodeListItemSnapshot
    let isOrphaned: Bool

    var id: String {
        record.episodeID
    }

    static func make(record: EpisodeDownloadRecord, library: LibraryStore) -> DownloadListItem {
        if let episode = library.episode(with: record.episodeID) {
            return DownloadListItem(record: record, episode: episode, isOrphaned: false)
        }

        let episode = EpisodeListItemSnapshot(
            downloadRecord: record,
            podcastCache: library.podcastCache(for: record.podcastID)
        )
        return DownloadListItem(record: record, episode: episode, isOrphaned: true)
    }
}
