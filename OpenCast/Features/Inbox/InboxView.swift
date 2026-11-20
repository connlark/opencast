import SwiftData
import SwiftUI

struct InboxView: View {
    @Environment(OpenCastAppModel.self) private var appModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.modelContext) private var modelContext
    @Environment(SceneLibraryLayouts.self) private var sceneLibraryLayouts: SceneLibraryLayouts?
    @State private var visibleEpisodeCount = EpisodeCatalogContinuation.pageSize

    let onAdd: () -> Void
    let onOpenEpisode: (String) -> Void
    var onOpenAdDetectionQueue: () -> Void = {}

    private var groupedLayout: LibraryLayout {
        let preference = appModel.inboxEpisodeListSettings.groupedLayout
        let isRegularWidth = horizontalSizeClass == .regular
        return sceneLibraryLayouts?.layout(of: .inboxGroups, for: preference, isRegularWidth: isRegularWidth)
            ?? preference.resolved(isRegularWidth: isRegularWidth)
    }

    var body: some View {
        let inboxEpisodes = appModel.library.inboxEpisodes
        let filter = appModel.inboxEpisodeListSettings.filter
        let hidesQueuedEpisodes = appModel.inboxEpisodeListSettings.hidesQueuedEpisodes
        let showsArchivedEpisodes = appModel.inboxEpisodeListSettings.showsArchivedEpisodes
        let groupsByPodcast = appModel.inboxEpisodeListSettings.groupsByPodcast
        // A group counts every matching episode of its show, so grouping
        // reads the whole filtered list instead of a page.
        let model = appModel.coreStoresHydrated
            ? InboxEpisodeListModel.make(
                episodes: inboxEpisodes,
                filter: filter,
                hidesQueuedEpisodes: hidesQueuedEpisodes,
                showsArchivedEpisodes: showsArchivedEpisodes,
                library: appModel.library,
                downloadRecords: appModel.downloads.records,
                queuedEpisodeIDs: Set(appModel.upNextQueue.items.map(\.episodeID)),
                playingEpisodeID: appModel.playback.currentEpisode?.id.rawValue,
                archivedEpisodeIDs: appModel.library.archivedEpisodeIDs,
                visibleEpisodeCount: groupsByPodcast ? nil : visibleEpisodeCount
            )
            : InboxEpisodeListModel(episodes: [], totalEpisodeCount: 0, hasMore: false)
        let groups = groupsByPodcast
            ? InboxPodcastGroup.make(episodes: model.episodes, subscriptions: appModel.library.subscriptions)
            : nil
        let visibleEpisodes = groups == nil ? Array(model.episodes.prefix(visibleEpisodeCount)) : []
        let rowIDs = groups?.map(\.id) ?? visibleEpisodes.map(\.episodeID)
        let showsFilter = appModel.coreStoresHydrated && !inboxEpisodes.isEmpty
        let layout = groupedLayout

        content(
            model: model,
            hasInboxEpisodes: !inboxEpisodes.isEmpty,
            filter: filter,
            hidesQueuedEpisodes: hidesQueuedEpisodes,
            showsArchivedEpisodes: showsArchivedEpisodes,
            groups: groups,
            visibleEpisodes: visibleEpisodes,
            layout: layout
        )
        .animation(listAnimation, value: rowIDs)
        .animation(listAnimation, value: appModel.library.state)
        .animation(listAnimation, value: groupsByPodcast)
        .animation(listAnimation, value: layout)
        .animation(listAnimation, value: appModel.library.lastRefreshWasOffline)
        .safeAreaInset(edge: .top, spacing: 0) {
            SettingsErrorBanner(message: appModel.inboxEpisodeListSettings.lastErrorMessage)
        }
        .navigationTitle("Inbox")
        // An empty subtitle takes no space under the large title.
        .navigationSubtitle(
            showsFilter ? appModel.inboxEpisodeListSettings.activeFilterTitles.joined(separator: " · ") : ""
        )
        .toolbarMinimizationBehavior(.onScrollDown, for: .navigationBar)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                InboxAdDetectionToolbarStatus(onOpen: onOpenAdDetectionQueue)
            }
            if showsFilter {
                if groupsByPodcast {
                    ToolbarItem(placement: .topBarTrailing) {
                        InboxGroupedLayoutMenu(resolvedLayout: layout)
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    InboxFilterMenu()
                }
            }
        }
        .refreshable {
            await appModel.library.refreshAll(modelContext: modelContext)
        }
        .onChange(of: appModel.inboxEpisodeListSettings.groupedLayout, initial: true) { _, preference in
            sceneLibraryLayouts?.observe(preference, on: .inboxGroups, isRegularWidth: horizontalSizeClass == .regular)
        }
    }

    /// The grid is its own scroll view, so each branch brings its container
    /// instead of sharing one `List`.
    @ViewBuilder
    private func content(
        model: InboxEpisodeListModel,
        hasInboxEpisodes: Bool,
        filter: PodcastEpisodeFilter,
        hidesQueuedEpisodes: Bool,
        showsArchivedEpisodes: Bool,
        groups: [InboxPodcastGroup]?,
        visibleEpisodes: [EpisodeListItemSnapshot],
        layout: LibraryLayout
    ) -> some View {
        if !appModel.coreStoresHydrated {
            inboxList {
                InboxLoadingStateView()
            }
        } else if case .failed(let message) = appModel.library.state,
                  !hasInboxEpisodes {
            inboxList {
                InboxFailedStateView(message: message)
            }
        } else if !hasInboxEpisodes {
            inboxList {
                InboxEmptyStateView(
                    syncActivity: appModel.syncStatus.libraryActivity,
                    onAdd: onAdd
                )
            }
        } else if model.isFilteredEmpty {
            let hiddenEpisodes = InboxFilteredEmptyStateView.hiddenEpisodes(
                inboxEpisodes: appModel.library.inboxEpisodes,
                hidesQueuedEpisodes: hidesQueuedEpisodes,
                showsArchivedEpisodes: showsArchivedEpisodes,
                archivedEpisodeIDs: appModel.library.archivedEpisodeIDs
            )
            inboxList {
                if showsArchivedEpisodes {
                    InboxArchiveEmptyStateView(filter: filter, hiddenEpisodes: hiddenEpisodes, onShowInbox: showInbox)
                } else {
                    InboxFilteredEmptyStateView(
                        filter: filter,
                        hiddenEpisodes: hiddenEpisodes,
                        onShowAll: showAllEpisodes,
                        onShowArchived: showArchive
                    )
                }
            }
        } else if let groups {
            let episodeListOverride = PodcastEpisodeListOverride(
                filter: filter,
                hidesQueuedEpisodes: hidesQueuedEpisodes,
                archiveScope: showsArchivedEpisodes ? .onlyArchived : .hidingArchived
            )
            if layout == .grid {
                InboxPodcastGroupGrid(groups: groups, episodeListOverride: episodeListOverride) {
                    if appModel.library.lastRefreshWasOffline {
                        LibraryOfflineNotice()
                    }
                }
                .transition(.opacity)
            } else {
                inboxList {
                    ForEach(groups) { group in
                        InboxPodcastGroupLink(group: group, episodeListOverride: episodeListOverride) {
                            SubscriptionRowView(subscription: group.subscription, badgeCount: group.episodeCount)
                        }
                    }
                }
                .accessibilityIdentifier("Inbox Podcast List")
                .transition(.opacity)
            }
        } else {
            inboxList {
                ForEach(visibleEpisodes) { episode in
                    EpisodeRowButton(
                        episode: episode,
                        onOpenEpisode: onOpenEpisode
                    )
                    .modifier(PodcastEpisodeSwipeActionsModifier(episode: episode, showsArchiveAction: true))
                    .twoPaneRootSelection(.episodeDetail(id: episode.episodeID))
                }
                EpisodeCatalogContinuation(hasMore: model.hasMore, visibleCount: $visibleEpisodeCount)
            }
        }
    }

    private func inboxList<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        List {
            offlineNoticeSection
            content()
        }
        .listSectionSpacing(12)
        .safeAreaHorizontalContentMargins(regular: 32)
    }

    @ViewBuilder
    private var offlineNoticeSection: some View {
        if appModel.library.lastRefreshWasOffline {
            Section {
                LibraryOfflineNotice()
                    .listRowInsets(EdgeInsets(top: 0, leading: 20, bottom: 0, trailing: 20))
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
            }
        }
    }

    private var listAnimation: Animation? {
        reduceMotion ? nil : .default
    }

    private func showAllEpisodes() {
        appModel.inboxEpisodeListSettings.resetFilterAndHideUpNext(modelContext: modelContext)
    }

    private func showArchive() {
        appModel.inboxEpisodeListSettings.setShowsArchivedEpisodes(true, modelContext: modelContext)
    }

    private func showInbox() {
        appModel.inboxEpisodeListSettings.setShowsArchivedEpisodes(false, modelContext: modelContext)
    }
}

/// Reads the ad-detection queue snapshot in its own body, so per-stage queue churn re-evaluates
/// this indicator alone, never the Inbox List.
private struct InboxAdDetectionToolbarStatus: View {
    @Environment(OpenCastAppModel.self) private var appModel

    let onOpen: () -> Void

    var body: some View {
        let snapshot = appModel.adFreePass.queueSnapshot
        AdDetectionQueueToolbarIndicator(
            indicator: adDetectionIndicator(for: snapshot),
            accessibilityValue: adDetectionAccessibilityValue(for: snapshot),
            onOpen: onOpen
        )
    }

    private func adDetectionIndicator(
        for snapshot: AdFreePassQueueSnapshot
    ) -> AdDetectionQueuePresentation.Indicator {
        let hasFailures = snapshot.failedCount > 0
        return switch snapshot.state {
        case .idle:
            snapshot.outcomes.isEmpty ? .hidden : .finished(hasFailures: hasFailures)
        case .running:
            .running(
                fractionCompleted: snapshot.fractionCompleted,
                hasFailures: hasFailures
            )
        case .pausedInterrupted, .awaitingModelConsent:
            .paused(hasFailures: hasFailures)
        }
    }

    private func adDetectionAccessibilityValue(for snapshot: AdFreePassQueueSnapshot) -> String {
        let percent = Int((snapshot.fractionCompleted * 100).rounded())
        return switch snapshot.state {
        case .idle:
            snapshot.outcomes.isEmpty
                ? "Idle"
                : "Finished — \(snapshot.completedCount) detected, \(snapshot.failedCount) failed"
        case .running:
            "\(percent)% — detecting ads"
        case .pausedInterrupted:
            "\(percent)% — paused"
        case .awaitingModelConsent:
            "\(percent)% — waiting for the speech model"
        }
    }
}
