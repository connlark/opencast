import SwiftData
import SwiftUI

struct LibraryView: View {
    @Environment(OpenCastAppModel.self) private var appModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.modelContext) private var modelContext
    @Environment(\.scenePhase) private var scenePhase
    @State private var sampleSubscriptionErrorMessage: String?
    @State private var isSubscribingSample = false
    @State private var namePromptRequest: PlaylistNamePromptRequest?

    let onAdd: () -> Void
    let onOpenUpNext: () -> Void

    private var displaySettings: LibraryDisplaySettingsStore {
        appModel.libraryDisplaySettings
    }

    private var layout: LibraryLayout {
        displaySettings.layout.resolved(isRegularWidth: horizontalSizeClass == .regular)
    }

    var body: some View {
        // Sorting reads release dates, never progress, so playback cannot
        // reorder the Library.
        let subscriptions = displaySettings.sortOrder.sorted(
            appModel.library.subscriptions,
            latestReleaseDate: appModel.library.latestReleasedEpisodeDate(forPodcastID:)
        )

        content(subscriptions: subscriptions)
            .animation(reduceMotion ? nil : .default, value: appModel.library.state)
            .animation(reduceMotion ? nil : .default, value: subscriptions.map(\.feedURL))
            .animation(reduceMotion ? nil : .default, value: layout)
            .safeAreaInset(edge: .top, spacing: 0) {
                SettingsErrorBanner(message: displaySettings.lastErrorMessage)
            }
            .navigationTitle("Library")
            .toolbarMinimizationBehavior(.onScrollDown, for: .navigationBar)
            .refreshable {
                await appModel.library.refreshAll(modelContext: modelContext)
            }
            .toolbar {
                if !subscriptions.isEmpty {
                    ToolbarItem(placement: .topBarTrailing) {
                        LibraryViewOptionsMenu(resolvedLayout: layout)
                    }
                    .visibilityPriority(.low)
                }

                ToolbarItem(placement: .topBarPinnedTrailing) {
                    Menu {
                        Button("Add Podcast", systemImage: "antenna.radiowaves.left.and.right", action: onAdd)
                        Button("New Playlist…", systemImage: "text.badge.plus", action: promptNewPlaylist)
                            .accessibilityIdentifier("New Playlist")
                    } label: {
                        Label("Add", systemImage: "plus")
                    }
                }
            }
            .playlistNamePrompt($namePromptRequest, onCommit: createPlaylist)
            .onAppear(perform: appModel.library.advanceNewEpisodeReferenceDate)
            .onChange(of: scenePhase) { _, scenePhase in
                if scenePhase == .active {
                    appModel.library.advanceNewEpisodeReferenceDate()
                }
            }
    }

    @ViewBuilder
    private func content(subscriptions: [SubscriptionRecord]) -> some View {
        switch appModel.library.state {
        case .loading where subscriptions.isEmpty:
            List {
                ProgressView()
            }
        case .failed(let message) where subscriptions.isEmpty:
            List {
                ContentUnavailableView(
                    "Library Unavailable",
                    systemImage: "exclamationmark.triangle",
                    description: Text(message)
                )
            }
        default:
            if subscriptions.isEmpty {
                List {
                    // Playlists outlive their shows and the Playlists tab is
                    // hidden on iPhone, so the rows stay while they lead
                    // somewhere; they are absent only when both are empty.
                    if hasCollections {
                        collectionsSection
                    }

                    LibraryEmptyStateView(
                        syncActivity: appModel.syncStatus.libraryActivity,
                        isSubscribingSample: isSubscribingSample,
                        sampleSubscriptionErrorMessage: sampleSubscriptionErrorMessage,
                        onAdd: onAdd,
                        onSubscribeSample: subscribeToSample
                    )
                }
            } else if layout == .grid {
                LibrarySubscriptionGridView(
                    subscriptions: subscriptions,
                    showsNewEpisodeCount: displaySettings.showsNewEpisodeBadges
                ) {
                    VStack(alignment: .leading, spacing: 12) {
                        collectionsHeader

                        Text("Shows")
                            .font(.title3)
                            .bold()
                            .accessibilityAddTraits(.isHeader)
                    }
                    .padding(.top, 4)
                }
                .transition(.opacity)
            } else {
                List {
                    collectionsSection

                    Section("Shows") {
                        ForEach(subscriptions) { subscription in
                            LibrarySubscriptionRowView(
                                subscription: subscription,
                                showsNewEpisodeCount: displaySettings.showsNewEpisodeBadges
                            )
                        }
                    }
                }
                .accessibilityIdentifier("Library List")
                .transition(.opacity)
            }
        }
    }

    private var hasCollections: Bool {
        !appModel.playlists.playlists.isEmpty || !appModel.upNextQueue.items.isEmpty
    }

    private var collectionsSection: some View {
        Section {
            collectionsHeader
                .listRowInsets(.vertical, 0)
                .listRowSeparator(.hidden)
                .listRowBackground(Color.clear)
        }
    }

    private var collectionsHeader: some View {
        LibraryCollectionsHeader(
            playlistCount: appModel.playlists.playlists.count,
            upNextCount: appModel.upNextQueue.items.count,
            onOpenUpNext: onOpenUpNext
        )
    }

    private func promptNewPlaylist() {
        namePromptRequest = .create()
    }

    private func createPlaylist(_ request: PlaylistNamePromptRequest, name: String) {
        appModel.performPlaylistMutation {
            appModel.playlists.create(name: name, kind: .manual, modelContext: modelContext)
        }
    }

    private func subscribeToSample() {
        guard !isSubscribingSample else {
            return
        }

        Task {
            await performSampleSubscription()
        }
    }

    private func performSampleSubscription() async {
        sampleSubscriptionErrorMessage = nil
        isSubscribingSample = true
        defer {
            isSubscribingSample = false
        }

        do {
            try await appModel.library.subscribe(
                to: OpenCastConstants.thisAmericanLifeFeedURL,
                modelContext: modelContext
            )
        } catch is CancellationError {
        } catch {
            sampleSubscriptionErrorMessage = error.localizedDescription
        }
    }
}
