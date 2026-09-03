import Foundation
import Observation
import OpenCastCore
import OpenCastPlayback
import OpenCastTranscription
import SwiftData
import UserNotifications

@Observable
final class OpenCastAppModel {
    /// The periodic synced flush only guards against a hard crash mid-listen
    /// (losing up to this much position is accepted); every deliberate exit -
    /// pause, seek, skip, background, completion, dismiss, episode switch -
    /// flushes through a boundary immediately. Writing the CloudKit-synced
    /// progress record every 5 seconds kept the export machinery churning for
    /// entire listening sessions.
    static let playbackProgressPersistenceInterval = Duration.seconds(60)

    let cacheController: OpenCastCacheController
    let httpClient: any OpenCastHTTPClient
    let library: LibraryStore
    let downloads: DownloadStore
    let transcriptionModels: TranscriptionModelStore
    let transcriptionEngineSettings: TranscriptionEngineSettingsStore
    let adDetectionSettings: AdDetectionSettingsStore
    let appleSpeechAssets: AppleSpeechAssetStore
    let transcriptions: EpisodeTranscriptionStore
    let transcriptionRequests: EpisodeTranscriptionRequestCoordinator
    let remoteTranscription: EpisodeRemoteTranscriptionCoordinator
    @ObservationIgnored private let remoteTranscriptionRunner: RemoteTranscriptionJobRunner
    @ObservationIgnored private let adFreePassEnqueueContext: AdFreePassEnqueueContext
    let remoteTranscriptionPurchases: RemoteTranscriptionPurchaseStore
    let adAnalyses: EpisodeAdAnalysisStore
    let transcriptAnalyses: EpisodeTranscriptAnalysisStore
    let adFreePass: EpisodeAdFreePassCoordinator
    let upNextQueue: UpNextQueueStore
    let adFreePassBackgroundSession: EpisodeAdFreePassBackgroundSession
    let transcriptGenerationBackgroundSession: EpisodeTranscriptGenerationBackgroundSession
    let transcriptImprovement: EpisodeTranscriptImprovementCoordinator
    let playback: AVFoundationPlaybackController
    let appearanceSettings: AppearanceSettingsStore
    let podcastEpisodeListSettings: PodcastEpisodeListSettingsStore
    let recentSearches: RecentSearchesStore
    let playbackSettings: PlaybackSettingsStore
    let notificationSettings: NotificationSettingsStore
    let onboardingState: OnboardingStateStore
    let voiceBoostDiagnostics: VoiceBoostAudioTapDiagnostics?
    let exposesVoiceBoostDiagnosticsStatus: Bool
    let runsVoiceBoostDeviceProbe: Bool
    let podcastDirectoryService: any PodcastDirectoryService
    let podcastDirectoryResolver: DirectoryFeedCandidateResolver
    let syncStatus: SyncStatusStore
    let allowsAutomaticFeedRefresh: Bool
    let adFreePassPresentationOverride: EpisodeAdFreePassPresentation?
    let adFreePassNotificationCenter: any AdFreePassNotificationCenter
    private(set) var finishedPlaybackPresentation: FinishedPlaybackPresentation?
    /// Tracked from the root lifecycle modifier. Completion notifications are
    /// suppressed while active, and leaving active discards the session-only
    /// Finished presentation.
    var isSceneActive = true {
        didSet {
            guard !isSceneActive, finishedPlaybackPresentation != nil else {
                return
            }

            dismissNowPlayingAndDiscardFinishedPlayback()
        }
    }
    var nowPlayingPresentationRequest = 0
    /// Single source of truth for Now Playing presentation; the root layer
    /// and tab views read this directly.
    var isNowPlayingPresented = false
    var hasNowPlayingPresentationContent: Bool {
        playback.currentEpisode != nil || finishedPlaybackPresentation != nil
    }
    var onboardingPresentationRequest = 0
    var lastPlaybackError: String?
    var lastUpNextError: String?
    /// Unsubscribe outcome surface, presented by the removal confirmation
    /// surfaces; unsubscribe failures never route through the playback error.
    var lastUnsubscribeErrorMessage: String?
    var importedSubscriptionsNotification: ImportedSubscriptionsNotification?
    var replacesNowPlayingArtworkWithPlaybackDiagnostics = false {
        didSet {
            guard oldValue != replacesNowPlayingArtworkWithPlaybackDiagnostics else {
                return
            }
            playback.setPlaybackDiagnosticsEnabled(replacesNowPlayingArtworkWithPlaybackDiagnostics)
        }
    }
    var isNukingData: Bool {
        dataNuke.isNukingData
    }
    var lastDataNukeErrorMessage: String? {
        dataNuke.lastErrorMessage
    }
    var dataNukeCompletionID: Int {
        dataNuke.completionID
    }
    var displayOnlySkipZones: [PlaybackSkipZone] {
        skipZones.displayOnlySkipZones
    }
    #if DEBUG
    var lastVoiceBoostDeviceProbeResult: String?
    var lastVoiceBoostDeviceProbeReportStatus: String?
    var lastVoiceBoostDeviceProbeApplicationState: String?
    #endif
    @ObservationIgnored private var coreStoresLoadTask: Task<Void, Never>?
    @ObservationIgnored private var playbackDependenciesLoadTask: Task<Void, Never>?
    @ObservationIgnored private var playbackSurfaceHydrationTask: Task<Void, Never>?
    @ObservationIgnored private var hasRestoredPlaybackSurface = false
    @ObservationIgnored private(set) var playbackSurfaceRestorationCount = 0
    @ObservationIgnored var playbackSurfaceRestorationObserver: ((Float) -> Void)?
    @ObservationIgnored var playbackProgressFlushObserver: (() -> Void)?
    @ObservationIgnored private var progressPersistenceTask: Task<Void, Never>?
    @ObservationIgnored private var progressBoundaryPersistenceTask: Task<Void, Never>?
    @ObservationIgnored private let playbackRestorePreference = PlaybackRestorePreferenceStore()
    /// Pending restore-key clear from the last playback teardown; tests
    /// await it before inspecting the store.
    @ObservationIgnored private(set) var deferredPlaybackTeardownTask: Task<Void, Never>?
    /// Set by launch restore, cleared implicitly by drift: the flush guard
    /// compares against it so a never-played restore never persists its
    /// smart-resume rewind.
    @ObservationIgnored private var restoredUnplayedPlayback: (episodeID: String, position: TimeInterval)?
    @ObservationIgnored private let skipZones: PlaybackSkipZoneCoordinator
    @ObservationIgnored private let downloadCleanup: DownloadCleanupCoordinator
    @ObservationIgnored private let dataNuke: DataNukeRunner
    @ObservationIgnored private let siriMediaDiscovery: SiriMediaDiscovery
    @ObservationIgnored private var siriMediaUserContextObservationTask: Task<Void, Never>?
    @ObservationIgnored private var hasRunVoiceBoostDeviceProbe = false
    @ObservationIgnored private var importedSubscriptionsNotificationID = 0
    @ObservationIgnored private let unsubscribeSidecarCleanupOverride: ((String, [String], ModelContext) throws -> Void)?
    @ObservationIgnored private let transcriptAnalysisQueue: TranscriptAnalysisQueue

    init(
        cacheController: OpenCastCacheController = OpenCastCacheController(),
        httpClient: (any OpenCastHTTPClient)? = nil,
        library: LibraryStore? = nil,
        localLibraryCacheStore: (any LocalLibraryCacheStore)? = nil,
        downloads: DownloadStore = DownloadStore(),
        transcriptionModels: TranscriptionModelStore = TranscriptionModelStore(),
        transcriptionEngineSettings: TranscriptionEngineSettingsStore = TranscriptionEngineSettingsStore(),
        adDetectionSettings: AdDetectionSettingsStore = AdDetectionSettingsStore(),
        appleSpeechAssets: AppleSpeechAssetStore = AppleSpeechAssetStore(),
        transcriptions: EpisodeTranscriptionStore = EpisodeTranscriptionStore(),
        adAnalyses: EpisodeAdAnalysisStore = EpisodeAdAnalysisStore(),
        transcriptAnalyses: EpisodeTranscriptAnalysisStore = EpisodeTranscriptAnalysisStore(),
        adFreePass: EpisodeAdFreePassCoordinator = EpisodeAdFreePassCoordinator(),
        upNextQueue: UpNextQueueStore = UpNextQueueStore(),
        adFreePassBackgroundSession: EpisodeAdFreePassBackgroundSession = EpisodeAdFreePassBackgroundSession(),
        transcriptGenerationBackgroundSession: EpisodeTranscriptGenerationBackgroundSession = EpisodeTranscriptGenerationBackgroundSession(),
        playback: AVFoundationPlaybackController? = nil,
        appearanceSettings: AppearanceSettingsStore = AppearanceSettingsStore(),
        podcastEpisodeListSettings: PodcastEpisodeListSettingsStore = PodcastEpisodeListSettingsStore(),
        recentSearches: RecentSearchesStore = RecentSearchesStore(),
        playbackSettings: PlaybackSettingsStore = PlaybackSettingsStore(),
        notificationSettings: NotificationSettingsStore = NotificationSettingsStore(),
        onboardingState: OnboardingStateStore = OnboardingStateStore(),
        voiceBoostDiagnostics: VoiceBoostAudioTapDiagnostics? = nil,
        exposesVoiceBoostDiagnosticsStatus: Bool = false,
        runsVoiceBoostDeviceProbe: Bool = false,
        podcastDirectoryService: (any PodcastDirectoryService)? = nil,
        syncStatus: SyncStatusStore = SyncStatusStore(),
        allowsAutomaticFeedRefresh: Bool = true,
        adFreePassPresentationOverride: EpisodeAdFreePassPresentation? = nil,
        adFreePassNotificationCenter: (any AdFreePassNotificationCenter)? = nil,
        siriMediaDiscovery: SiriMediaDiscovery = SiriMediaDiscovery(),
        unsubscribeSidecarCleanupOverride: ((String, [String], ModelContext) throws -> Void)? = nil
    ) {
        // Before any session configuration is built: configurations capture
        // the user agent at creation time.
        if let marketingVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String {
            OpenCastURLSessionFactory.setMarketingVersion(marketingVersion)
        }
        let resolvedHTTPClient = httpClient ?? URLSessionOpenCastHTTPClient(
            configuration: OpenCastURLSessionFactory.sharedConfiguration(
                cacheDirectory: cacheController.httpCacheDirectory
            )
        )

        self.cacheController = cacheController
        self.httpClient = resolvedHTTPClient
        let resolvedLibrary = library ?? LibraryStore(
            feedService: DefaultFeedService(httpClient: resolvedHTTPClient),
            localCache: localLibraryCacheStore ?? SQLiteLocalLibraryCacheStore(
                databaseURL: SQLiteLocalLibraryCacheStore.defaultDatabaseURL()
            )
        )
        self.library = resolvedLibrary
        self.downloads = downloads
        self.transcriptionModels = transcriptionModels
        self.transcriptionEngineSettings = transcriptionEngineSettings
        self.adDetectionSettings = adDetectionSettings
        self.appleSpeechAssets = appleSpeechAssets
        self.transcriptions = transcriptions
        transcriptions.episodeSearchIndexStore = resolvedLibrary.localCache
        self.transcriptionRequests = EpisodeTranscriptionRequestCoordinator(
            library: resolvedLibrary,
            downloads: downloads,
            transcriptionModels: transcriptionModels,
            transcriptionEngineSettings: transcriptionEngineSettings,
            appleSpeechAssets: appleSpeechAssets,
            transcriptions: transcriptions
        )
        let remoteTranscriptionAPI: any RemoteTranscriptionAPI
        #if DEBUG
        remoteTranscriptionAPI = RemoteTranscriptionAPIClient()
        #else
        remoteTranscriptionAPI = RemoteTranscriptionRoutedAPIClient()
        #endif
        self.remoteTranscription = EpisodeRemoteTranscriptionCoordinator(
            api: remoteTranscriptionAPI,
            downloads: downloads,
            transcriptions: transcriptions
        )
        // Cloud detect passes share the plain surface's job store (purpose-
        // keyed references, one balance) through their own runner instance.
        self.remoteTranscriptionRunner = RemoteTranscriptionJobRunner(
            api: remoteTranscriptionAPI,
            downloads: downloads,
            transcriptions: transcriptions,
            store: remoteTranscription.store
        )
        self.remoteTranscriptionPurchases = RemoteTranscriptionPurchaseStore(
            api: remoteTranscriptionAPI,
            storeKit: LiveRemoteTranscriptionStoreKitClient()
        )
        #if DEBUG
        if let purchaseFixture = RemoteTranscriptionPurchaseUIFixture.requested() {
            switch purchaseFixture {
            case .reviewScreenshot:
                remoteTranscriptionPurchases.applyReviewScreenshotFixture()
            case .unavailable:
                remoteTranscriptionPurchases.applyUnavailableFixture()
            case .delayedAvailability:
                remoteTranscriptionPurchases.applyDelayedAvailabilityFixture()
            }
        }
        if RemoteTranscriptionDevFlag.isEnabled,
           let fixture = RemoteTranscriptionUIFixture.fromLaunchArguments() {
            fixture.fixture.apply(
                to: remoteTranscription.store,
                episodeID: fixture.episodeID
            )
        }
        #endif
        self.adAnalyses = adAnalyses
        self.transcriptAnalyses = transcriptAnalyses
        transcriptAnalysisQueue = TranscriptAnalysisQueue(
            transcriptAnalyses: transcriptAnalyses,
            transcriptions: transcriptions,
            library: resolvedLibrary
        )
        resolvedLibrary.episodeSidecarMigrators = [downloads, transcriptions, adAnalyses, transcriptAnalyses]
        notificationSettings.feedHealthRecorder = { [weak resolvedLibrary] records in
            await resolvedLibrary?.recordNotificationFeedHealth(records)
        }
        adFreePassEnqueueContext = AdFreePassEnqueueContext(
            downloads: downloads,
            transcriptionModels: transcriptionModels,
            appleSpeechAssets: appleSpeechAssets,
            transcriptions: transcriptions,
            adAnalyses: adAnalyses,
            remoteRunner: remoteTranscriptionRunner,
            remoteJobStore: remoteTranscription.store,
            remotePurchases: remoteTranscriptionPurchases
        )
        self.adFreePass = adFreePass
        self.upNextQueue = upNextQueue
        self.adFreePassBackgroundSession = adFreePassBackgroundSession
        self.transcriptGenerationBackgroundSession = transcriptGenerationBackgroundSession
        self.transcriptImprovement = EpisodeTranscriptImprovementCoordinator(
            appleSpeechAssets: appleSpeechAssets,
            transcriptions: transcriptions
        )
        self.playback = playback ?? AVFoundationPlaybackController(
            nowPlayingArtworkLoader: SharedNowPlayingArtworkLoader()
        )
        skipZones = PlaybackSkipZoneCoordinator(
            playback: self.playback,
            transcriptions: transcriptions,
            adAnalyses: adAnalyses
        )
        downloadCleanup = DownloadCleanupCoordinator(
            downloads: downloads,
            transcriptions: transcriptions,
            library: resolvedLibrary,
            playback: self.playback,
            adFreePass: adFreePass
        )
        self.appearanceSettings = appearanceSettings
        self.podcastEpisodeListSettings = podcastEpisodeListSettings
        self.recentSearches = recentSearches
        self.playbackSettings = playbackSettings
        self.notificationSettings = notificationSettings
        self.onboardingState = onboardingState
        self.voiceBoostDiagnostics = voiceBoostDiagnostics
        self.exposesVoiceBoostDiagnosticsStatus = exposesVoiceBoostDiagnosticsStatus
        self.runsVoiceBoostDeviceProbe = runsVoiceBoostDeviceProbe
        let resolvedPodcastDirectoryService = podcastDirectoryService
            ?? Self.defaultPodcastDirectoryService(httpClient: resolvedHTTPClient)
        self.podcastDirectoryService = resolvedPodcastDirectoryService
        podcastDirectoryResolver = DirectoryFeedCandidateResolver(
            feedService: DefaultFeedService(httpClient: resolvedHTTPClient)
        )
        self.syncStatus = syncStatus
        self.allowsAutomaticFeedRefresh = allowsAutomaticFeedRefresh
        self.adFreePassPresentationOverride = adFreePassPresentationOverride
        self.adFreePassNotificationCenter = adFreePassNotificationCenter ?? UNUserNotificationCenter.current()
        self.siriMediaDiscovery = siriMediaDiscovery
        dataNuke = DataNukeRunner(
            syncStatus: syncStatus,
            library: resolvedLibrary,
            downloads: downloads,
            transcriptions: transcriptions,
            adAnalyses: adAnalyses,
            transcriptAnalyses: transcriptAnalyses,
            transcriptionModels: transcriptionModels,
            cacheController: cacheController,
            siriMediaDiscovery: siriMediaDiscovery
        )
        self.unsubscribeSidecarCleanupOverride = unsubscribeSidecarCleanupOverride
        self.transcriptions.onEpisodeStateChanged = { [weak self] episodeID in
            self?.skipZones.refreshIfCurrentEpisode(episodeID: episodeID)
        }
        transcriptAnalysisQueue.resolveEpisode = { [weak self] episodeID in
            self?.episodeSnapshot(for: episodeID)
        }
        dataNuke.prepareRuntime = { [weak self] in
            await self?.prepareRuntimeForDataNuke()
        }
        dataNuke.resetRuntime = { [weak self] modelContext in
            await self?.resetRuntimeStateAfterDataNuke(modelContext: modelContext)
        }
        remoteTranscriptionPurchases.onBalanceIncreased = { [weak self] in
            self?.transcriptAnalysisQueue.retryDeferredAfterBalanceIncrease()
        }
        self.transcriptions.onAppleSpeechRunInterrupted = { [weak self] episodeID, restoredPriorTranscript in
            self?.scheduleTranscriptionInterruptedNotificationIfNeeded(
                episodeID: episodeID,
                restoredPriorTranscript: restoredPriorTranscript
            )
        }
        self.adAnalyses.onEpisodeStateChanged = { [weak self] episodeID in
            self?.skipZones.refreshIfCurrentEpisode(episodeID: episodeID)
        }
        self.adFreePass.onStageChange = { [weak self] stage, queueContext in
            self?.adFreePassBackgroundSession.noteStage(stage, queueContext: queueContext)
        }
        self.adFreePass.onQueueTerminal = { [weak self] outcome in
            guard let self else {
                return
            }
            self.adFreePassBackgroundSession.noteQueueTerminal(outcome)
            self.scheduleAdFreePassCompletionNotificationIfNeeded(terminal: outcome)
        }
        self.adFreePass.isBackgroundProtected = { [weak self] in
            self?.adFreePassBackgroundSession.isProtectingBackgroundExecution ?? false
        }
        self.transcriptionRequests.onPhaseChange = { [weak self] phase in
            guard let self else {
                return
            }
            self.transcriptGenerationBackgroundSession.notePhase(phase)
            if phase == .transcribingAppleSpeech {
                self.requestLocalNotificationAuthorizationIfNeeded()
            }
        }
        transcriptGenerationBackgroundSession.installFraction = { [weak self] in
            guard case .installing(let progress) = self?.transcriptionModels.state,
                  progress.totalByteCount > 0
            else {
                return nil
            }
            return Double(progress.completedByteCount) / Double(progress.totalByteCount)
        }
        transcriptGenerationBackgroundSession.transcriptionProgress = { [weak self] in
            guard let self,
                  let episodeID = self.transcriptionRequests.request?.episodeID
            else {
                return nil
            }
            return self.transcriptions.progressByEpisodeID[episodeID]
        }
        let playbackController = self.playback
        upNextQueue.onQueueChanged = { [weak playbackController, weak upNextQueue] in
            playbackController?.setHasQueuedNextEpisode(!(upNextQueue?.items.isEmpty ?? true))
        }
        startSiriMediaUserContextObservation()
    }

    deinit {
        siriMediaUserContextObservationTask?.cancel()
    }

    func ensureCoreStoresLoaded(modelContext: ModelContext) async {
        playback.setRemotePlaybackRateChangeHandler { [weak self, weak modelContext] rate in
            guard let self, let modelContext else {
                return
            }
            self.setPlaybackRate(rate, modelContext: modelContext)
        }
        playback.setEpisodeFinishedHandler { [weak self, weak modelContext] episode, policy in
            guard let self, let modelContext else {
                return
            }
            handlePlaybackEpisodeFinished(
                episode,
                policy: policy,
                modelContext: modelContext
            )
        }
        playback.setNextTrackHandler { [weak self, weak modelContext] in
            guard let self, let modelContext else {
                return
            }
            advanceToNextQueuedEpisode(modelContext: modelContext)
        }
        if let coreStoresLoadTask {
            await coreStoresLoadTask.value
            return
        }

        let task = Task {
            let didLoadLibrary = await library.load(modelContext: modelContext)
            await downloads.load(modelContext: modelContext)
            playbackSettings.load(modelContext: modelContext, playback: playback)
            podcastEpisodeListSettings.load(modelContext: modelContext)
            upNextQueue.load(
                resolveEpisode: { [weak self] episodeID in
                    self?.episodeSnapshot(for: episodeID)
                },
                mayPruneUnresolved: didLoadLibrary,
                modelContext: modelContext
            )
            if let message = upNextQueue.consumeLastErrorMessage() {
                lastUpNextError = message
            }
        }
        coreStoresLoadTask = task
        await task.value
    }

    /// Everything playback reads before it can start correctly: transcripts and
    /// ad analyses back the skip zones installed on load, and the auto-detect
    /// decision on play. A CarPlay-only launch has no phone setup pass to load
    /// them, so both surfaces share this one-shot.
    func ensurePlaybackDependenciesLoaded(modelContext: ModelContext) async {
        if let playbackDependenciesLoadTask {
            await playbackDependenciesLoadTask.value
            return
        }

        let task = Task {
            loadLocalTranscriptionState(modelContext: modelContext)
        }
        playbackDependenciesLoadTask = task
        await task.value
    }

    func ensurePlaybackSurfaceLoaded(modelContext: ModelContext) async {
        await ensureCoreStoresLoaded(modelContext: modelContext)
        await ensurePlaybackDependenciesLoaded(modelContext: modelContext)
    }

    func ensurePlaybackSurfaceHydrated(modelContext: ModelContext) async {
        if let playbackSurfaceHydrationTask {
            await playbackSurfaceHydrationTask.value
            return
        }

        let task = Task {
            await ensurePlaybackSurfaceLoaded(modelContext: modelContext)
            restorePlaybackSurfaceIfNeeded(modelContext: modelContext)
        }
        playbackSurfaceHydrationTask = task
        await task.value
    }

    func restorePlaybackSurfaceIfNeeded(modelContext: ModelContext) {
        guard !hasRestoredPlaybackSurface else {
            return
        }

        hasRestoredPlaybackSurface = true
        playbackSurfaceRestorationCount += 1
        playbackSurfaceRestorationObserver?(playback.rate)
        startPlaybackProgressPersistence(modelContext: modelContext)
        restorePreviousPlaybackIfAvailable(modelContext: modelContext)
        restoreAdFreePassQueue(modelContext: modelContext)
    }

    /// Progress persistence has to outlive any one scene: a CarPlay-only launch
    /// never builds the phone scene, and without this a whole drive's listening
    /// would be lost when the process goes away.
    func startPlaybackProgressPersistence(modelContext: ModelContext) {
        guard progressPersistenceTask == nil else {
            return
        }

        progressPersistenceTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.playbackProgressPersistenceInterval)
                guard let self, !Task.isCancelled else {
                    return
                }
                guard playback.state == .playing else {
                    continue
                }

                flushPlaybackProgress(
                    modelContext: modelContext,
                    refreshObservableProgress: isSceneActive
                )
            }
        }

        progressBoundaryPersistenceTask = Task { [weak self] in
            for await _ in Observations({ self?.playback.progressBoundaryID ?? 0 }) {
                guard let self, !Task.isCancelled else {
                    return
                }

                flushPlaybackProgress(
                    modelContext: modelContext,
                    refreshObservableProgress: isSceneActive && !isNowPlayingPresented
                )
            }
        }
    }

    func playEpisode(
        _ episode: EpisodeListItemSnapshot,
        presentsNowPlaying: Bool = true,
        modelContext: ModelContext
    ) throws {
        try play(
            episode,
            source: preferredPlaybackSource(for: episode.episodeID),
            presentsNowPlaying: presentsNowPlaying,
            modelContext: modelContext
        )
    }

    @discardableResult
    func advanceToNextQueuedEpisode(modelContext: ModelContext) -> Bool {
        var hadCandidate = false
        var playbackFailureMessage: String?

        while true {
            let item: UpNextQueueItem
            switch upNextQueue.popNext(modelContext: modelContext) {
            case .item(let nextItem):
                item = nextItem
                hadCandidate = true
            case .empty:
                flushPlaybackProgress(modelContext: modelContext)
                if hadCandidate {
                    lastPlaybackError = playbackFailureMessage
                        ?? "None of the episodes in Up Next are available to play."
                }
                return false
            case .failure(let message):
                flushPlaybackProgress(modelContext: modelContext)
                lastUpNextError = upNextQueue.consumeLastErrorMessage() ?? message
                return false
            }

            guard let episode = episodeSnapshot(for: item.episodeID) else {
                continue
            }

            do {
                try playEpisode(
                    episode,
                    presentsNowPlaying: false,
                    modelContext: modelContext
                )
                return true
            } catch {
                playbackFailureMessage = error.localizedDescription
            }
        }
    }

    func handlePlaybackEpisodeFinished(
        _ episode: Episode,
        policy: PlaybackCompletionPolicy,
        modelContext: ModelContext
    ) {
        guard playback.currentEpisode?.id == episode.id else {
            return
        }

        switch policy {
        case .advanceIfQueued:
            guard !advanceToNextQueuedEpisode(modelContext: modelContext) else {
                return
            }
        case .stop:
            flushPlaybackProgress(modelContext: modelContext)
        }

        unloadFinishedPlayback(retainingPresentationFor: episode, modelContext: modelContext)
    }

    @discardableResult
    func replayFinishedPlayback(modelContext: ModelContext) -> Bool {
        guard let finishedPlaybackPresentation else {
            return false
        }

        do {
            try playEpisode(
                finishedPlaybackPresentation.episode,
                presentsNowPlaying: false,
                modelContext: modelContext
            )
            return true
        } catch {
            lastPlaybackError = error.localizedDescription
            return false
        }
    }

    func dismissNowPlayingAndDiscardFinishedPlayback() {
        finishedPlaybackPresentation = nil
        isNowPlayingPresented = false
    }

    private func unloadFinishedPlayback(
        retainingPresentationFor episode: Episode,
        modelContext: ModelContext
    ) {
        nowPlayingProbeMark("playback-finished")
        let episodeSnapshot = currentPlaybackEpisodeSnapshot ?? EpisodeListItemSnapshot(episode: episode)
        if isSceneActive, isNowPlayingPresented {
            finishedPlaybackPresentation = FinishedPlaybackPresentation(episode: episodeSnapshot)
        } else {
            dismissNowPlayingAndDiscardFinishedPlayback()
        }

        unloadPlaybackDeferringBookkeeping(modelContext: modelContext)
    }

    /// Unloads synchronously so the frame that follows already shows the
    /// post-playback state, then clears the restore key and sweeps played
    /// downloads one main-actor turn later: neither needs to land in that
    /// frame, and neither may be lost on process death, so they stay on the
    /// main actor instead of a background queue.
    private func unloadPlaybackDeferringBookkeeping(modelContext: ModelContext) {
        playback.unload()
        guard deferredPlaybackTeardownTask == nil else {
            return
        }

        deferredPlaybackTeardownTask = Task { [weak self] in
            self?.finishDeferredPlaybackTeardown(modelContext: modelContext)
        }
    }

    private func finishDeferredPlaybackTeardown(modelContext: ModelContext) {
        deferredPlaybackTeardownTask = nil
        // Replay or a restore may have started a new episode in the meantime;
        // its restore key must survive.
        if playback.currentEpisode == nil {
            playbackRestorePreference.clear(modelContext: modelContext)
        }
        sweepPlayedDownloadsIfEnabled(modelContext: modelContext)
    }

    func performUpNextQueueMutation(_ mutation: () -> Bool) {
        guard !mutation() else {
            return
        }
        lastUpNextError = upNextQueue.consumeLastErrorMessage()
    }

    /// A completed download is the preferred source for any playback: it is
    /// offline, byte-stable, and the copy that transcripts and ad analyses
    /// describe. Dynamic enclosure URLs can return a different audio assembly
    /// per request, so streaming is the fallback, not the default.
    private func preferredPlaybackSource(for episodeID: String) -> EpisodePlaybackSource {
        guard let record = downloads.record(for: episodeID),
              record.state == .completed,
              downloads.downloadedFileExists(for: record)
        else {
            return .stream
        }
        return .downloaded(record)
    }

    func episodeSnapshot(for episodeID: String) -> EpisodeListItemSnapshot? {
        if let episode = library.episode(with: episodeID) {
            return episode
        }

        guard let downloadRecord = downloads.record(for: episodeID) else {
            return nil
        }

        return EpisodeListItemSnapshot(
            downloadRecord: downloadRecord,
            podcastCache: library.podcastCache(for: downloadRecord.podcastID)
        )
    }

    /// Starts an episode from its transcript (a tapped line or the play
    /// button), using the completed download only when its trusted byte
    /// identity matches the transcript's recorded source hash. An unproven
    /// local file or a fresh dynamic-stream response can be a different audio
    /// assembly than the one transcribed, which no seek can realign.
    func playEpisode(
        _ episode: EpisodeListItemSnapshot,
        at startPosition: TimeInterval?,
        matchingSourceSHA256 sourceSHA256: String,
        presentsNowPlaying: Bool = true,
        autoplay: Bool = true,
        modelContext: ModelContext
    ) throws {
        let source: EpisodePlaybackSource
        if TranscriptSourceAlignment.downloadMatchesTranscript(
            trustedDownloadSHA256: downloads.completedSourceIdentity(for: episode.episodeID)?.sha256,
            documentSHA256: sourceSHA256
        ), let downloadRecord = downloads.record(for: episode.episodeID) {
            source = .downloaded(downloadRecord)
        } else {
            source = preferredPlaybackSource(for: episode.episodeID)
        }
        try play(
            episode,
            source: source,
            startPosition: startPosition,
            presentsNowPlaying: presentsNowPlaying,
            autoplay: autoplay,
            modelContext: modelContext
        )
    }

    func playDownloadedEpisode(
        _ episode: EpisodeListItemSnapshot,
        downloadRecord: EpisodeDownloadRecord,
        modelContext: ModelContext
    ) throws {
        try play(episode, source: .downloaded(downloadRecord), modelContext: modelContext)
    }

    @discardableResult
    func unsubscribe(
        feedURL: String,
        modelContext: ModelContext,
        clearListeningHistory: Bool = false
    ) async -> PodcastUnsubscribeOutcome {
        lastUnsubscribeErrorMessage = nil
        let podcastID = PodcastID(rawValue: feedURL)
        if playback.currentEpisode?.podcastID == podcastID {
            // Unsubscribe keeps listening history by default, so the position
            // since the last periodic flush must land before unload discards
            // it. Pointless when the history is being cleared anyway.
            if !clearListeningHistory {
                _ = flushPlaybackProgress(modelContext: modelContext)
            }
            dismissNowPlayingAndDiscardFinishedPlayback()
            playback.unload()
            playbackRestorePreference.clear(modelContext: modelContext)
        }

        // Captured before the authoritative delete clears the feed's cache;
        // the voice-boost sweep needs the episode IDs afterwards.
        let episodeIDs = library.episodes(forPodcastID: feedURL).map(\.episodeID)

        // The authoritative subscription delete runs first: a failure there
        // must leave a still-subscribed feed with its sidecars intact.
        await library.unsubscribe(
            feedURL: feedURL,
            modelContext: modelContext,
            clearListeningHistory: clearListeningHistory
        )
        guard !library.isActivelySubscribed(to: feedURL) else {
            let message = library.lastErrorMessage
                ?? "Unable to remove this podcast."
            lastUnsubscribeErrorMessage = message
            return .failed(message: message)
        }

        // Sidecar cleanup is best-effort once the subscription is gone.
        var sidecarErrorMessage: String?
        if !upNextQueue.removeAll(forPodcastID: feedURL, modelContext: modelContext) {
            sidecarErrorMessage = upNextQueue.lastErrorMessage
        }
        // Downloads are destroyed only after the delete is confirmed — files
        // cannot be rolled back, and dynamic enclosures mean a re-download
        // may not be byte-identical — and route through the transcription
        // hook like every other download-deletion path.
        do {
            try downloadCleanup.deleteDownloads(forPodcastID: feedURL, modelContext: modelContext)
        } catch {
            sidecarErrorMessage = sidecarErrorMessage ?? error.localizedDescription
        }
        if let unsubscribeSidecarCleanupOverride {
            do {
                try unsubscribeSidecarCleanupOverride(feedURL, episodeIDs, modelContext)
            } catch {
                sidecarErrorMessage = sidecarErrorMessage ?? error.localizedDescription
            }
        } else {
            do {
                try adAnalyses.deleteAnalyses(forPodcastID: feedURL, modelContext: modelContext)
                try transcriptAnalyses.deleteAnalyses(forPodcastID: feedURL, modelContext: modelContext)
                try transcriptions.deleteTranscripts(forPodcastID: feedURL, modelContext: modelContext)
            } catch {
                sidecarErrorMessage = sidecarErrorMessage ?? error.localizedDescription
            }
            if !podcastEpisodeListSettings.removePreferences(
                forPodcastID: feedURL,
                modelContext: modelContext
            ) {
                sidecarErrorMessage = sidecarErrorMessage ?? podcastEpisodeListSettings.lastErrorMessage
            }
            if !playbackSettings.removeVoiceBoostPreferences(
                forEpisodeIDs: episodeIDs,
                modelContext: modelContext
            ) {
                sidecarErrorMessage = sidecarErrorMessage ?? playbackSettings.lastErrorMessage
            }
        }
        let warning = sidecarErrorMessage.map {
            "The podcast was removed, but some of its stored data could not be cleaned up: \($0)"
        }
        lastUnsubscribeErrorMessage = warning
        siriMediaDiscovery.deleteDonations(forPodcastID: feedURL)
        return .removed(warning: warning)
    }

    func loadLocalTranscriptionState(modelContext: ModelContext) {
        transcriptionModels.load(modelContext: modelContext)
        transcriptionEngineSettings.load(modelContext: modelContext)
        adDetectionSettings.load(modelContext: modelContext)
        transcriptions.load(modelContext: modelContext)
        adAnalyses.load(modelContext: modelContext)
        transcriptAnalyses.load(modelContext: modelContext)
        // Launch is the "retry next day" moment for cap-deferred runs; the
        // scene-activation probe can fire before this load and find nothing.
        transcriptAnalysisQueue.retryDeferred(modelContext: modelContext, trigger: .launch)
        refreshPlaybackSkipZonesForCurrentEpisode()
        Task { [appleSpeechAssets] in
            await appleSpeechAssets.refresh()
        }
    }

    @discardableResult
    func setTranscriptionModelChoice(
        _ choice: TranscriptionModelChoice,
        modelContext: ModelContext
    ) -> Bool {
        guard !transcriptions.hasActiveJob else {
            transcriptionModels.fail("Finish or cancel the active transcript before changing the speech model.")
            return false
        }

        return transcriptionModels.setSelectedChoice(choice, modelContext: modelContext)
    }

    @discardableResult
    func installTranscriptionModel() -> Bool {
        guard !transcriptions.hasActiveJob else {
            transcriptionModels.fail("Finish or cancel the active transcript before installing the speech model.")
            return false
        }
        return transcriptionModels.installPinnedModel()
    }

    func cancelTranscriptionModelInstall() {
        transcriptionModels.cancelInstall()
    }

    func checkTranscriptionModel() {
        transcriptionModels.checkRemoteManifest()
    }

    @discardableResult
    func repairTranscriptionModel() -> Bool {
        guard !transcriptions.hasActiveJob else {
            transcriptionModels.fail("Finish or cancel the active transcript before repairing the speech model.")
            return false
        }
        return transcriptionModels.repairPinnedModel()
    }

    func deleteTranscriptionModel() {
        guard !transcriptions.hasActiveJob else {
            transcriptionModels.fail("Finish or cancel the active transcript before deleting the speech model.")
            return
        }

        Task {
            await transcriptions.unloadRuntime()
            transcriptionModels.deleteInstalledModel()
        }
    }

    func transcribeDownloadedEpisode(
        _ episode: EpisodeListItemSnapshot,
        downloadRecord: EpisodeDownloadRecord,
        modelContext: ModelContext
    ) {
        guard let localFileURL = downloads.localFileURL(for: downloadRecord),
              downloads.downloadedFileExists(for: downloadRecord)
        else {
            try? downloads.markDownloadedFileMissing(downloadRecord, modelContext: modelContext)
            return
        }

        let reservation: EpisodeTranscriptionWorkCoordinator.LocalReservation
        switch transcriptions.reserveLocalWork(for: episode.episodeID) {
        case .success(let value):
            reservation = value
        case .failure:
            return
        }

        Task {
            await transcribeDownloadedEpisodeResolvingEngine(
                episode,
                downloadRecord: downloadRecord,
                localFileURL: localFileURL,
                localReservation: reservation,
                modelContext: modelContext
            )
        }
    }

    func requestTranscriptForCurrentEpisode(modelContext: ModelContext) {
        guard let episode = currentPlaybackEpisodeSnapshot else {
            return
        }
        transcriptionRequests.start(
            episode: episode,
            modelContext: modelContext,
            prepareBackgroundSession: { [weak self] in
                self?.armTranscriptGenerationBackgroundSessionIfNeeded(episodeTitle: episode.title)
            }
        )
    }

    /// Apple-preferred Generate runs are foreground-only, including their
    /// Whisper fallback. Otherwise, one system card at a time: an armed
    /// ad-free drain keeps its card and Generate stays lifecycle-managed
    /// instead of competing for a second continued-processing task.
    private func armTranscriptGenerationBackgroundSessionIfNeeded(episodeTitle: String) {
        guard !transcriptionEngineSettings.prefersAppleSpeech,
              !transcriptGenerationBackgroundSession.isArmed,
              !adFreePassBackgroundSession.isArmed
        else {
            return
        }

        transcriptGenerationBackgroundSession.arm(episodeTitle: episodeTitle)
    }

    func dismissTranscriptionRequest(id: UUID) {
        transcriptionRequests.dismiss(id: id)
    }

    func remoteTranscriptionStartPreviewRequestForCurrentEpisode() -> RemoteTranscriptionStartPreviewRequest? {
        guard let episode = currentPlaybackEpisodeSnapshot,
              !transcriptions.hasCompletedTranscript(for: episode.episodeID),
              !remoteTranscription.store.hasActiveRequest
        else {
            return nil
        }

        return RemoteTranscriptionStartPreviewRequest(
            episodeID: episode.episodeID,
            durationSeconds: episode.duration
        )
    }

    @discardableResult
    func confirmRemoteTranscriptionStart(
        _ request: RemoteTranscriptionStartPreviewRequest,
        modelContext: ModelContext
    ) -> RemoteTranscriptionStartConfirmationOutcome {
        remoteTranscription.store.dismissStartPreview(ifMatching: request)
        guard let episode = episodeSnapshot(for: request.episodeID) else {
            return .unavailable(
                message: "This episode is no longer available. Refresh the podcast and try again."
            )
        }

        switch remoteTranscription.start(episode: episode, modelContext: modelContext) {
        case .started:
            return .started(episodeID: episode.episodeID)
        case .rejected(let message):
            return .unavailable(
                message: message
            )
        }
    }

    private func transcribeDownloadedEpisodeResolvingEngine(
        _ episode: EpisodeListItemSnapshot,
        downloadRecord: EpisodeDownloadRecord,
        localFileURL: URL,
        localReservation: EpisodeTranscriptionWorkCoordinator.LocalReservation,
        modelContext: ModelContext
    ) async {
        defer {
            transcriptions.releaseLocalWork(localReservation)
        }
        // Fresh Generate runs follow the global engine preference. An
        // interrupted Whisper checkpoint remains on Whisper so Resume keeps
        // its promise.
        let resolver = EpisodeTranscriptionPlanResolver(
            transcriptionModels: transcriptionModels,
            appleSpeechAssets: appleSpeechAssets,
            prefersRevocationDurableEngine: !transcriptionEngineSettings.prefersAppleSpeech
                || transcriptions.hasResumableWhisperCheckpoint(for: episode.episodeID)
        )
        do {
            let plan = try await resolver.resolve(
                requestedEngine: .productDefault,
                podcastLanguageCode: podcastLanguageCode(forPodcastID: episode.podcastID)
            )
            if plan.runEngine == .appleSpeech {
                requestLocalNotificationAuthorizationIfNeeded()
            }
            transcriptions.startTranscription(
                episode,
                downloadRecord: downloadRecord,
                localFileURL: localFileURL,
                engine: plan.runEngine,
                modelIdentity: plan.modelIdentity,
                languageCode: plan.languageCode,
                runLanguageCode: plan.runLanguageCode,
                localReservation: localReservation,
                modelContext: modelContext
            )
        } catch {
            transcriptions.load(modelContext: modelContext)
            transcriptionModels.fail(error.localizedDescription)
        }
    }

    func podcastLanguageCode(forPodcastID podcastID: String) -> String? {
        library.podcastCache(for: podcastID)?.languageCode
    }

    func improveTranscriptWithAppleSpeech(episodeID: String, modelContext: ModelContext) {
        guard let episode = library.episode(with: episodeID),
              let downloadRecord = downloads.record(for: episodeID),
              downloadRecord.state == .completed,
              let localFileURL = downloads.localFileURL(for: downloadRecord),
              downloads.downloadedFileExists(for: downloadRecord)
        else {
            return
        }

        requestLocalNotificationAuthorizationIfNeeded()
        transcriptImprovement.start(
            episode: episode,
            downloadRecord: downloadRecord,
            localFileURL: localFileURL,
            podcastLanguageCode: podcastLanguageCode(forPodcastID: episode.podcastID),
            modelContext: modelContext
        )
    }

    func cancelEpisodeTranscription(episodeID: String, modelContext: ModelContext) {
        transcriptions.cancelTranscription(episodeID: episodeID, modelContext: modelContext)
    }

    func deleteEpisodeTranscript(episodeID: String, modelContext: ModelContext) {
        adAnalyses.deleteAnalysis(episodeID: episodeID, modelContext: modelContext)
        transcriptAnalyses.deleteAnalysis(episodeID: episodeID, modelContext: modelContext)
        transcriptions.deleteTranscript(episodeID: episodeID, modelContext: modelContext)
    }

    func analyzeEpisodeTranscript(_ document: EpisodeTranscriptDocument, modelContext: ModelContext) {
        adAnalyses.startAnalysis(
            transcript: document,
            transcriptState: transcriptions.record(for: document.episodeID)?.state,
            modelContext: modelContext
        )
    }

    func deleteEpisodeAdAnalysis(episodeID: String, modelContext: ModelContext) {
        adAnalyses.deleteAnalysis(episodeID: episodeID, modelContext: modelContext)
    }

    // MARK: - Chapters & Summary (transcript analysis)

    /// Explicit episode-detail action for an already-transcribed episode —
    /// the only way a new analysis starts; `TranscriptAnalysisQueue` owns
    /// the eligibility checks and the single-flight drain.
    func generateChaptersAndSummary(episodeID: String, modelContext: ModelContext) {
        transcriptAnalysisQueue.generate(episodeID: episodeID, modelContext: modelContext)
    }

    func retryDeferredTranscriptAnalyses(
        modelContext: ModelContext,
        trigger: TranscriptAnalysisQueue.RetryTrigger = .launch
    ) {
        transcriptAnalysisQueue.retryDeferred(modelContext: modelContext, trigger: trigger)
    }

    func resetTranscriptAnalysisForegroundProbe() {
        transcriptAnalysisQueue.resetForegroundProbe()
    }

    var currentAdFreePassPresentation: EpisodeAdFreePassPresentation {
        if let adFreePassPresentationOverride {
            return adFreePassPresentationOverride
        }

        return adFreePass.presentation(
            for: currentPlaybackEpisodeSnapshot,
            downloads: downloads,
            transcriptionModels: transcriptionModels,
            appleSpeechAssets: appleSpeechAssets,
            transcriptions: transcriptions,
            adAnalyses: adAnalyses,
            currentZoneCount: playback.skipZones.count
        )
    }

    func startOrContinueAdFreePassForCurrentEpisode(
        modelContext: ModelContext,
        transcriptionEngine: AdFreePassTranscriptionEngine = .productDefault
    ) {
        guard let episode = currentPlaybackEpisodeSnapshot else {
            return
        }

        startAdFreePass(for: episode, modelContext: modelContext, transcriptionEngine: transcriptionEngine)
    }

    /// Sound Lab entry: a visible cloud-unavailable outcome runs the one-tap
    /// on-device fallback directly; otherwise the prompt policy decides.
    /// Returns the episode when the caller must present the mode dialog.
    func startOrContinueAdFreePassForCurrentEpisodeResolvingMode(
        modelContext: ModelContext
    ) -> EpisodeListItemSnapshot? {
        guard let episode = currentPlaybackEpisodeSnapshot else {
            return nil
        }
        if case .cloudUnavailable = adFreePass.queueStatus(for: episode.episodeID) {
            startAdFreePass(for: episode, modelContext: modelContext, mode: .onDevice)
            return nil
        }
        return startAdFreePassResolvingMode(for: episode, modelContext: modelContext)
            ? episode
            : nil
    }

    func startAdFreePass(
        for episode: EpisodeListItemSnapshot,
        modelContext: ModelContext,
        transcriptionEngine: AdFreePassTranscriptionEngine = .productDefault,
        mode: AdDetectionMode = .onDevice
    ) {
        adFreePass.enqueue(
            episode: episode,
            origin: .manual,
            context: adFreePassEnqueueContext,
            modelContext: modelContext,
            transcriptionEngine: transcriptionEngine,
            podcastLanguageCode: podcastLanguageCode(forPodcastID: episode.podcastID),
            mode: mode,
            prepareBackgroundSession: { [weak self] in
                // Cloud items never arm the continued-processing card: the
                // server keeps working while the app is suspended.
                guard mode == .onDevice else {
                    return
                }
                self?.armAdFreePassBackgroundSessionIfNeeded(episodeTitle: episode.title)
            },
            refreshSkipZones: { [weak self] in
                await self?.skipZones.zoneCountAfterPass(for: episode) ?? 0
            }
        )
    }

    /// Decision table for a manual Detect Ads tap: a current completed
    /// transcript always runs the free on-device analysis, a stored mode
    /// runs directly, and only an unset mode with the remote surface visible
    /// prompts.
    func detectAdsTapDecision(for episode: EpisodeListItemSnapshot) -> AdDetectionModePromptPolicy.Decision {
        return AdDetectionModePromptPolicy(
            storedMode: adDetectionSettings.mode,
            hasCurrentCompletedTranscript: transcriptions.hasCompletedDocument(for: episode.episodeID),
            isRemoteSurfaceVisible: remoteTranscriptionPurchases.isSurfaceVisible
        ).decision
    }

    /// First-tap dialog choice: remember the mode device-locally, then run
    /// the pass it selected. A failed preference save never blocks the pass
    /// — the mode travels explicitly below, the Settings section renders the
    /// store's error, and the next tap simply prompts again.
    func chooseAdDetectionMode(
        _ mode: AdDetectionMode,
        for episode: EpisodeListItemSnapshot,
        modelContext: ModelContext
    ) {
        _ = adDetectionSettings.setMode(mode, modelContext: modelContext)
        startAdFreePass(for: episode, modelContext: modelContext, mode: mode)
    }

    /// Runs the Detect Ads tap through the prompt policy; returns true when
    /// the caller must present the mode dialog instead.
    func startAdFreePassResolvingMode(
        for episode: EpisodeListItemSnapshot,
        modelContext: ModelContext
    ) -> Bool {
        switch detectAdsTapDecision(for: episode) {
        case .runOnDevice:
            startAdFreePass(for: episode, modelContext: modelContext, mode: .onDevice)
            return false
        case .runCloud:
            startAdFreePass(for: episode, modelContext: modelContext, mode: .cloud)
            return false
        case .prompt:
            return true
        }
    }

    func cancelAdFreePass(for episode: EpisodeListItemSnapshot, modelContext: ModelContext) {
        guard adFreePass.activeEpisodeID == episode.episodeID else {
            adFreePass.removePendingItem(episodeID: episode.episodeID, modelContext: modelContext)
            return
        }

        adFreePass.cancelActivePass()
        if downloads.record(for: episode.episodeID)?.state == .downloading {
            downloads.cancelDownload(episodeID: episode.episodeID, modelContext: modelContext)
        }
    }

    func armBackgroundContinuationForActiveQueue() {
        guard adFreePass.queueState == .running,
              !adFreePassBackgroundSession.isArmed,
              let activeItem = adFreePass.activeItem,
              // Cloud items never arm: the server keeps working while the
              // app is suspended and polling resumes on foreground.
              activeItem.mode == .onDevice
        else {
            return
        }

        armAdFreePassBackgroundSessionIfNeeded(episodeTitle: activeItem.episode.title)
        adFreePass.republishCurrentStage()
    }

    func restoreAdFreePassQueue(modelContext: ModelContext) {
        adFreePass.restorePersistedQueue(
            resolveEpisode: { [library] episodeID in
                library.episode(with: episodeID)
            },
            context: adFreePassEnqueueContext,
            modelContext: modelContext,
            podcastLanguageCode: { [weak self] podcastID in
                self?.podcastLanguageCode(forPodcastID: podcastID)
            },
            refreshSkipZones: { [weak self] episode in
                await self?.skipZones.zoneCountAfterPass(for: episode) ?? 0
            }
        )
    }

    func resumeEnvironmentalAdFreePassIfNeeded(modelContext: ModelContext) {
        adFreePass.handleForegroundReturn()
        adFreePass.probeCapDeferredQueueIfAllowed(trigger: .sceneActivated)

        if adFreePass.isQueuePausedForEnvironmentalInterrupt {
            adFreePass.resumeQueueForEnvironmentalAutoResume()
            return
        }

        guard adFreePass.activeEpisodeID == nil,
              adFreePass.queueState == .idle,
              adFreePass.queueItems.isEmpty,
              let episode = currentPlaybackEpisodeSnapshot,
              transcriptions.hasEnvironmentalInterruptionPending(for: episode.episodeID)
        else {
            return
        }

        startOrContinueAdFreePassForCurrentEpisode(modelContext: modelContext)
    }

    func detectAdsMenuState(for episode: EpisodeListItemSnapshot) -> EpisodeDetectAdsMenuState {
        EpisodeDetectAdsMenuState(
            queueStatus: adFreePass.queueStatus(for: episode.episodeID),
            hasCurrentCompletedAnalysis: adFreePass.hasCurrentCompletedAnalysis(
                for: episode.episodeID,
                transcriptions: transcriptions,
                adAnalyses: adAnalyses
            )
        )
    }

    func downloadMenuState(for episode: EpisodeListItemSnapshot) -> EpisodeDownloadMenuState {
        guard let record = downloads.record(for: episode.episodeID) else {
            return .available
        }

        switch record.state {
        case .downloading:
            return .downloading
        case .completed:
            return downloads.downloadedFileExists(for: record) ? .downloaded : .available
        case .paused, .failed, .missing:
            return .available
        }
    }

    private func armAdFreePassBackgroundSessionIfNeeded(episodeTitle: String) {
        guard !adFreePassBackgroundSession.isArmed else {
            return
        }

        adFreePassBackgroundSession.arm(
            episodeTitle: episodeTitle,
            cancellationSource: adFreePass.cancellationSource
        )
        requestLocalNotificationAuthorizationIfNeeded()
    }

    private func requestLocalNotificationAuthorizationIfNeeded() {
        Task { [adFreePassNotificationCenter] in
            guard await adFreePassNotificationCenter.authorizationStatus() == .notDetermined else {
                return
            }
            await adFreePassNotificationCenter.requestProvisionalAuthorization()
        }
    }

    private func scheduleAdFreePassCompletionNotificationIfNeeded(terminal: AdFreePassQueueTerminalOutcome) {
        let scheduler = AdFreePassCompletionNotificationScheduler(center: adFreePassNotificationCenter)
        let outcomes = adFreePass.drainOutcomes
        let isSceneActive = isSceneActive
        Task {
            await scheduler.scheduleIfNeeded(
                terminal: terminal,
                outcomes: outcomes,
                isSceneActive: isSceneActive
            )
        }
    }

    private func scheduleTranscriptionInterruptedNotificationIfNeeded(
        episodeID: String,
        restoredPriorTranscript: Bool
    ) {
        guard adFreePass.queueStatus(for: episodeID) != .running else {
            return
        }

        let content = TranscriptionInterruptedNotificationContent(
            episodeTitle: library.episode(with: episodeID)?.title,
            restoredPriorTranscript: restoredPriorTranscript
        )
        let scheduler = TranscriptionInterruptedNotificationScheduler(
            center: adFreePassNotificationCenter
        )
        let isSceneActive = isSceneActive
        Task {
            await scheduler.scheduleIfNeeded(
                content: content,
                isSceneActive: isSceneActive
            )
        }
    }

    func refreshPlaybackSkipZonesForCurrentEpisode() {
        skipZones.refreshForCurrentEpisode()
    }

    /// Awaits the in-flight skip-zone refresh, if any. Test hook.
    func waitForSkipZoneRefresh() async {
        await skipZones.waitForRefresh()
    }

    func undoLastAutoSkip() {
        skipZones.undoLastAutoSkip()
    }

    func interruptActiveTranscriptionForLifecycleExit(modelContext: ModelContext) {
        transcriptionRequests.prepareForLifecycleExit(modelContext: modelContext)
    }

    func configureBackgroundSessionExpirations(modelContext: ModelContext) {
        adFreePassBackgroundSession.onExpiration = { [weak self] in
            self?.interruptActiveTranscriptionForLifecycleExit(modelContext: modelContext)
        }
        transcriptGenerationBackgroundSession.onExpiration = { [weak self] in
            self?.interruptActiveTranscriptionForLifecycleExit(modelContext: modelContext)
        }
    }

    func deleteDownload(_ record: EpisodeDownloadRecord, modelContext: ModelContext) {
        downloadCleanup.deleteDownload(record, modelContext: modelContext)
    }

    func deleteDownloads(_ records: [EpisodeDownloadRecord], modelContext: ModelContext) {
        downloadCleanup.deleteDownloads(records, modelContext: modelContext)
    }

    func deleteAllDownloads(modelContext: ModelContext) {
        downloadCleanup.deleteAllDownloads(modelContext: modelContext)
    }

    func deleteCompletedDownloads(forPodcastID podcastID: String, modelContext: ModelContext) throws {
        try downloadCleanup.deleteCompletedDownloads(forPodcastID: podcastID, modelContext: modelContext)
    }

    func deleteDownloads(forPodcastID podcastID: String, modelContext: ModelContext) {
        do {
            try downloadCleanup.deleteDownloads(forPodcastID: podcastID, modelContext: modelContext)
        } catch {
            lastPlaybackError = "Unable to delete this podcast's downloads: \(error.localizedDescription)"
        }
    }

    func sweepPlayedDownloadsIfEnabled(modelContext: ModelContext) {
        downloadCleanup.sweepPlayedDownloadsIfEnabled(modelContext: modelContext)
    }

    func deletePlayedDownloads(modelContext: ModelContext) {
        downloadCleanup.deletePlayedDownloads(modelContext: modelContext)
    }

    func resolvedPlaybackEpisode(
        for snapshot: EpisodeListItemSnapshot,
        source: EpisodePlaybackSource = .stream,
        modelContext: ModelContext
    ) throws -> Episode {
        var episode = library.domainEpisode(for: snapshot)

        switch source {
        case .stream:
            guard episode.audioURL != nil else {
                throw OpenCastCoreError.missingAudioURL
            }
        case .downloaded(let downloadRecord):
            guard downloadRecord.episodeID == snapshot.episodeID,
                  downloadRecord.podcastID == snapshot.podcastID
            else {
                throw EpisodeDownloadError.invalidDownloadedRecord
            }
            guard downloadRecord.state == .completed else {
                throw EpisodeDownloadError.downloadNotComplete
            }
            guard let localFileURL = downloads.localFileURL(for: downloadRecord),
                  downloads.downloadedFileExists(for: downloadRecord)
            else {
                try downloads.markDownloadedFileMissing(downloadRecord, modelContext: modelContext)
                throw EpisodeDownloadError.missingDownloadedFile
            }
            episode.audioURL = localFileURL
        }

        return episode
    }

    @discardableResult
    func flushPlaybackProgress(
        modelContext: ModelContext,
        refreshObservableProgress: Bool = true
    ) -> Bool {
        playbackProgressFlushObserver?()
        guard let episode = playback.currentEpisode else {
            return false
        }
        // A restored-but-never-touched episode sits at the smart-resume
        // rewound position (3–20s behind the stored one). Persisting that
        // would walk the synced resume point backward on every browse-only
        // open/close cycle and generate a CloudKit export per app open.
        if let restored = restoredUnplayedPlayback, restored.episodeID == episode.id.rawValue {
            if playback.state != .playing, abs(playback.position - restored.position) < 1.0 {
                return false
            }
            // Playback or a seek engaged the restored episode; every later
            // flush persists normally.
            restoredUnplayedPlayback = nil
        }

        let duration = sanitizedDuration(playback.duration ?? episode.duration)
        let position = sanitizedPosition(playback.position, duration: duration)
        let didSave = library.updateProgress(
            episodeID: episode.id.rawValue,
            podcastID: episode.podcastID.rawValue,
            position: position,
            duration: duration,
            modelContext: modelContext,
            refreshObservableProgress: refreshObservableProgress
        )
        if LibraryStore.isPlayed(position: position, duration: duration) {
            playbackRestorePreference.clear(modelContext: modelContext)
        } else {
            playbackRestorePreference.remember(episode.id.rawValue, modelContext: modelContext)
        }
        return didSave
    }

    func restorePreviousPlaybackIfAvailable(modelContext: ModelContext) {
        guard playback.currentEpisode == nil else {
            return
        }

        guard let record = restorableEpisode(modelContext: modelContext) else {
            playbackRestorePreference.clear(modelContext: modelContext)
            return
        }

        do {
            let episode = try resolvedPlaybackEpisode(
                for: record,
                source: preferredPlaybackSource(for: record.episodeID),
                modelContext: modelContext
            )
            applyVoiceBoostSetting(for: episode, modelContext: modelContext)
            let boundaries = playbackEpisodeBoundaries(forPodcastID: record.podcastID)
            let startPosition = boundaries.ordinaryStartPosition(
                library.resumePosition(for: record.episodeID),
                duration: episode.duration
            )
            try playback.load(
                episode,
                startPosition: startPosition,
                boundaries: boundaries
            )
            restoredUnplayedPlayback = (episodeID: record.episodeID, position: startPosition)
            refreshPlaybackSkipZonesForCurrentEpisode()
            playbackRestorePreference.remember(record.episodeID, modelContext: modelContext)
        } catch {
            playbackRestorePreference.clear(modelContext: modelContext)
        }
    }

    func requestNowPlayingPresentation() {
        nowPlayingPresentationRequest += 1
    }

    @discardableResult
    func dismissCurrentPlayback(modelContext: ModelContext) -> Bool {
        let hadCurrentEpisode = playback.currentEpisode != nil
        flushPlaybackProgress(modelContext: modelContext)
        dismissNowPlayingAndDiscardFinishedPlayback()
        unloadPlaybackDeferringBookkeeping(modelContext: modelContext)
        return hadCurrentEpisode
    }

    func requestNowPlayingPresentationAfterPrewarm(for episodeID: EpisodeID) {
        Task { [weak self] in
            // Yield so SwiftUI can mount the hidden Now Playing overlay before presenting it.
            await Task.yield()
            guard self?.playback.currentEpisode?.id == episodeID else {
                return
            }

            self?.requestNowPlayingPresentation()
        }
    }

    func requestOnboardingPresentation() {
        onboardingPresentationRequest += 1
    }

    @discardableResult
    func presentImportedSubscriptionsNotification(feedCount: Int) -> ImportedSubscriptionsNotification? {
        guard feedCount > 0 else {
            return nil
        }

        importedSubscriptionsNotificationID += 1
        let notification = ImportedSubscriptionsNotification(
            id: importedSubscriptionsNotificationID,
            feedCount: feedCount
        )
        importedSubscriptionsNotification = notification
        return notification
    }

    func dismissImportedSubscriptionsNotification(id: Int) {
        guard importedSubscriptionsNotification?.id == id else {
            return
        }

        importedSubscriptionsNotification = nil
    }

    func refreshLibraryIfStale(modelContext: ModelContext) async {
        guard allowsAutomaticFeedRefresh else {
            return
        }

        await library.refreshAllIfStale(modelContext: modelContext)
    }

    func nukeAllData(modelContext: ModelContext) async throws {
        try await dataNuke.run(modelContext: modelContext)
    }

    func clearDataNukeError() {
        dataNuke.clearError()
    }

    /// Pre-nuke teardown the runner cannot own: request and install resets,
    /// library invalidation, and the analysis-queue cancel — which must
    /// precede the store nuke, because that nuke's cancel wakes a drain
    /// suspended on the store's change stream that would otherwise start a
    /// fresh network analysis mid-nuke.
    private func prepareRuntimeForDataNuke() async {
        transcriptionRequests.resetForDataNuke()
        await notificationSettings.deleteInstallIfRegistered()
        library.prepareForDataNuke()
        await transcriptAnalysisQueue.cancelPending()
    }

    @discardableResult
    func markEpisodePlayed(
        _ episode: EpisodeListItemSnapshot,
        modelContext: ModelContext
    ) -> Bool {
        let didSave = library.markEpisodePlayed(episode, modelContext: modelContext)
        _ = upNextQueue.remove(episodeID: episode.episodeID, modelContext: modelContext)
        if isCurrentEpisode(episode) {
            // Mark Played is a playback command too, so unload even when persistence was already complete.
            dismissNowPlayingAndDiscardFinishedPlayback()
            playback.unload()
            playbackRestorePreference.clear(modelContext: modelContext)
        }
        sweepPlayedDownloadsIfEnabled(modelContext: modelContext)
        return didSave
    }

    @discardableResult
    func clearEpisodeProgress(
        _ episode: EpisodeListItemSnapshot,
        modelContext: ModelContext
    ) -> Bool {
        let didClear = library.clearProgress(for: episode, modelContext: modelContext)
        guard didClear else {
            return false
        }

        if isCurrentEpisode(episode) {
            playback.seek(to: 0)
            playbackRestorePreference.clear(modelContext: modelContext)
        }
        return true
    }

    @discardableResult
    func toggleEpisodePlayed(
        _ episode: EpisodeListItemSnapshot,
        modelContext: ModelContext
    ) -> Bool {
        if library.progressRecord(for: episode.episodeID)?.isPlayed == true {
            clearEpisodeProgress(episode, modelContext: modelContext)
        } else {
            markEpisodePlayed(episode, modelContext: modelContext)
        }
    }

    @discardableResult
    func markAllEpisodesPlayed(
        forPodcastID podcastID: String,
        modelContext: ModelContext
    ) -> Bool {
        let didSave = library.markAllPlayed(forPodcastID: podcastID, modelContext: modelContext)
        _ = upNextQueue.removeAll(forPodcastID: podcastID, modelContext: modelContext)
        if playback.currentEpisode?.podcastID.rawValue == podcastID {
            dismissNowPlayingAndDiscardFinishedPlayback()
            playback.unload()
            playbackRestorePreference.clear(modelContext: modelContext)
        }
        sweepPlayedDownloadsIfEnabled(modelContext: modelContext)
        return didSave
    }

    func refreshCurrentVoiceBoostSetting(modelContext: ModelContext) {
        playbackSettings.load(
            episodeID: playback.currentEpisode?.id.rawValue,
            podcastID: playback.currentEpisode?.podcastID.rawValue,
            modelContext: modelContext,
            playback: playback
        )
    }

    @discardableResult
    func setAppearanceMode(
        _ mode: AppAppearanceMode,
        modelContext: ModelContext
    ) -> Bool {
        appearanceSettings.setMode(mode, modelContext: modelContext)
    }

    @discardableResult
    func setPlaybackRate(
        _ rate: Float,
        modelContext: ModelContext
    ) -> Bool {
        playbackSettings.setPlaybackRate(
            rate,
            modelContext: modelContext,
            playback: playback
        )
    }

    @discardableResult
    func cyclePlaybackRate(modelContext: ModelContext) -> Bool {
        setPlaybackRate(
            PlaybackRateSteps.next(after: playback.rate),
            modelContext: modelContext
        )
    }

    @discardableResult
    func setVoiceBoostMode(
        _ mode: VoiceBoostMode,
        modelContext: ModelContext
    ) -> Bool {
        playbackSettings.setVoiceBoostMode(
            mode,
            episodeID: playback.currentEpisode?.id.rawValue,
            podcastID: playback.currentEpisode?.podcastID.rawValue,
            modelContext: modelContext,
            playback: playback
        )
    }

    @discardableResult
    func setVoiceBoostEnabled(
        _ isEnabled: Bool,
        forEpisodeID episodeID: String,
        podcastID: String?,
        modelContext: ModelContext
    ) -> Bool {
        playbackSettings.setVoiceBoostEnabled(
            isEnabled,
            forEpisodeID: episodeID,
            podcastID: podcastID,
            modelContext: modelContext,
            playback: playback
        )
    }

    @discardableResult
    func setSkipBackwardOption(
        _ option: PlaybackSkipIntervalOption,
        modelContext: ModelContext
    ) -> Bool {
        playbackSettings.setSkipBackwardOption(
            option,
            modelContext: modelContext,
            playback: playback
        )
    }

    @discardableResult
    func setSkipForwardOption(
        _ option: PlaybackSkipIntervalOption,
        modelContext: ModelContext
    ) -> Bool {
        playbackSettings.setSkipForwardOption(
            option,
            modelContext: modelContext,
            playback: playback
        )
    }

    @discardableResult
    func setAutoSkipPromosAndAdsEnabled(
        _ isEnabled: Bool,
        modelContext: ModelContext
    ) -> Bool {
        playbackSettings.setAutoSkipPromosAndAdsEnabled(
            isEnabled,
            modelContext: modelContext,
            playback: playback
        )
    }

    func runVoiceBoostDeviceProbeIfNeeded(modelContext: ModelContext) async {
        #if DEBUG
        guard runsVoiceBoostDeviceProbe, !hasRunVoiceBoostDeviceProbe else {
            return
        }

        hasRunVoiceBoostDeviceProbe = true
        await runVoiceBoostDeviceProbe(trigger: "launch", modelContext: modelContext)
        #endif
    }

    #if DEBUG
    func runVoiceBoostDeviceProbe(trigger: String, modelContext: ModelContext) async {
        let report = await VoiceBoostDeviceProbe().run(
            trigger: trigger,
            appModel: self,
            modelContext: modelContext
        )
        updateVoiceBoostDeviceProbeSummary(from: report)
    }

    func writeVoiceBoostDeviceProbeWaitingForActiveReportIfNeeded() {
        guard runsVoiceBoostDeviceProbe, !hasRunVoiceBoostDeviceProbe else {
            return
        }

        do {
            let report = try VoiceBoostDeviceProbe().writeWaitingForActiveReport(appModel: self)
            updateVoiceBoostDeviceProbeSummary(from: report)
        } catch {
            lastPlaybackError = "Unable to write Voice Boost device probe report: \(error.localizedDescription)"
            refreshVoiceBoostDeviceProbeReportStatus()
        }
    }

    private func updateVoiceBoostDeviceProbeSummary(from report: VoiceBoostDeviceProbeReport) {
        lastVoiceBoostDeviceProbeResult = "\(report.trigger): \(report.result)"
        lastVoiceBoostDeviceProbeApplicationState = "\(report.startedApplicationState) to \(report.finishedApplicationState)"
        refreshVoiceBoostDeviceProbeReportStatus()
    }

    private func refreshVoiceBoostDeviceProbeReportStatus() {
        lastVoiceBoostDeviceProbeReportStatus = FileManager.default.fileExists(atPath: VoiceBoostDeviceProbe.reportURL.path)
            ? "Report Written"
            : "Report Missing"
    }
    #endif

    private func resetRuntimeStateAfterDataNuke(modelContext: ModelContext) async {
        // The unload must precede this method's first suspension: the row
        // wipe has just run, and the unload's boundary flush sees no episode
        // only because the playback snapshot is cleared first. Anything that
        // suspends before it lets a periodic flush re-insert a progress row
        // the wipe deleted (DataNukeRunner.run names the same invariant).
        dismissNowPlayingAndDiscardFinishedPlayback()
        playback.unload()
        lastPlaybackError = nil
        lastUpNextError = nil
        lastUnsubscribeErrorMessage = nil
        playbackRestorePreference.resetAfterDataNuke()
        library.resetAfterDataNuke()
        await downloads.load(modelContext: modelContext)
        transcriptions.load(modelContext: modelContext)
        adAnalyses.load(modelContext: modelContext)
        transcriptAnalysisQueue.resetAfterDataNuke()
        transcriptAnalyses.load(modelContext: modelContext)
        adFreePass.reset()
        upNextQueue.resetAfterDataNuke()
        adFreePassBackgroundSession.reset()
        transcriptGenerationBackgroundSession.reset()
        transcriptImprovement.resetForDataNuke()
        transcriptionModels.resetAfterDataNuke()
        transcriptionEngineSettings.load(modelContext: modelContext)
        appearanceSettings.load(modelContext: modelContext)
        podcastEpisodeListSettings.load(modelContext: modelContext)
        recentSearches.load(modelContext: modelContext)
        playbackSettings.load(modelContext: modelContext, playback: playback)
        notificationSettings.resetAfterDataNuke()
        onboardingState.load(modelContext: modelContext)
        #if DEBUG
        try? FileManager.default.removeItem(at: VoiceBoostDeviceProbe.reportURL)
        lastVoiceBoostDeviceProbeResult = nil
        lastVoiceBoostDeviceProbeApplicationState = nil
        refreshVoiceBoostDeviceProbeReportStatus()
        #endif
    }

    private func startSiriMediaUserContextObservation() {
        let library = library
        let discovery = siriMediaDiscovery
        siriMediaUserContextObservationTask = Task {
            var lastPublishedPodcastIDs: Set<String>?
            for await activePodcastIDs in Observations({ library.activePodcastIDs }) {
                guard !Task.isCancelled else {
                    return
                }
                guard activePodcastIDs != lastPublishedPodcastIDs else {
                    continue
                }

                lastPublishedPodcastIDs = activePodcastIDs
                discovery.publishUserContext(subscriptionCount: activePodcastIDs.count)
            }
        }
    }

    private func play(
        _ snapshot: EpisodeListItemSnapshot,
        source: EpisodePlaybackSource,
        startPosition: TimeInterval? = nil,
        presentsNowPlaying: Bool = true,
        autoplay: Bool = true,
        modelContext: ModelContext
    ) throws {
        let episode = try resolvedPlaybackEpisode(for: snapshot, source: source, modelContext: modelContext)
        flushPlaybackProgress(modelContext: modelContext)
        nowPlayingProbeMark("play-validated")
        applyVoiceBoostSetting(for: episode, modelContext: modelContext)
        let boundaries = playbackEpisodeBoundaries(forPodcastID: snapshot.podcastID)
        let requestedStartPosition = startPosition ?? library.resumePosition(for: snapshot.episodeID)
        let resolvedStartPosition = startPosition != nil
            ? requestedStartPosition
            : boundaries.ordinaryStartPosition(requestedStartPosition, duration: episode.duration)
        try playback.load(
            episode,
            startPosition: resolvedStartPosition,
            boundaries: boundaries
        )
        finishedPlaybackPresentation = nil
        _ = upNextQueue.remove(episodeID: snapshot.episodeID, modelContext: modelContext)
        downloadCleanup.deferPlayedSweep(modelContext: modelContext)
        refreshPlaybackSkipZonesForCurrentEpisode()
        nowPlayingProbeMark("play-loaded")
        playbackRestorePreference.remember(snapshot.episodeID, modelContext: modelContext)
        if autoplay {
            playback.play()
            nowPlayingProbeMark("play-started")
            siriMediaDiscovery.donatePlaybackIfNeeded(for: snapshot)
        }
        if presentsNowPlaying {
            requestNowPlayingPresentationAfterPrewarm(for: episode.id)
        }
        autoDetectAdsOnPlayIfQualified(snapshot, modelContext: modelContext)
    }

    private func autoDetectAdsOnPlayIfQualified(
        _ episode: EpisodeListItemSnapshot,
        modelContext: ModelContext
    ) {
        guard library.isAdAutoDetectEnabled(forPodcastID: episode.podcastID),
              adFreePass.queueStatus(for: episode.episodeID) == .notQueued
        else {
            return
        }

        Task { [weak self] in
            await self?.enqueueAutoDetectAdsOnPlayIfQualified(
                episode,
                modelContext: modelContext
            )
        }
    }

    private func enqueueAutoDetectAdsOnPlayIfQualified(
        _ episode: EpisodeListItemSnapshot,
        modelContext: ModelContext
    ) async {
        let hasCurrentCompletedAnalysis = await adFreePass.currentCompletedAnalysisVerdict(
            for: episode.episodeID,
            transcriptions: transcriptions,
            adAnalyses: adAnalyses
        )
        let policy = AdAutoDetectPlayPolicy(
            isAutoDetectEnabled: library.isAdAutoDetectEnabled(forPodcastID: episode.podcastID),
            hasCurrentCompletedAnalysis: hasCurrentCompletedAnalysis,
            queueStatus: adFreePass.queueStatus(for: episode.episodeID)
        )
        guard policy.shouldEnqueue else {
            return
        }

        // Auto passes never arm the background session;
        // continuation requires an explicit tap. They follow the stored
        // detection mode: cloud mode enqueues a cloud job on
        // play with no per-episode confirmation; the authoritative credits
        // check lives inside the cloud pass itself.
        adFreePass.enqueue(
            episode: episode,
            origin: .auto,
            context: adFreePassEnqueueContext,
            modelContext: modelContext,
            podcastLanguageCode: podcastLanguageCode(forPodcastID: episode.podcastID),
            mode: adDetectionSettings.mode ?? .onDevice,
            refreshSkipZones: { [weak self] in
                await self?.skipZones.zoneCountAfterPass(for: episode) ?? 0
            }
        )
    }

    private func applyVoiceBoostSetting(for episode: Episode, modelContext: ModelContext) {
        playbackSettings.load(
            episodeID: episode.id.rawValue,
            podcastID: episode.podcastID.rawValue,
            modelContext: modelContext,
            playback: playback
        )
    }

    func playbackEpisodeBoundaries(forPodcastID podcastID: String) -> PlaybackEpisodeBoundaries {
        let settings = library.podcastPlaybackSkipSettings(forPodcastID: podcastID)
        return PlaybackEpisodeBoundaries(
            skipIntroSeconds: settings.skipIntroSeconds,
            skipOutroSeconds: settings.skipOutroSeconds
        )
    }

    private var currentPlaybackEpisodeSnapshot: EpisodeListItemSnapshot? {
        guard let episode = playback.currentEpisode else {
            return nil
        }

        if let snapshot = library.episode(with: episode.id.rawValue) {
            return snapshot
        }

        return EpisodeListItemSnapshot(episode: episode)
    }

    private func isCurrentEpisode(_ episode: EpisodeListItemSnapshot) -> Bool {
        playback.currentEpisode?.id.rawValue == episode.episodeID
    }

    private func restorableEpisode(modelContext: ModelContext) -> EpisodeListItemSnapshot? {
        guard let episodeID = playbackRestorePreference.storedEpisodeID(modelContext: modelContext),
              let episode = library.episode(with: episodeID),
              library.canRestorePlayback(for: episode)
        else {
            return nil
        }

        return episode
    }

    /// Apple stays the ranking authority; the Podcast Index Worker is a
    /// supplement, so a disabled directory backend degrades to the
    /// Apple-only service.
    private static func defaultPodcastDirectoryService(
        httpClient: any OpenCastHTTPClient
    ) -> any PodcastDirectoryService {
        let apple = ITunesPodcastDirectoryService(httpClient: httpClient)
        let configuration = PodcastDirectoryBackendConfiguration.current
        guard configuration.isEnabled else {
            return apple
        }
        return CompositePodcastDirectoryService(
            apple: apple,
            podcastIndex: PodcastIndexWorkerDirectoryService(
                baseURL: configuration.workerBaseURL,
                httpClient: httpClient
            )
        )
    }
}
