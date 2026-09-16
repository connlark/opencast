import CoreData
import OpenCastCore
import SwiftData
import SwiftUI

struct OpenCastRootView: View {
    private static let emptyImportPollInterval: Duration = .seconds(1)
    private static let emptyImportPollAttempts = 15

    @Environment(OpenCastAppModel.self) private var appModel
    @Environment(\.modelContext) private var modelContext
    @Environment(\.scenePhase) private var scenePhase

    @State private var selectedTab = AppSection.inbox
    @State private var navigationPaths = AppNavigationPaths()
    @State private var sheetDestination: SheetDestination?
    @State private var isInitialSetupComplete = false
    @State private var initialSetupGate = InitialSetupGate()
    @State private var hasFlushedProgressForLifecycleExit = false
    @State private var importedDataRefreshTask: Task<Void, Never>?
    @State private var remoteStoreChangeArbiter = SyncedStoreRemoteChangeArbiter()
    @State private var foregroundMaintenanceGate = ForegroundMaintenanceGate()
    @State private var remoteStoreReloadScheduler = SyncedStoreReloadScheduler()
    @State private var emptyImportPollingTask: Task<Void, Never>?
    @State private var hasStartedTranscriptionBenchmark = false
    @State private var hasStartedSearchBenchmark = false
    @State private var hasStartedFeedBenchmark = false
    @State private var hasStartedSearchPerformance = false
    @State private var hasStartedSearchEvaluation = false
    @State private var hasStartedSearchColdStartSeed = false
    @State private var hasStartedUITestAutoPlay = false
    #if DEBUG
    @State private var hasStartedTranscriptionProof = false
    @State private var hasStartedAdFreePassBackgroundProbe = false
    @State private var hasStartedAdFreePassAutoStart = false
    @State private var hasStartedEpisodePanelTranscribeProbe = false
    @State private var hasStartedPCCBackgroundProbe = false
    @State private var hasStartedTranscriptIntelligenceToolProbe = false
    @State private var hasStartedTranscriptIntelligenceEvaluation = false
    #endif

    var body: some View {
        OpenCastRootLayerView(
            isNowPlayingPresented: appModel.isNowPlayingPresented,
            onDismissNowPlaying: dismissNowPlaying,
            onOpenCurrentEpisode: openCurrentEpisodeFromNowPlaying,
            onOpenCurrentPodcast: openCurrentPodcastFromNowPlaying
        ) {
            OpenCastTabRootView(
                selectedTab: $selectedTab,
                navigationPaths: $navigationPaths,
                isNowPlayingPresented: appModel.isNowPlayingPresented,
                onAdd: presentAddPodcast,
                onPresentNowPlaying: presentNowPlaying
            )
        }
        .modifier(
            OpenCastRootLifecycleModifier(
                hasFlushedProgressForLifecycleExit: $hasFlushedProgressForLifecycleExit,
                performInitialSetup: performInitialSetup,
                shouldRunForegroundMaintenance: shouldRunForegroundMaintenance,
                refreshImportedData: refreshImportedData,
                refreshSyncedUserData: refreshSyncedUserData,
                runVoiceBoostDeviceProbeIfActive: runVoiceBoostDeviceProbeIfActive
            )
        )
        .modifier(OpenCastSystemIntegrationModifier())
        .modifier(PerformanceDiagnosticsModifier())
        .modifier(ResumeWidgetPublicationModifier())
        .modifier(
            OpenCastRootRoutingModifier(
                sheetDestination: $sheetDestination,
                pruneNavigationPaths: pruneNavigationPaths,
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
        .onChange(of: appModel.systemSearchRequest, initial: true) { _, request in
            guard request != nil else { return }
            selectedTab = .search
            navigationPaths[.search] = []
            dismissNowPlaying()
        }
        .onChange(of: appModel.library.activePodcastIDs) { _, activePodcastIDs in
            appModel.notificationSettings.scheduleSubscriptionSyncIfEnabled(activePodcastIDs: activePodcastIDs)
        }
        .onChange(of: appModel.onboardingState.isCompleted) { _, isCompleted in
            if isCompleted {
                appModel.importedSubscriptionsNotification = nil
            }
        }
        .task {
            await consumeRemoteEpisodeNotificationRoutes()
        }
        .task {
            // Launch-scoped gate resolution: episode-menu
            // remote surfaces appear on fresh launch without visiting
            // Settings; later Settings mounts re-use the cached resolution.
            await appModel.remoteTranscriptionPurchases.prepare()
        }
        .task {
            await observeRemoteStoreChanges()
        }
        .task {
            await runTranscriptionBenchmarkIfRequested()
        }
        .task {
            await runSearchBenchmarkIfRequested()
        }
        .task {
            guard !hasStartedFeedBenchmark else { return }
            hasStartedFeedBenchmark = true
            guard ProcessInfo.processInfo.arguments.contains(FeedBenchmarkRunner.requestArgument) else { return }
            await initialSetupGate.wait()
            await FeedBenchmarkRunner.runIfRequested(library: appModel.library, modelContext: modelContext)
        }
        .task {
            await runSearchPerformanceIfRequested()
        }
        .task {
            await runSearchEvaluationIfRequested()
        }
        .task {
            guard !hasStartedSearchColdStartSeed else { return }
            hasStartedSearchColdStartSeed = true
            await SearchColdStartProbe.seedIfRequested(
                store: appModel.library.localCache
            )
        }
        .task {
            await runUITestAutoPlayIfRequested()
        }
        #if DEBUG
        .task {
            await runTranscriptionProofIfRequested()
        }
        .task {
            runAdFreePassBackgroundProbeIfRequested()
        }
        .task {
            runPCCBackgroundProbeIfRequested()
        }
        .task {
            runTranscriptIntelligenceToolProbeIfRequested()
        }
        .task {
            await runTranscriptIntelligenceEvaluationIfRequested()
        }
        .task {
            await runAdFreePassAutoStartIfRequested()
        }
        .task {
            await runEpisodePanelTranscribeProbeIfRequested()
        }
        #endif
    }

    private func presentNowPlaying() {
        guard appModel.hasNowPlayingPresentationContent else {
            return
        }

        nowPlayingProbeMark("present-requested")
        appModel.isNowPlayingPresented = true
    }

    private func presentAddPodcast() {
        sheetDestination = .addPodcast
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

    private func performInitialSetup() async {
        let activePodcastIDsBeforeInitialLoad = appModel.library.activePodcastIDs
        appModel.syncStatus.beginLibraryActivity(.checkingAccount)
        await appModel.ensurePlaybackSurfaceLoaded(modelContext: modelContext)
        appModel.appearanceSettings.load(modelContext: modelContext)
        appModel.recentSearches.load(modelContext: modelContext)
        await appModel.notificationSettings.load(modelContext: modelContext)
        let accountStatus = await appModel.syncStatus.refreshAccountStatus(force: true)
        let didRepairSyncDuplicates = await repairSyncDuplicatesAfterImportedData()
        appModel.onboardingState.load(modelContext: modelContext)
        presentOnboardingIfNeeded()
        presentImportedSubscriptionsNotificationIfNeeded(
            addedFeedURLStrings: appModel.library.activePodcastIDs.subtracting(activePodcastIDsBeforeInitialLoad)
        )
        if didRepairSyncDuplicates {
            updateLibrarySyncActivityAfterImportCheck(accountStatus: accountStatus)
        }
        appModel.restorePlaybackSurfaceIfNeeded(modelContext: modelContext)
        appModel.sweepPlayedDownloadsIfEnabled(modelContext: modelContext)
        isInitialSetupComplete = true
        SearchColdStartProbe.recordFirstUsableIfRequested()
        initialSetupGate.complete()
        OpenCastAppRuntime.shared.performanceDiagnostics.start()
        if didRepairSyncDuplicates {
            await hydrateImportedFeedsIfNeeded()
            updateLibrarySyncActivityAfterImportCheck(accountStatus: accountStatus)
            presentImportedSubscriptionsNotificationIfNeeded(
                addedFeedURLStrings: appModel.library.activePodcastIDs.subtracting(activePodcastIDsBeforeInitialLoad)
            )
        }
        await appModel.refreshLibraryIfStale(modelContext: modelContext)
        appModel.cacheController.pruneIfNeeded()
        await runVoiceBoostDeviceProbeIfActive()
        await appModel.notificationSettings.refreshIfNeeded(
            activePodcastIDs: appModel.library.activePodcastIDs,
            modelContext: modelContext
        )
    }

    private func dismissNowPlaying() {
        appModel.dismissNowPlayingAndDiscardFinishedPlayback()
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
        guard selectedTab != .settings else {
            openRouteInLibrary(route)
            return
        }
        if navigationPaths[selectedTab].last != route {
            navigationPaths[selectedTab].append(route)
        }
    }

    private func openRouteInLibrary(_ route: AppRoute) {
        selectedTab = .library
        navigationPaths[.library] = [route]
    }

    private func consumeRemoteEpisodeNotificationRoutes() async {
        for await route in RemoteEpisodeNotificationRouteBridge.shared.routes() {
            await handleRemoteEpisodeNotificationRoute(route)
        }
    }

    private func observeRemoteStoreChanges() async {
        // Both stores post remote-change notifications for every transaction,
        // including this process's own saves. Only genuinely remote
        // synced-store changes warrant the synced-data refetch: local-store
        // churn (download/transcription commits) is excluded by store URL,
        // and the app's own progress saves — periodic and boundary playback
        // flushes — are consumed as self-save credits by the arbiter, since
        // they already updated in-memory state on the way to the store.
        let syncedStoreURL = modelContext.container.configurations
            .first { $0.name == OpenCastModelContainerFactory.syncedConfigurationName }?
            .url.standardizedFileURL
        for await notification in NotificationCenter.default.notifications(
            named: Notification.Name.NSPersistentStoreRemoteChange
        ) {
            let changedStoreURL = (notification.userInfo?[NSPersistentStoreURLKey] as? URL)?
                .standardizedFileURL
            if remoteStoreChangeArbiter.shouldScheduleReload(
                changedStoreURL: changedStoreURL,
                syncedStoreURL: syncedStoreURL,
                selfSaveCount: appModel.library.syncedStoreSelfSaveCount
            ) {
                foregroundMaintenanceGate.recordRemoteChange()
                scheduleRemoteStoreChangeReload()
            }
        }
    }

    private func runTranscriptionBenchmarkIfRequested() async {
        guard !hasStartedTranscriptionBenchmark else {
            return
        }

        hasStartedTranscriptionBenchmark = true
        await TranscriptionBenchmarkRunner.runIfRequested()
    }

    private func runSearchBenchmarkIfRequested() async {
        guard !hasStartedSearchBenchmark else {
            return
        }

        hasStartedSearchBenchmark = true
        await SearchBenchmarkRunner.runIfRequested()
    }

    private func runSearchPerformanceIfRequested() async {
        guard !hasStartedSearchPerformance else {
            return
        }

        hasStartedSearchPerformance = true
        await SearchPerformanceRunner.runIfRequested()
    }

    private func runSearchEvaluationIfRequested() async {
        guard !hasStartedSearchEvaluation else {
            return
        }

        hasStartedSearchEvaluation = true
        await SearchEvaluationRunner.runIfRequested()
    }

    private func runUITestAutoPlayIfRequested() async {
        guard !hasStartedUITestAutoPlay else {
            return
        }
        guard UITestAutoPlayProbe.isRequested else {
            return
        }

        hasStartedUITestAutoPlay = true
        await UITestAutoPlayProbe.startWhenReady(
            appModel: appModel,
            modelContext: modelContext,
            isInitialSetupComplete: { isInitialSetupComplete }
        )
    }

    #if DEBUG
    private func runTranscriptionProofIfRequested() async {
        guard !hasStartedTranscriptionProof else {
            return
        }

        hasStartedTranscriptionProof = true
        await TranscriptionProofRunner.runIfRequested()
    }

    private func runAdFreePassBackgroundProbeIfRequested() {
        guard !hasStartedAdFreePassBackgroundProbe else {
            return
        }

        hasStartedAdFreePassBackgroundProbe = true
        AdFreePassBackgroundProbe.runIfRequested()
    }

    private func runPCCBackgroundProbeIfRequested() {
        guard !hasStartedPCCBackgroundProbe else {
            return
        }

        hasStartedPCCBackgroundProbe = true
        PCCBackgroundProbe.runIfRequested()
    }

    private func runTranscriptIntelligenceToolProbeIfRequested() {
        guard !hasStartedTranscriptIntelligenceToolProbe else {
            return
        }

        hasStartedTranscriptIntelligenceToolProbe = true
        TranscriptIntelligenceToolProbe.runIfRequested()
    }

    private func runTranscriptIntelligenceEvaluationIfRequested() async {
        guard !hasStartedTranscriptIntelligenceEvaluation else {
            return
        }

        hasStartedTranscriptIntelligenceEvaluation = true
        await TranscriptIntelligenceEvaluationRunner.runIfRequested()
    }

    private func runAdFreePassAutoStartIfRequested() async {
        guard !hasStartedAdFreePassAutoStart else {
            return
        }
        guard AdFreePassAutoStartProbe.isRequested else {
            return
        }

        hasStartedAdFreePassAutoStart = true
        await AdFreePassAutoStartProbe.startWhenReady(
            appModel: appModel,
            modelContext: modelContext,
            isInitialSetupComplete: { isInitialSetupComplete }
        )
    }

    private func runEpisodePanelTranscribeProbeIfRequested() async {
        guard !hasStartedEpisodePanelTranscribeProbe else {
            return
        }
        guard EpisodePanelTranscribeProbe.isRequested else {
            return
        }

        hasStartedEpisodePanelTranscribeProbe = true
        await EpisodePanelTranscribeProbe.startWhenReady(
            appModel: appModel,
            modelContext: modelContext,
            isInitialSetupComplete: { isInitialSetupComplete }
        )
    }
    #endif

    private func scheduleRemoteStoreChangeReload() {
        remoteStoreReloadScheduler.schedule {
            await refreshSyncedUserData()
        }
    }

    private func refreshSyncedUserData() async {
        await initialSetupGate.wait()
        guard !Task.isCancelled else { return }
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
            activePodcastIDsBeforeReload: activePodcastIDsBeforeReload
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
        presentImportedSubscriptionsNotificationIfNeeded(
            addedFeedURLStrings: appModel.library.activePodcastIDs.subtracting(activePodcastIDsBeforeReload)
        )
        await hydrateImportedFeedsIfNeeded()
        let accountStatus = await appModel.syncStatus.refreshAccountStatus()
        updateLibrarySyncActivityAfterImportCheck(
            accountStatus: accountStatus,
            startsEmptyImportPolling: startsEmptyImportPolling
        )
        presentImportedSubscriptionsNotificationIfNeeded(
            addedFeedURLStrings: appModel.library.activePodcastIDs.subtracting(activePodcastIDsBeforeReload)
        )
        appModel.library.pruneTrivialUnsubscribedProgressRecords(modelContext: modelContext)
        foregroundMaintenanceGate.recordCompletedPass()
    }

    private func shouldRunForegroundMaintenance() -> Bool {
        foregroundMaintenanceGate.shouldRunMaintenancePass()
    }

    private func processImportedSubscriptionChanges(activePodcastIDsBeforeReload: Set<String>) async {
        guard await repairSyncDuplicatesAfterImportedData() else {
            return
        }

        presentImportedSubscriptionsNotificationIfNeeded(
            addedFeedURLStrings: appModel.library.activePodcastIDs.subtracting(activePodcastIDsBeforeReload)
        )
        await hydrateImportedFeedsIfNeeded()
        // Hydration can publish another imported batch before the next remote
        // reload observes it. Include that batch in the same restore notice.
        presentImportedSubscriptionsNotificationIfNeeded(
            addedFeedURLStrings: appModel.library.activePodcastIDs.subtracting(activePodcastIDsBeforeReload)
        )
        if case .failed = appModel.library.state {
            return
        }

        appModel.syncStatus.finishLibraryActivity()
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
            defer {
                emptyImportPollingTask = nil
            }

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
                    return
                }
            }

            guard appModel.syncStatus.libraryActivity == .waitingForImports,
                  appModel.library.activePodcastIDs.isEmpty
            else {
                return
            }

            appModel.syncStatus.finishLibraryActivity()
        }
    }

    private func presentImportedSubscriptionsNotificationIfNeeded(addedFeedURLStrings: Set<String>) {
        guard appModel.onboardingState.shouldPresentOnboarding,
              !addedFeedURLStrings.isEmpty
        else {
            return
        }

        appModel.presentImportedSubscriptionsNotification(feedURLStrings: addedFeedURLStrings)
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
            openRouteInLibrary(.episodeDetail(id: route.episodeID))
        } else {
            record("Opened Podcast")
            openRouteInLibrary(.podcastDetail(feedURL: canonicalFeedURL))
        }
    }

    private func waitForInitialSetup() async {
        await initialSetupGate.wait()
    }

    private func routeToInbox() {
        selectedTab = .inbox
        navigationPaths[.inbox] = []
    }

    private func openExternalURL(_ url: URL) {
        if let action = ResumeWidgetRoute.action(for: url) {
            Task {
                do {
                    try await appModel.systemActions.perform(action, modelContext: modelContext)
                } catch is CancellationError {
                    return
                } catch let error as OpenCastSystemActionError {
                    appModel.lastPlaybackError = String(localized: error.localizedStringResource)
                } catch {
                    appModel.lastPlaybackError = error.localizedDescription
                }
            }
            return
        }
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


    private func pruneNavigationPaths() {
        navigationPaths.removeAll(where: isRouteInvalid)
    }

    private func isRouteInvalid(_ route: AppRoute) -> Bool {
        switch route {
        case .podcastDetail(let feedURL):
            !appModel.library.isActivelySubscribed(to: feedURL)
        case .episodeDetail(let id), .episodeTranscript(let id), .episodeArtwork(let id):
            appModel.library.episode(with: id) == nil && appModel.downloads.record(for: id) == nil
        case .adDetectionQueue, .settings:
            false
        }
    }

    private func resetAfterDataNuke() {
        appModel.importedSubscriptionsNotification = nil
        selectedTab = .inbox
        navigationPaths.removeAll()
        sheetDestination = nil
        presentOnboardingIfNeeded()
        dismissNowPlaying()
        hasFlushedProgressForLifecycleExit = false
    }
}
