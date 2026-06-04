import SwiftData
import SwiftUI

struct OpenCastRootView: View {
    @Environment(OpenCastAppModel.self) private var appModel
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.modelContext) private var modelContext
    @Environment(\.scenePhase) private var scenePhase

    @State private var selectedTab = AppSection.library
    @State private var selectedSection: AppSection? = .library
    @State private var selectedRoute: AppRoute?
    @State private var libraryNavigationPath: [AppRoute] = []
    @State private var inboxNavigationPath: [AppRoute] = []
    @State private var sheetDestination: SheetDestination?
    @State private var isNowPlayingPresented = false
    @State private var isInitialSetupComplete = false
    @State private var hasFlushedProgressForLifecycleExit = false

    var body: some View {
        OpenCastRootLayerView(
            isNowPlayingPresented: isNowPlayingPresented,
            onDismissNowPlaying: dismissNowPlaying,
            onOpenCurrentEpisode: openCurrentEpisodeFromNowPlaying,
            onOpenCurrentPodcast: openCurrentPodcastFromNowPlaying
        ) {
            OpenCastAdaptiveRootContentView(
                selectedTab: $selectedTab,
                selectedSection: $selectedSection,
                selectedRoute: $selectedRoute,
                libraryNavigationPath: $libraryNavigationPath,
                inboxNavigationPath: $inboxNavigationPath,
                isNowPlayingPresented: isNowPlayingPresented,
                onAdd: presentAddPodcast,
                onPresentDataNukeConfirmation: presentDataNukeConfirmation,
                onPresentNowPlaying: presentNowPlaying
            )
        }
        .modifier(
            OpenCastRootLifecycleModifier(
                hasFlushedProgressForLifecycleExit: $hasFlushedProgressForLifecycleExit,
                performInitialSetup: performInitialSetup,
                persistPlaybackProgress: persistPlaybackProgress,
                runVoiceBoostDeviceProbeIfActive: runVoiceBoostDeviceProbeIfActive
            )
        )
        .modifier(
            OpenCastRootRoutingModifier(
                sheetDestination: $sheetDestination,
                pruneSelectedRoute: pruneSelectedRoute,
                presentNowPlaying: presentNowPlaying,
                dismissNowPlaying: dismissNowPlaying,
                openExternalURL: openExternalURL
            )
        )
        .modifier(
            OpenCastRootPresentationModifier(
                sheetDestination: $sheetDestination
            )
        )
        .onChange(of: appModel.dataNukeCompletionID) { _, _ in
            resetAfterDataNuke()
        }
    }

    private func presentNowPlaying() {
        guard appModel.playback.currentEpisode != nil else {
            return
        }

        nowPlayingProbeMark("present-requested")
        appModel.isNowPlayingPresented = true
        isNowPlayingPresented = true
    }

    private func presentAddPodcast() {
        sheetDestination = .addPodcast
    }

    private func presentDataNukeConfirmation() {
        sheetDestination = .nukeConfirmation
    }

    private func presentOnboardingIfNeeded() {
        guard appModel.onboardingState.shouldPresentOnboarding else {
            return
        }

        presentOnboarding()
    }

    private func presentOnboarding() {
        sheetDestination = .onboarding
    }

    private func selectInitialSectionAfterLibraryLoad() {
        guard selectedTab == .library, selectedSection == .library else {
            return
        }
        guard !appModel.library.activePodcastIDs.isEmpty else {
            return
        }

        selectedTab = .inbox
        selectedSection = .inbox
    }

    private func performInitialSetup() async {
        appModel.library.load(modelContext: modelContext)
        selectInitialSectionAfterLibraryLoad()
        appModel.downloads.load(modelContext: modelContext)
        appModel.appearanceSettings.load(modelContext: modelContext)
        appModel.playbackSettings.load(modelContext: modelContext, playback: appModel.playback)
        appModel.onboardingState.load(modelContext: modelContext)
        presentOnboardingIfNeeded()
        appModel.restorePreviousPlaybackIfAvailable(modelContext: modelContext)
        isInitialSetupComplete = true
        await appModel.refreshLibraryIfStale(modelContext: modelContext)
        appModel.cacheController.pruneIfNeeded()
        await runVoiceBoostDeviceProbeIfActive()
        await appModel.syncStatus.refreshAccountStatus()
    }

    private func dismissNowPlaying() {
        appModel.isNowPlayingPresented = false
        isNowPlayingPresented = false
    }

    private func openCurrentEpisodeFromNowPlaying() {
        guard let episodeID = appModel.playback.currentEpisode?.id.rawValue else {
            return
        }

        openRouteFromNowPlaying(.episodeDetail(id: episodeID))
    }

    private func openCurrentPodcastFromNowPlaying() {
        guard let feedURL = appModel.playback.currentEpisode?.podcastID.rawValue else {
            return
        }

        openRouteFromNowPlaying(.podcastDetail(feedURL: feedURL))
    }

    private func openRouteFromNowPlaying(_ route: AppRoute) {
        if horizontalSizeClass == .regular {
            selectedSection = .library
            selectedRoute = route
        } else {
            selectedTab = .library
            libraryNavigationPath = [route]
        }
    }

    private func openExternalURL(_ url: URL) {
        guard url.isFileURL else {
            return
        }

        sheetDestination = .importOPMLFile(url)
    }

    private func runVoiceBoostDeviceProbeIfActive() async {
        #if DEBUG
        guard isInitialSetupComplete else {
            return
        }

        guard scenePhase == .active else {
            appModel.writeVoiceBoostDeviceProbeWaitingForActiveReportIfNeeded()
            return
        }

        await appModel.runVoiceBoostDeviceProbeIfNeeded(modelContext: modelContext)
        #endif
    }

    private func persistPlaybackProgress() async {
        guard appModel.playback.currentEpisode != nil else {
            return
        }

        while !Task.isCancelled {
            do {
                try await Task.sleep(for: .seconds(5))
            } catch is CancellationError {
                return
            } catch {
                return
            }

            guard appModel.playback.currentEpisode != nil else {
                return
            }
            guard appModel.playback.state == .playing else {
                continue
            }
            appModel.flushPlaybackProgress(
                modelContext: modelContext,
                refreshObservableProgress: scenePhase == .active
            )
        }
    }

    private func pruneSelectedRoute() {
        guard let selectedRoute else {
            return
        }

        switch selectedRoute {
        case .podcastDetail(let feedURL):
            if !appModel.library.isActivelySubscribed(to: feedURL) {
                self.selectedRoute = nil
            }
        case .episodeDetail(let id):
            if appModel.library.episode(with: id) == nil {
                self.selectedRoute = nil
            }
        }
    }

    private func resetAfterDataNuke() {
        selectedTab = .library
        selectedSection = .library
        selectedRoute = nil
        libraryNavigationPath.removeAll()
        inboxNavigationPath.removeAll()
        sheetDestination = nil
        dismissNowPlaying()
        hasFlushedProgressForLifecycleExit = false
    }
}
