struct DownloadsListModel {
    let downloading: [DownloadListItem]
    let failed: [DownloadListItem]
    let downloaded: [DownloadListItem]
    let animationKey: DownloadsListAnimationKey

    var isEmpty: Bool {
        downloading.isEmpty && failed.isEmpty && downloaded.isEmpty
    }

    static func make(
        records: [EpisodeDownloadRecord],
        library: LibraryStore,
        showsUnplayedOnly: Bool
    ) -> DownloadsListModel {
        var downloading: [DownloadListItem] = []
        var failed: [DownloadListItem] = []
        var downloaded: [DownloadListItem] = []

        for record in records {
            let item = DownloadListItem.make(record: record, library: library)
            switch record.state {
            case .downloading, .paused:
                downloading.append(item)
            case .failed, .missing:
                failed.append(item)
            case .completed:
                guard !showsUnplayedOnly || library.progressRecord(for: record.episodeID)?.isPlayed != true else {
                    continue
                }
                downloaded.append(item)
            }
        }

        downloading.sort(by: sortsDownloading)
        failed.sort(by: sortsNewestFirst)
        downloaded.sort(by: sortsNewestFirst)

        return DownloadsListModel(
            downloading: downloading,
            failed: failed,
            downloaded: downloaded,
            animationKey: DownloadsListAnimationKey(
                downloadingEpisodeIDs: downloading.map(\.id),
                failedEpisodeIDs: failed.map(\.id),
                downloadedEpisodeIDs: downloaded.map(\.id),
                stateRawValuesByEpisodeID: Dictionary(
                    records.map { ($0.episodeID, $0.stateRawValue) },
                    uniquingKeysWith: { _, newestState in newestState }
                )
            )
        )
    }

    private static func sortsDownloading(_ lhs: DownloadListItem, _ rhs: DownloadListItem) -> Bool {
        if lhs.record.createdAt == rhs.record.createdAt {
            return lhs.id < rhs.id
        }

        return lhs.record.createdAt < rhs.record.createdAt
    }

    private static func sortsNewestFirst(_ lhs: DownloadListItem, _ rhs: DownloadListItem) -> Bool {
        if lhs.record.updatedAt == rhs.record.updatedAt {
            return lhs.id < rhs.id
        }

        return lhs.record.updatedAt > rhs.record.updatedAt
    }
}
