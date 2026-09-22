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

    let onAdd: () -> Void

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
                displaySettingsError
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
                    Button("Add", systemImage: "plus", action: onAdd)
                }
            }
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
                )
                .transition(.opacity)
            } else {
                List {
                    ForEach(subscriptions) { subscription in
                        LibrarySubscriptionRowView(
                            subscription: subscription,
                            showsNewEpisodeCount: displaySettings.showsNewEpisodeBadges
                        )
                    }
                }
                .accessibilityIdentifier("Library List")
                .transition(.opacity)
            }
        }
    }

    @ViewBuilder
    private var displaySettingsError: some View {
        if let message = displaySettings.lastErrorMessage {
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .font(.footnote)
                .foregroundStyle(.orange)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal)
                .padding(.vertical, 8)
                .background(.bar)
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
