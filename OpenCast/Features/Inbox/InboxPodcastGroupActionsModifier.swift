import SwiftData
import SwiftUI

/// The long-press menu on a show in the Group by Podcast Inbox, for rows and
/// tiles alike. Play Latest starts the newest Inbox episode, Play Next and
/// Play Last queue the show's Inbox episodes (what the badge counts), Mark
/// All Played is the show page's, and Archive All archives the episodes the
/// group lists. In the archive view the group lists archived episodes, so
/// Unarchive All takes Archive All's place. Show management (removal,
/// sharing) stays on the Library and the show page.
struct InboxPodcastGroupActionsModifier: ViewModifier {
    @Environment(OpenCastAppModel.self) private var appModel
    @Environment(\.modelContext) private var modelContext
    @State private var isConfirmingMarkAllPlayed = false
    @State private var isConfirmingArchiveAll = false
    @State private var archiveAllConfirmation: InboxArchiveAllConfirmation?
    @State private var isConfirmingUnarchiveAll = false
    @State private var unarchiveAllConfirmation: InboxUnarchiveAllConfirmation?
    @State private var playFeedback = 0
    @State private var stateChangeFeedback = 0

    let group: InboxPodcastGroup
    let episodeListOverride: PodcastEpisodeListOverride

    private var isRefreshing: Bool {
        appModel.library.isRefreshing(feedURL: group.subscription.feedURL)
    }

    func body(content: Content) -> some View {
        content
            .contextMenu {
                TwoPaneRootLink(
                    route: .podcastDetail(
                        feedURL: group.subscription.feedURL,
                        episodeListOverride: episodeListOverride
                    ),
                    selectionStyle: .menuItem
                ) {
                    Label("Go to Show", systemImage: "rectangle.stack")
                }
                Button("Play Latest", systemImage: "play.fill", action: playLatest)
                Button(
                    "Play All Next",
                    systemImage: "text.line.first.and.arrowtriangle.forward",
                    action: enqueueNext
                )
                Button(
                    "Play All Last",
                    systemImage: "text.line.last.and.arrowtriangle.forward",
                    action: enqueueLast
                )
                Divider()
                Button("Mark All Played", systemImage: "checkmark.circle", action: confirmMarkAllPlayed)
                if !appModel.archivableEpisodes(group.episodes).isEmpty {
                    Button("Archive All", systemImage: "archivebox", action: confirmArchiveAll)
                }
                if !appModel.unarchivableEpisodes(group.episodes).isEmpty {
                    Button("Unarchive All", systemImage: "tray.and.arrow.up", action: confirmUnarchiveAll)
                }
                Button("Refresh", systemImage: "arrow.clockwise", action: refresh)
                    .disabled(isRefreshing)
            }
            .confirmationDialog(
                "Mark every episode as played?",
                isPresented: $isConfirmingMarkAllPlayed,
                titleVisibility: .visible
            ) {
                Button("Mark All Played", action: markAllPlayed)
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Listening progress for every episode in \(group.subscription.title) will be completed.")
            }
            .confirmationDialog(
                "Archive these episodes?",
                isPresented: $isConfirmingArchiveAll,
                titleVisibility: .visible,
                presenting: archiveAllConfirmation
            ) { confirmation in
                Button("Archive All") {
                    archiveAll(confirmation)
                }
                Button("Cancel", role: .cancel) {}
            } message: { confirmation in
                Text(confirmation.message)
            }
            .confirmationDialog(
                "Unarchive these episodes?",
                isPresented: $isConfirmingUnarchiveAll,
                titleVisibility: .visible,
                presenting: unarchiveAllConfirmation
            ) { confirmation in
                Button("Unarchive All") {
                    unarchiveAll(confirmation)
                }
                Button("Cancel", role: .cancel) {}
            } message: { confirmation in
                Text(confirmation.message)
            }
            .sensoryFeedback(.impact(flexibility: .soft), trigger: playFeedback)
            .sensoryFeedback(.success, trigger: stateChangeFeedback)
    }

    private func playLatest() {
        guard let episode = group.episodes.first else {
            return
        }
        do {
            try appModel.playEpisode(episode, modelContext: modelContext)
            playFeedback += 1
        } catch {
            appModel.lastPlaybackError = error.localizedDescription
        }
    }

    /// Oldest first, so the batch plays in release order wherever it lands:
    /// at the top of the queue or below it. The playing episode never joins
    /// the queue behind itself.
    private var queueableEpisodes: [EpisodeListItemSnapshot] {
        let currentEpisodeID = appModel.playback.currentEpisode?.id.rawValue
        return group.episodes
            .filter { $0.episodeID != currentEpisodeID }
            .sorted { OpenCastEntityCatalog.newestFirst($1, $0) }
    }

    private func enqueueNext() {
        let episodes = queueableEpisodes
        guard !episodes.isEmpty else {
            return
        }
        appModel.performUpNextQueueMutation {
            appModel.upNextQueue.enqueueNext(episodes, source: nil, modelContext: modelContext)
        }
    }

    private func enqueueLast() {
        let episodes = queueableEpisodes
        guard !episodes.isEmpty else {
            return
        }
        appModel.performUpNextQueueMutation {
            appModel.upNextQueue.enqueueLast(episodes, source: nil, modelContext: modelContext)
        }
    }

    private func confirmMarkAllPlayed() {
        isConfirmingMarkAllPlayed = true
    }

    private func markAllPlayed() {
        appModel.markAllEpisodesPlayed(
            forPodcastID: group.subscription.feedURL,
            modelContext: modelContext
        )
        stateChangeFeedback += 1
    }

    private func confirmArchiveAll() {
        archiveAllConfirmation = InboxArchiveAllConfirmation(group: group, appModel: appModel)
        isConfirmingArchiveAll = archiveAllConfirmation != nil
    }

    private func archiveAll(_ confirmation: InboxArchiveAllConfirmation) {
        if confirmation.archive(appModel: appModel, modelContext: modelContext) {
            stateChangeFeedback += 1
        }
    }

    private func confirmUnarchiveAll() {
        unarchiveAllConfirmation = InboxUnarchiveAllConfirmation(group: group, appModel: appModel)
        isConfirmingUnarchiveAll = unarchiveAllConfirmation != nil
    }

    private func unarchiveAll(_ confirmation: InboxUnarchiveAllConfirmation) {
        if confirmation.unarchive(appModel: appModel, modelContext: modelContext) {
            stateChangeFeedback += 1
        }
    }

    private func refresh() {
        Task {
            await appModel.library.refresh(feedURL: group.subscription.feedURL, modelContext: modelContext)
        }
    }
}
