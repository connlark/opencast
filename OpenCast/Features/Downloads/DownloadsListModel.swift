struct DownloadsListModel {
    let downloading: [DownloadListItem]
    let failed: [DownloadListItem]
    let downloaded: [DownloadListItem]
    let animationKey: DownloadsListAnimationKey

    var isEmpty: Bool {
        downloading.isEmpty && failed.isEmpty && downloaded.isEmpty
    }

    func filteringUnplayed(using library: LibraryStore) -> DownloadsListModel {
        let unplayedDownloads = downloaded.filter {
            library.progressRecord(for: $0.id)?.isPlayed != true
        }
        return DownloadsListModel(
            downloading: downloading,
            failed: failed,
            downloaded: unplayedDownloads,
            animationKey: DownloadsListAnimationKey(
                downloadingEpisodeIDs: animationKey.downloadingEpisodeIDs,
                failedEpisodeIDs: animationKey.failedEpisodeIDs,
                downloadedEpisodeIDs: unplayedDownloads.map(\.id),
                stateRawValuesByEpisodeID: animationKey.stateRawValuesByEpisodeID
            )
        )
    }

    static func make(
        records: [EpisodeDownloadRecord],
        library: LibraryStore
    ) -> DownloadsListModel {
        var downloading: [DownloadListItem] = []
        var failed: [DownloadListItem] = []
        var downloaded: [DownloadListItem] = []

        for record in uniquedByEpisodeID(records) {
            let item = DownloadListItem.make(record: record, library: library)
            switch record.state {
            case .downloading, .paused:
                downloading.append(item)
            case .failed, .missing:
                failed.append(item)
            case .completed:
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

    /// Item IDs are episode IDs, so every row must be unique per episode even
    /// when persisted records violate that invariant (`DownloadStore` repairs
    /// them at load; this is the last fence before `ForEach`/selection). The
    /// survivor is chosen by an explicit ladder, never by fetch order, so the
    /// same rows always render the same list.
    private static func uniquedByEpisodeID(_ records: [EpisodeDownloadRecord]) -> [EpisodeDownloadRecord] {
        var winnersByEpisodeID: [String: EpisodeDownloadRecord] = [:]
        for record in records {
            if let current = winnersByEpisodeID[record.episodeID], !prefers(record, over: current) {
                continue
            }
            winnersByEpisodeID[record.episodeID] = record
        }
        guard winnersByEpisodeID.count != records.count else {
            return records
        }
        return records.filter { winnersByEpisodeID[$0.episodeID] === $0 }
    }

    private static func prefers(_ lhs: EpisodeDownloadRecord, over rhs: EpisodeDownloadRecord) -> Bool {
        if displayPriority(lhs.state) != displayPriority(rhs.state) {
            return displayPriority(lhs.state) > displayPriority(rhs.state)
        }
        if lhs.updatedAt != rhs.updatedAt {
            return lhs.updatedAt > rhs.updatedAt
        }
        if lhs.createdAt != rhs.createdAt {
            return lhs.createdAt > rhs.createdAt
        }
        return String(describing: lhs.persistentModelID) < String(describing: rhs.persistentModelID)
    }

    private static func displayPriority(_ state: EpisodeDownloadState) -> Int {
        switch state {
        case .completed: 4
        case .downloading: 3
        case .paused: 2
        case .failed: 1
        case .missing: 0
        }
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
