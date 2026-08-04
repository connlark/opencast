import Foundation
import OpenCastCore

/// Maps store state to the value models the CarPlay templates render. Every
/// ordering, capping and marking decision lives here so the surface that has no
/// UI-test bridge stays covered by plain unit tests.
enum CarPlayBrowseModelBuilder {
    static func inbox(
        library: LibraryStore,
        downloadRecords: [EpisodeDownloadRecord],
        currentEpisode: Episode?,
        nowPlaying: CarPlayNowPlayingState,
        isLoading: Bool,
        limits: CarPlayListLimits
    ) -> CarPlayBrowseSnapshot {
        let downloadedEpisodeIDs = completedDownloadEpisodeIDs(in: downloadRecords)
        var sections: [CarPlayListSection] = []

        if let currentEpisode {
            sections.append(
                CarPlayListSection(
                    header: "Continue",
                    rows: [
                        .episode(
                            continueRow(
                                for: currentEpisode,
                                downloadedEpisodeIDs: downloadedEpisodeIDs,
                                nowPlaying: nowPlaying
                            )
                        )
                    ]
                )
            )
        }

        // Visible list + continuation never consume more than 2x the item
        // cap; don't build rows for an unbounded inbox (perf 29).
        let latestRows = library.inboxEpisodes.prefix(limits.maximumItemCount * 2).map { episode in
            CarPlayListRow.episode(
                episodeRow(
                    for: episode,
                    detailText: episode.podcastTitle,
                    library: library,
                    downloadedEpisodeIDs: downloadedEpisodeIDs,
                    nowPlaying: nowPlaying
                )
            )
        }
        sections.append(
            CarPlayListSection(header: sections.isEmpty ? nil : "Latest", rows: latestRows)
        )

        return makeSnapshot(
            title: "Inbox",
            sections: sections,
            continuationTitle: "More Episodes",
            emptyTitleVariants: ["No Episodes Yet", "No Episodes"],
            emptySubtitleVariants: ["New episodes from your shows appear here."],
            isLoading: isLoading,
            limits: limits
        )
    }

    static func library(
        subscriptions: [SubscriptionRecord],
        library: LibraryStore,
        isLoading: Bool,
        limits: CarPlayListLimits
    ) -> CarPlayBrowseSnapshot {
        let rows = subscriptions.prefix(limits.maximumItemCount * 2).map { subscription in
            CarPlayListRow.podcast(
                CarPlayPodcastRow(
                    feedURL: subscription.feedURL,
                    title: subscription.title,
                    artworkURL: subscription.artworkURL
                        ?? library.podcastCache(for: subscription.feedURL)?.artworkURL
                )
            )
        }

        return makeSnapshot(
            title: "Library",
            sections: [CarPlayListSection(header: nil, rows: rows)],
            continuationTitle: "More Shows",
            emptyTitleVariants: ["No Shows Yet", "No Shows"],
            emptySubtitleVariants: ["Shows you subscribe to appear here."],
            isLoading: isLoading,
            limits: limits
        )
    }

    static func downloads(
        records: [EpisodeDownloadRecord],
        library: LibraryStore,
        nowPlaying: CarPlayNowPlayingState,
        isLoading: Bool,
        limits: CarPlayListLimits
    ) -> CarPlayBrowseSnapshot {
        let model = DownloadsListModel.make(records: records, library: library)
        let rows = model.downloaded.prefix(limits.maximumItemCount * 2).map { item in
            CarPlayListRow.episode(
                episodeRow(
                    for: item.episode,
                    detailText: item.episode.podcastTitle,
                    library: library,
                    downloadedEpisodeIDs: [item.episode.episodeID],
                    nowPlaying: nowPlaying
                )
            )
        }

        return makeSnapshot(
            title: "Downloads",
            sections: [CarPlayListSection(header: nil, rows: rows)],
            continuationTitle: "More Downloads",
            emptyTitleVariants: ["No Downloads", "None"],
            emptySubtitleVariants: ["Episodes you download appear here."],
            isLoading: isLoading,
            limits: limits
        )
    }

    /// The car's show list is the phone's show list: same episodes, same stored
    /// filter and sort order, computed by the same model.
    static func episodes(
        forPodcastID podcastID: String,
        title: String,
        library: LibraryStore,
        downloadRecords: [EpisodeDownloadRecord],
        episodeListSettings: PodcastEpisodeListSettingsStore,
        nowPlaying: CarPlayNowPlayingState,
        limits: CarPlayListLimits
    ) -> CarPlayBrowseSnapshot {
        let model = PodcastEpisodeListModel.make(
            episodes: library.episodes(forPodcastID: podcastID),
            filter: episodeListSettings.filter(forPodcastID: podcastID),
            sortOrder: episodeListSettings.sortOrder(forPodcastID: podcastID),
            library: library,
            downloadRecords: downloadRecords
        )
        let downloadedEpisodeIDs = completedDownloadEpisodeIDs(in: downloadRecords)
        let rows = model.episodes.prefix(limits.maximumItemCount * 2).map { episode in
            CarPlayListRow.episode(
                episodeRow(
                    for: episode,
                    detailText: episode.publishedAt.map(Self.publishedText),
                    library: library,
                    downloadedEpisodeIDs: downloadedEpisodeIDs,
                    nowPlaying: nowPlaying
                )
            )
        }

        return makeSnapshot(
            title: title,
            sections: [CarPlayListSection(header: nil, rows: rows)],
            continuationTitle: "More Episodes",
            emptyTitleVariants: ["No Episodes", "None"],
            emptySubtitleVariants: ["No episodes match this show's filter."],
            isLoading: false,
            limits: limits
        )
    }

    private static func makeSnapshot(
        title: String,
        sections: [CarPlayListSection],
        continuationTitle: String,
        emptyTitleVariants: [String],
        emptySubtitleVariants: [String],
        isLoading: Bool,
        limits: CarPlayListLimits
    ) -> CarPlayBrowseSnapshot {
        let truncated = truncate(
            sections: sections,
            limits: limits,
            continuationTitle: continuationTitle
        )
        // Loading copy only reaches the screen while the list is empty, so a
        // populated list is byte-identical before and after hydration settles
        // and never spends a re-render on the transition.
        let isLoadingEmpty = isLoading && truncated.sections.isEmpty

        return CarPlayBrowseSnapshot(
            title: title,
            sections: truncated.sections,
            emptyTitleVariants: isLoadingEmpty ? ["Loading…"] : emptyTitleVariants,
            emptySubtitleVariants: isLoadingEmpty ? [] : emptySubtitleVariants,
            showsSpinnerWhileEmpty: isLoadingEmpty,
            continuation: truncated.continuation
        )
    }

    /// Slices to the head unit's ceilings, spending the last visible slot on a
    /// "Show More" row that reaches exactly one further page.
    private static func truncate(
        sections: [CarPlayListSection],
        limits: CarPlayListLimits,
        continuationTitle: String
    ) -> (sections: [CarPlayListSection], continuation: CarPlayListContinuation?) {
        let populated = sections.filter { !$0.rows.isEmpty }
        let kept = populated.prefix(limits.maximumSectionCount)
        var tail = populated.dropFirst(limits.maximumSectionCount).flatMap(\.rows)
        let keptRowCount = kept.reduce(0) { $0 + $1.rows.count }

        guard keptRowCount > limits.maximumItemCount || !tail.isEmpty else {
            return (Array(kept), nil)
        }

        // A list with nowhere to push, or too short to hold both content and a
        // marker, spends every slot on rows; the rest stay on the phone rather
        // than costing the driver a visible row for a dead end.
        guard limits.allowsContinuation, limits.maximumItemCount > 1 else {
            return (sliced(kept, budget: limits.maximumItemCount).sections, nil)
        }

        let visible = sliced(kept, budget: limits.maximumItemCount - 1)
        tail = visible.overflow + tail
        guard !tail.isEmpty, let lastSection = visible.sections.last else {
            return (visible.sections, nil)
        }

        var markedSections = visible.sections
        markedSections[markedSections.count - 1] = CarPlayListSection(
            header: lastSection.header,
            rows: lastSection.rows + [.showMore]
        )

        return (
            markedSections,
            CarPlayListContinuation(
                title: continuationTitle,
                sections: [
                    CarPlayListSection(header: nil, rows: Array(tail.prefix(limits.maximumItemCount)))
                ]
            )
        )
    }

    private static func sliced(
        _ sections: ArraySlice<CarPlayListSection>,
        budget: Int
    ) -> (sections: [CarPlayListSection], overflow: [CarPlayListRow]) {
        var remaining = budget
        var visible: [CarPlayListSection] = []
        var overflow: [CarPlayListRow] = []

        for section in sections {
            let take = min(max(remaining, 0), section.rows.count)
            if take > 0 {
                visible.append(
                    CarPlayListSection(header: section.header, rows: Array(section.rows.prefix(take)))
                )
            }
            overflow.append(contentsOf: section.rows.dropFirst(take))
            remaining -= take
        }

        return (visible, overflow)
    }

    private static func episodeRow(
        for episode: EpisodeListItemSnapshot,
        detailText: String?,
        library: LibraryStore,
        downloadedEpisodeIDs: Set<String>,
        nowPlaying: CarPlayNowPlayingState
    ) -> CarPlayEpisodeRow {
        CarPlayEpisodeRow(
            episodeID: episode.episodeID,
            title: episode.title,
            detailText: detailText,
            artworkURL: episode.artworkURL,
            // While an episode plays its progress record is rewritten every few
            // seconds, and reading it would rebuild the car lists on that
            // cadence for a bar the playing indicator already stands in for.
            // Paused, nothing writes it, so the bar comes back.
            playbackProgress: nowPlaying.isActivelyPlaying(episode.episodeID)
                ? nil
                : visibleProgress(for: episode, library: library),
            isPlaying: nowPlaying.isActivelyPlaying(episode.episodeID),
            isDownloaded: downloadedEpisodeIDs.contains(episode.episodeID)
        )
    }

    private static func continueRow(
        for episode: Episode,
        downloadedEpisodeIDs: Set<String>,
        nowPlaying: CarPlayNowPlayingState
    ) -> CarPlayEpisodeRow {
        CarPlayEpisodeRow(
            episodeID: episode.id.rawValue,
            title: episode.title,
            detailText: episode.podcastTitle,
            artworkURL: episode.artworkURL?.absoluteString,
            playbackProgress: nil,
            isPlaying: nowPlaying.isActivelyPlaying(episode.id.rawValue),
            isDownloaded: downloadedEpisodeIDs.contains(episode.id.rawValue)
        )
    }

    private static func visibleProgress(
        for episode: EpisodeListItemSnapshot,
        library: LibraryStore
    ) -> Double? {
        let progress = library.progressSummary(for: episode)
        return progress.hasVisibleProgress ? progress.fractionCompleted : nil
    }

    private static func completedDownloadEpisodeIDs(in records: [EpisodeDownloadRecord]) -> Set<String> {
        Set(records.compactMap { $0.state == .completed ? $0.episodeID : nil })
    }

    private static func publishedText(_ publishedAt: Date) -> String {
        publishedAt.formatted(.dateTime.month(.abbreviated).day().year())
    }
}
