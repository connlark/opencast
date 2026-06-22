import CoreData
import OpenCastCore
import SwiftData
import SwiftUI

struct OpenCastRootView: View {
    private static let remoteStoreChangeDebounce: Duration = .milliseconds(750)
    private static let emptyImportPollInterval: Duration = .seconds(1)
    private static let emptyImportPollAttempts = 15
    private static let importedSubscriptionsNotificationDuration: Duration = .seconds(5)

    @Environment(OpenCastAppModel.self) private var appModel
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.modelContext) private var modelContext
    @Environment(\.scenePhase) private var scenePhase

    @State private var selectedTab = AppSection.inbox
    @State private var selectedSection: AppSection? = .inbox
    @State private var selectedRoute: AppRoute?
    @State private var libraryNavigationPath: [AppRoute] = []
    @State private var inboxNavigationPath: [AppRoute] = []
    @State private var sheetDestination: SheetDestination?
    @State private var isNowPlayingPresented = false
    @State private var isInitialSetupComplete = false
    @State private var hasFlushedProgressForLifecycleExit = false
    @State private var importedDataRefreshTask: Task<Void, Never>?
    @State private var remoteStoreChangeReloadTask: Task<Void, Never>?
    @State private var emptyImportPollingTask: Task<Void, Never>?
    @State private var importedSubscriptionsNotificationDismissalTask: Task<Void, Never>?

    var body: some View {
        OpenCastRootLayerView(
            isNowPlayingPresented: isNowPlayingPresented,
            onPresentNowPlaying: presentNowPlaying,
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
                onOpenSettings: openSettings,
                onPresentDataNukeConfirmation: presentDataNukeConfirmation,
                onPresentNowPlaying: presentNowPlaying
            )
        }
        .modifier(
            OpenCastRootLifecycleModifier(
                hasFlushedProgressForLifecycleExit: $hasFlushedProgressForLifecycleExit,
                performInitialSetup: performInitialSetup,
                persistPlaybackProgress: persistPlaybackProgress,
                refreshImportedData: refreshImportedData,
                refreshSyncedUserData: refreshSyncedUserData,
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
        .onChange(of: appModel.library.activePodcastIDs) { _, activePodcastIDs in
            appModel.notificationSettings.scheduleSubscriptionSyncIfEnabled(activePodcastIDs: activePodcastIDs)
        }
        .task {
            await consumeRemoteEpisodeNotificationRoutes()
        }
        .task {
            await observeRemoteStoreChanges()
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

    private func openSettings() {
        if horizontalSizeClass == .regular {
            selectedSection = .settings
            selectedRoute = nil
        } else {
            selectedTab = .settings
        }
    }

    private func performInitialSetup() async {
        let activePodcastIDsBeforeInitialLoad = appModel.library.activePodcastIDs
        appModel.syncStatus.beginLibraryActivity(.checkingAccount)
        await appModel.library.load(modelContext: modelContext)
        appModel.downloads.load(modelContext: modelContext)
        appModel.appearanceSettings.load(modelContext: modelContext)
        appModel.playbackSettings.load(modelContext: modelContext, playback: appModel.playback)
        await appModel.notificationSettings.load(modelContext: modelContext)
        appModel.notificationPromoBanner.load(modelContext: modelContext)
        let accountStatus = await appModel.syncStatus.refreshAccountStatus(force: true)
        let didRepairSyncDuplicates = await repairSyncDuplicatesAfterImportedData()
        if didRepairSyncDuplicates {
            await hydrateImportedFeedsIfNeeded()
        }
        appModel.onboardingState.load(modelContext: modelContext)
        presentOnboardingIfNeeded()
        presentImportedSubscriptionsNotificationIfNeeded(
            addedFeedURLStrings: appModel.library.activePodcastIDs.subtracting(activePodcastIDsBeforeInitialLoad)
        )
        if didRepairSyncDuplicates {
            updateLibrarySyncActivityAfterImportCheck(accountStatus: accountStatus)
        }
        appModel.restorePreviousPlaybackIfAvailable(modelContext: modelContext)
        isInitialSetupComplete = true
        await appModel.refreshLibraryIfStale(modelContext: modelContext)
        appModel.cacheController.pruneIfNeeded()
        await runVoiceBoostDeviceProbeIfActive()
        await appModel.notificationSettings.refreshIfNeeded(
            activePodcastIDs: appModel.library.activePodcastIDs,
            modelContext: modelContext
        )
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

    private func consumeRemoteEpisodeNotificationRoutes() async {
        for await route in RemoteEpisodeNotificationRouteBridge.shared.routes() {
            await handleRemoteEpisodeNotificationRoute(route)
        }
    }

    private func observeRemoteStoreChanges() async {
        for await _ in NotificationCenter.default.notifications(
            named: Notification.Name.NSPersistentStoreRemoteChange
        ) {
            scheduleRemoteStoreChangeReload()
        }
    }

    private func scheduleRemoteStoreChangeReload() {
        remoteStoreChangeReloadTask?.cancel()
        remoteStoreChangeReloadTask = Task {
            do {
                try await Task.sleep(for: Self.remoteStoreChangeDebounce)
            } catch is CancellationError {
                return
            } catch {
                return
            }

            await refreshSyncedUserData()
            remoteStoreChangeReloadTask = nil
        }
    }

    private func refreshSyncedUserData() async {
        let activePodcastIDsBeforeReload = appModel.library.activePodcastIDs
        let result: SyncedUserDataReloadResult
        do {
            result = try appModel.library.reloadSyncedUserData(modelContext: modelContext)
        } catch {
            appModel.syncStatus.recordLibraryActivityFailure(error.localizedDescription)
            return
        }

        guard result.shouldProcessImportedSubscriptions else {
            return
        }

        await processImportedSubscriptionChanges(
            addedFeedURLStrings: appModel.library.activePodcastIDs.subtracting(activePodcastIDsBeforeReload)
        )
    }

    private func refreshImportedData() async {
        await refreshImportedData(startsEmptyImportPolling: true)
    }

    private func refreshImportedData(startsEmptyImportPolling: Bool) async {
        if let importedDataRefreshTask {
            await importedDataRefreshTask.value
            return
        }

        let task = Task {
            await performImportedDataRefresh(startsEmptyImportPolling: startsEmptyImportPolling)
        }
        importedDataRefreshTask = task
        await task.value
        importedDataRefreshTask = nil
    }

    private func performImportedDataRefresh(startsEmptyImportPolling: Bool) async {
        let activePodcastIDsBeforeReload = appModel.library.activePodcastIDs
        appModel.syncStatus.beginLibraryActivity(.reloading)

        do {
            try await appModel.library.reloadPersistedData(modelContext: modelContext)
        } catch {
            appModel.syncStatus.recordLibraryActivityFailure(error.localizedDescription)
            return
        }

        guard await repairSyncDuplicatesAfterImportedData() else {
            return
        }
        await hydrateImportedFeedsIfNeeded()
        let accountStatus = await appModel.syncStatus.refreshAccountStatus()
        updateLibrarySyncActivityAfterImportCheck(
            accountStatus: accountStatus,
            startsEmptyImportPolling: startsEmptyImportPolling
        )
        presentImportedSubscriptionsNotificationIfNeeded(
            addedFeedURLStrings: appModel.library.activePodcastIDs.subtracting(activePodcastIDsBeforeReload)
        )
    }

    private func processImportedSubscriptionChanges(addedFeedURLStrings: Set<String>) async {
        guard await repairSyncDuplicatesAfterImportedData() else {
            return
        }

        await hydrateImportedFeedsIfNeeded()
        if case .failed = appModel.library.state {
            return
        }

        appModel.syncStatus.finishLibraryActivity()
        presentImportedSubscriptionsNotificationIfNeeded(addedFeedURLStrings: addedFeedURLStrings)
    }

    private func repairSyncDuplicatesAfterImportedData() async -> Bool {
        appModel.syncStatus.beginLibraryActivity(.repairingDuplicates)
        await appModel.syncStatus.repairDuplicates(
            modelContext: modelContext,
            libraryStore: appModel.library
        )

        if let errorMessage = appModel.syncStatus.lastRepairErrorMessage {
            appModel.syncStatus.recordLibraryActivityFailure(errorMessage)
            return false
        }

        return true
    }

    @discardableResult
    private func hydrateImportedFeedsIfNeeded() async -> Bool {
        guard !appModel.library.feedURLStringsNeedingLocalCache.isEmpty else {
            return false
        }

        appModel.syncStatus.beginLibraryActivity(.syncingFeeds)
        let didRefresh = await appModel.library.refreshFeedsNeedingLocalCache(modelContext: modelContext)

        if case .failed(let message) = appModel.library.state {
            appModel.syncStatus.recordLibraryActivityFailure(message)
            return false
        }

        return didRefresh
    }

    private func updateLibrarySyncActivityAfterImportCheck(
        accountStatus: SyncAccountStatus,
        startsEmptyImportPolling: Bool = true
    ) {
        if case .failed(let message) = appModel.library.state {
            appModel.syncStatus.recordLibraryActivityFailure(message)
            return
        }

        guard accountStatus == .available, appModel.library.activePodcastIDs.isEmpty else {
            emptyImportPollingTask?.cancel()
            emptyImportPollingTask = nil
            appModel.syncStatus.finishLibraryActivity()
            return
        }

        appModel.syncStatus.beginLibraryActivity(.waitingForImports)
        if startsEmptyImportPolling {
            startEmptyImportPolling()
        }
    }

    private func startEmptyImportPolling() {
        guard emptyImportPollingTask == nil else {
            return
        }

        emptyImportPollingTask = Task {
            for _ in 0..<Self.emptyImportPollAttempts {
                do {
                    try await Task.sleep(for: Self.emptyImportPollInterval)
                } catch is CancellationError {
                    return
                } catch {
                    return
                }

                guard appModel.syncStatus.libraryActivity == .waitingForImports,
                      appModel.library.activePodcastIDs.isEmpty
                else {
                    return
                }

                await refreshImportedData(startsEmptyImportPolling: false)
                guard appModel.library.activePodcastIDs.isEmpty else {
                    emptyImportPollingTask = nil
                    return
                }
            }

            guard appModel.syncStatus.libraryActivity == .waitingForImports,
                  appModel.library.activePodcastIDs.isEmpty
            else {
                emptyImportPollingTask = nil
                return
            }

            appModel.syncStatus.finishLibraryActivity()
            emptyImportPollingTask = nil
        }
    }

    private func presentImportedSubscriptionsNotificationIfNeeded(addedFeedURLStrings: Set<String>) {
        guard appModel.onboardingState.shouldPresentOnboarding,
              !addedFeedURLStrings.isEmpty
        else {
            return
        }

        guard let notification = appModel.presentImportedSubscriptionsNotification(
            feedCount: addedFeedURLStrings.count
        ) else {
            return
        }

        importedSubscriptionsNotificationDismissalTask?.cancel()
        importedSubscriptionsNotificationDismissalTask = Task {
            do {
                try await Task.sleep(for: Self.importedSubscriptionsNotificationDuration)
            } catch is CancellationError {
                return
            } catch {
                return
            }

            appModel.dismissImportedSubscriptionsNotification(id: notification.id)
        }
    }

    private func handleRemoteEpisodeNotificationRoute(
        _ route: RemoteEpisodeNotificationRoute
    ) async {
        let canonicalFeedURL = URLCanonicalizer.canonicalString(forRawString: route.feedURL)
        let canonicalRoute = RemoteEpisodeNotificationRoute(
            feedURL: canonicalFeedURL,
            episodeID: route.episodeID,
            episodeTitle: route.episodeTitle
        )
        #if DEBUG || INTERNAL_NOTIFICATIONS_DIAGNOSTICS
        let diagnostics = RemoteEpisodeNotificationRouteDiagnostics.shared

        func record(_ status: String) {
            diagnostics.record(status, route: canonicalRoute, canonicalFeedURL: canonicalFeedURL)
        }
        #else
        func record(_ status: String) {}
        #endif

        record("Handling")
        await waitForInitialSetup()
        record("Setup Complete")

        guard appModel.library.isActivelySubscribed(to: canonicalFeedURL) else {
            record("Missing Subscription")
            routeToInbox()
            return
        }

        record("Refreshing")
        await appModel.library.refresh(feedURL: canonicalFeedURL, modelContext: modelContext)
        if appModel.library.episode(with: route.episodeID) != nil {
            record("Opened Episode")
            openRouteFromNowPlaying(.episodeDetail(id: route.episodeID))
        } else {
            record("Opened Podcast")
            openRouteFromNowPlaying(.podcastDetail(feedURL: canonicalFeedURL))
        }
    }

    private func waitForInitialSetup() async {
        while !isInitialSetupComplete && !Task.isCancelled {
            do {
                try await Task.sleep(for: .milliseconds(100))
            } catch {
                return
            }
        }
    }

    private func routeToInbox() {
        if horizontalSizeClass == .regular {
            selectedSection = .inbox
            selectedRoute = nil
        } else {
            selectedTab = .inbox
            inboxNavigationPath.removeAll()
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
        selectedTab = .inbox
        selectedSection = .inbox
        selectedRoute = nil
        libraryNavigationPath.removeAll()
        inboxNavigationPath.removeAll()
        sheetDestination = nil
        dismissNowPlaying()
        hasFlushedProgressForLifecycleExit = false
    }
}
