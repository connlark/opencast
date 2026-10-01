import SwiftData
import SwiftUI

/// One smart playlist: the tinted hero with its rule chips, then the episodes
/// the rule matches, in rule order. Tapping a row plays from there. The rule
/// decides membership and order, so rows cannot be reordered or removed;
/// changing a chip re-evaluates the list in place.
///
/// The body reads the evaluation once, through the app model's memo, which
/// recomputes only when a token the rule depends on changes. The body never
/// reads the playlist items, Hide Played or Up Next.
struct SmartPlaylistDetailView: View {
    @Environment(OpenCastAppModel.self) private var appModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.modelContext) private var modelContext
    @State private var visibleEpisodeCount = EpisodeCatalogContinuation.pageSize

    let summary: PlaylistSummary
    var onOpenEpisode: (String) -> Void = { _ in }

    var body: some View {
        let evaluation = appModel.smartPlaylistEvaluation(for: summary)
        let primaryAction = PlaylistPrimaryAction.resolve(
            smartEpisodes: evaluation.episodes,
            library: appModel.library
        )
        // Play Next and Play Last skip the episode now playing.
        let currentEpisodeID = appModel.playback.currentEpisode?.id.rawValue
        let canEnqueue = evaluation.episodes.contains {
            $0.episodeID != currentEpisodeID && isCandidate($0)
        }
        let visibleEpisodes = evaluation.episodes.prefix(visibleEpisodeCount)

        List {
            Section {
                PlaylistHeroHeader(
                    summary: summary,
                    itemCount: evaluation.count,
                    totalDuration: evaluation.totalDuration,
                    counts: nil,
                    sources: PlaylistCoverSources(artworkURLs: [], fallbackTitle: summary.name),
                    primaryAction: primaryAction ?? .play,
                    canPlay: primaryAction != nil,
                    onPlay: play,
                    onRuleChange: setRule
                )
                .frame(maxWidth: 600)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
            }

            // An unreadable rule lists nothing; the hero's footnote explains.
            if !summary.hasUnreadableRule {
                Section {
                    if evaluation.episodes.isEmpty {
                        ContentUnavailableView(
                            "No Matching Episodes",
                            systemImage: "sparkles",
                            description: Text("No episodes match these rules. Change a rule above to include more.")
                        )
                    } else {
                        ForEach(visibleEpisodes) { episode in
                            PlaylistEpisodeRowView(
                                itemID: nil,
                                playlistID: summary.playlistID,
                                episode: episode,
                                onOpenEpisode: onOpenEpisode
                            )
                            .modifier(PodcastEpisodeSwipeActionsModifier(episode: episode))
                        }
                        EpisodeCatalogContinuation(totalCount: evaluation.count, visibleCount: $visibleEpisodeCount)
                    }
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background(alignment: .top) {
            PlaylistTintGlowBackground(tint: (summary.tint ?? .blue).color)
        }
        .contentMargins(.bottom, 72, for: .scrollContent)
        .animation(listAnimation, value: visibleEpisodes.map(\.episodeID))
        .navigationTitle(summary.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                PlaylistActionsMenu(
                    summary: summary,
                    canEnqueue: canEnqueue,
                    canDownloadAll: appModel.hasPlaylistDownloadAllCandidates(summary.playlistID)
                )
            }
        }
        // The age clause measures from the library's reference date; a smart
        // playlist opened from the Playlists tab or the playing-from pill
        // never passes through the Library screen that advances it.
        .onAppear(perform: appModel.library.advanceNewEpisodeReferenceDate)
    }

    private var listAnimation: Animation? {
        reduceMotion ? nil : .default
    }

    /// The candidate rule `OpenCastAppModel` plays a smart playlist with, so
    /// Play Next and Play Last are enabled exactly when they would queue
    /// something.
    private func isCandidate(_ episode: EpisodeListItemSnapshot) -> Bool {
        !appModel.library.progressSummary(for: episode).isCompleted
    }

    private func play(_ mode: PlaylistPlayMode) {
        appModel.playPlaylist(summary.playlistID, mode: mode, shuffle: false, modelContext: modelContext)
    }

    private func setRule(_ rule: PlaylistRule) {
        appModel.performPlaylistMutation {
            appModel.playlists.setRule(rule, for: summary.playlistID, modelContext: modelContext)
        }
    }
}
