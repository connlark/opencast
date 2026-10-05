import Foundation
import Observation
import OpenCastCore
import OpenCastPlayback
import OpenCastTranscription
import SwiftData
import UserNotifications

@Observable
final class OpenCastAppModel {
    @ObservationIgnored lazy var systemActions = OpenCastSystemActionRouter(appModel: self)
    var systemSearchRequest: OpenCastSearchRequest?
    /// The periodic synced flush only guards against a hard crash mid-listen
    /// (losing up to this much position is accepted); every deliberate exit -
    /// pause, seek, skip, background, completion, dismiss, episode switch -
    /// flushes through a boundary immediately. Writing the CloudKit-synced
    /// progress record every 5 seconds kept the export machinery churning for
    /// entire listening sessions.
    static let playbackProgressPersistenceInterval = Duration.seconds(60)

    let cacheController: OpenCastCacheController
    let httpClient: any OpenCastHTTPClient
    let helpContent: HelpContentStore
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
    @ObservationIgnored private let remoteJobReattacher: RemoteJobReattacher
    @ObservationIgnored private let adFreePassEnqueueContext: AdFreePassEnqueueContext
    let remoteTranscriptionPurchases: RemoteTranscriptionPurchaseStore
    let adAnalyses: EpisodeAdAnalysisStore
    let transcriptAnalyses: EpisodeTranscriptAnalysisStore
    let transcriptIntelligence: TranscriptIntelligenceStore
    let adFreePass: EpisodeAdFreePassCoordinator
    let upNextQueue: UpNextQueueStore
    let playlists: PlaylistStore
    let playlistDisplaySettings: PlaylistDisplaySettingsStore
    let adFreePassBackgroundSession: EpisodeAdFreePassBackgroundSession
    let transcriptGenerationBackgroundSession: EpisodeTranscriptGenerationBackgroundSession
    let remoteTranscriptionBackgroundSession: EpisodeRemoteTranscriptionBackgroundSession
    let transcriptImprovement: EpisodeTranscriptImprovementCoordinator
    let playback: AVFoundationPlaybackController
    let appearanceSettings: AppearanceSettingsStore
    let appIcon: AppIconStore
    let podcastEpisodeListSettings: PodcastEpisodeListSettingsStore
    let libraryDisplaySettings: LibraryDisplaySettingsStore
    let inboxEpisodeListSettings: InboxEpisodeListSettingsStore
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
    private(set) var addToPlaylistPresentationRequest: AddToPlaylistPresentationRequest?
    /// Single source of truth for Now Playing presentation; the root layer
    /// and tab views read this directly.
    var isNowPlayingPresented = false
    var hasNowPlayingPresentationContent: Bool {
        playback.currentEpisode != nil || finishedPlaybackPresentation != nil
    }
    /// The queue head the tab accessory offers while nothing is loaded. Nil
    /// until the launch restore has run and while the Finished card is
    /// retained; skips unresolvable items so a stale head never renders a
    /// blank accessory.
    var upNextAccessoryEpisode: EpisodeListItemSnapshot? {
        guard hasRestoredPlaybackSurface, !hasNowPlayingPresentationContent else {
            return nil
        }

        for item in upNextQueue.items {
            if let episode = episodeSnapshot(for: item.episodeID) {
                return episode
            }
        }
        return nil
    }
    var showsUpNextAccessory: Bool {
        upNextAccessoryEpisode != nil
    }
    var onboardingPresentationRequest = 0
    /// The nuke sheet stays hoisted at the root so `resetAfterDataNuke()` can
    /// swap it for onboarding in one transaction; Delete Data requests it here.
    var dataNukeConfirmationPresentationRequest = 0
    var lastPlaybackError: String?
    var lastUpNextError: String?
    var lastPlaylistError: String?
    /// The playlist the loaded episode was started from, or derived from the
    /// queue row it was popped from; nil for any untagged start.
    private(set) var currentPlaylistSourceID: String?
    /// Joined with the live playlist summary: a rename shows at once, and a
    /// deleted playlist hides the source without touching the queue.
    var currentPlaylistSource: PlaylistPlaybackSource? {
        guard let currentPlaylistSourceID,
              let summary = playlists.playlists.first(where: { $0.playlistID == currentPlaylistSourceID })
        else {
            return nil
        }
        return PlaylistPlaybackSource(playlistID: summary.playlistID, name: summary.name)
    }
    /// The library, downloads, Up Next, and playlist snapshots are all ready
    /// for list views to derive cross-store state without observing partial
    /// startup data.
    private(set) var coreStoresHydrated = false
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
    /// The latest Transcribe Remotely delivery decision in flight; the
    /// remote card's expiration awaits it before completing the task.
    @ObservationIgnored private var remoteTranscriptionDeliveryTask: Task<Void, Never>?
    /// Flips in the same turn that loads the restorable episode, so the
    /// queue accessory can key off it without ever preceding a restore.
    private(set) var hasRestoredPlaybackSurface = false
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
        helpContent: HelpContentStore? = nil,
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
        remoteTranscriptionPurchases: RemoteTranscriptionPurchaseStore? = nil,
        remoteTranscriptionAPI: (any RemoteTranscriptionAPI)? = nil,
        remoteTranscriptionJobStore: RemoteTranscriptionJobStore = RemoteTranscriptionJobStore(),
        transcriptIntelligence: TranscriptIntelligenceStore = TranscriptIntelligenceStore(),
        adFreePass: EpisodeAdFreePassCoordinator = EpisodeAdFreePassCoordinator(),
        upNextQueue: UpNextQueueStore = UpNextQueueStore(),
        playlists: PlaylistStore = PlaylistStore(),
        playlistDisplaySettings: PlaylistDisplaySettingsStore = PlaylistDisplaySettingsStore(),
        adFreePassBackgroundSession: EpisodeAdFreePassBackgroundSession = EpisodeAdFreePassBackgroundSession(),
        transcriptGenerationBackgroundSession: EpisodeTranscriptGenerationBackgroundSession = EpisodeTranscriptGenerationBackgroundSession(),
        remoteTranscriptionBackgroundSession: EpisodeRemoteTranscriptionBackgroundSession = EpisodeRemoteTranscriptionBackgroundSession(),
        playback: AVFoundationPlaybackController? = nil,
        appearanceSettings: AppearanceSettingsStore = AppearanceSettingsStore(),
        appIcon: AppIconStore = AppIconStore(),
        podcastEpisodeListSettings: PodcastEpisodeListSettingsStore = PodcastEpisodeListSettingsStore(),
        libraryDisplaySettings: LibraryDisplaySettingsStore = LibraryDisplaySettingsStore(),
        inboxEpisodeListSettings: InboxEpisodeListSettingsStore = InboxEpisodeListSettingsStore(),
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
        adFreePassQueueOverride: AdFreePassQueueUITestOverride? = nil,
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
        self.helpContent = helpContent ?? HelpContentStore(
            httpClient: resolvedHTTPClient,
            cacheDirectory: cacheController.rootDirectory.appending(path: "HelpContent", directoryHint: .isDirectory)
        )
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
        let resolvedRemoteTranscriptionAPI: any RemoteTranscriptionAPI
        #if DEBUG
        resolvedRemoteTranscriptionAPI = remoteTranscriptionAPI ?? RemoteTranscriptionAPIClient()
        #else
        resolvedRemoteTranscriptionAPI = remoteTranscriptionAPI ?? RemoteTranscriptionRoutedAPIClient()
        #endif
        self.remoteTranscription = EpisodeRemoteTranscriptionCoordinator(
            api: resolvedRemoteTranscriptionAPI,
            downloads: downloads,
            transcriptions: transcriptions,
            store: remoteTranscriptionJobStore
        )
        // Cloud detect passes share the plain surface's job store (purpose-
        // keyed references, one balance) through their own runner instance.
        self.remoteTranscriptionRunner = RemoteTranscriptionJobRunner(
            api: resolvedRemoteTranscriptionAPI,
            downloads: downloads,
            transcriptions: transcriptions,
            store: remoteTranscription.store
        )
        self.remoteTranscriptionPurchases = remoteTranscriptionPurchases ?? RemoteTranscriptionPurchaseStore(
            api: resolvedRemoteTranscriptionAPI,
            storeKit: LiveRemoteTranscriptionStoreKitClient()
        )
        #if DEBUG
        if let purchaseFixture = RemoteTranscriptionPurchaseUIFixture.requested() {
            switch purchaseFixture {
            case .reviewScreenshot:
                self.remoteTranscriptionPurchases.applyReviewScreenshotFixture()
            case .unavailable:
                self.remoteTranscriptionPurchases.applyUnavailableFixture()
            case .delayedAvailability:
                self.remoteTranscriptionPurchases.applyDelayedAvailabilityFixture()
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
        self.transcriptIntelligence = transcriptIntelligence
        transcriptAnalysisQueue = TranscriptAnalysisQueue(
            transcriptAnalyses: transcriptAnalyses,
            transcriptions: transcriptions,
            library: resolvedLibrary,
            purchases: self.remoteTranscriptionPurchases
        )
        resolvedLibrary.episodeSidecarMigrators = [downloads, transcriptions, adAnalyses, transcriptAnalyses, playlists]
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
            remotePurchases: self.remoteTranscriptionPurchases
        )
        self.adFreePass = adFreePass
        remoteJobReattacher = RemoteJobReattacher(
            plainTranscription: remoteTranscription,
            cloudRunner: remoteTranscriptionRunner,
            transcriptions: transcriptions,
            resolveEpisode: { [resolvedLibrary, downloads] episodeID in
                Self.episodeSnapshot(for: episodeID, library: resolvedLibrary, downloads: downloads)
            },
            cloudQueueEpisodeIDs: { [adFreePass] in
                var episodeIDs = Set(adFreePass.queueItems.map(\.episodeID))
                if let activeEpisodeID = adFreePass.activeEpisodeID {
                    episodeIDs.insert(activeEpisodeID)
                }
                return episodeIDs
            }
        )
        self.upNextQueue = upNextQueue
        self.playlists = playlists
        self.playlistDisplaySettings = playlistDisplaySettings
        self.adFreePassBackgroundSession = adFreePassBackgroundSession
        self.transcriptGenerationBackgroundSession = transcriptGenerationBackgroundSession
        self.remoteTranscriptionBackgroundSession = remoteTranscriptionBackgroundSession
        self.transcriptImprovement = EpisodeTranscriptImprovementCoordinator(
            appleSpeechAssets: appleSpeechAssets,
            transcriptions: transcriptions
        )
        self.playback = playback ?? AVFoundationPlaybackController(
            nowPlayingArtworkLoader: SharedNowPlayingArtworkLoader()
        )
        self.playback.setEventLogHandler { message in
            Task { await PlaybackEventLog.shared.record(message) }
        }
        skipZones = PlaybackSkipZoneCoordinator(
            playback: self.playback,
            downloads: downloads,
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
        self.appIcon = appIcon
        self.podcastEpisodeListSettings = podcastEpisodeListSettings
        self.libraryDisplaySettings = libraryDisplaySettings
        self.inboxEpisodeListSettings = inboxEpisodeListSettings
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
        self.downloads.onEpisodeStateChanged = { [weak self] episodeID in
            self?.skipZones.refreshIfCurrentEpisode(episodeID: episodeID)
        }
        transcriptAnalysisQueue.resolveEpisode = { [weak self] episodeID in
            self?.episodeSnapshot(for: episodeID)
        }
        adFreePass.uiTestQueueOverride = adFreePassQueueOverride
        adFreePass.uiTestEpisodeSnapshotResolver = { [weak self] episodeID in
            self?.episodeSnapshot(for: episodeID)
        }
        dataNuke.prepareRuntime = { [weak self] in
            await self?.prepareRuntimeForDataNuke()
        }
        dataNuke.resetRuntime = { [weak self] modelContext in
            await self?.resetRuntimeStateAfterDataNuke(modelContext: modelContext)
        }
        self.remoteTranscriptionPurchases.onBalanceIncreased = { [weak self] in
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
        self.adFreePass.requiresNonGPUCompute = { [weak self] in
            self?.adFreePassBackgroundSession.requiresNonGPUCompute ?? false
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
        remoteTranscriptionBackgroundSession.jobStore = remoteTranscription.store
        remoteTranscription.onPhaseChange = { [weak self] episodeID, phase in
            self?.remoteTranscriptionBackgroundSession.notePhase(phase, episodeID: episodeID)
        }
        remoteTranscription.onRunEnded = { [weak self] episodeID, phase, deliveryOwner in
            self?.scheduleRemoteTranscriptionNotificationIfNeeded(
                episodeID: episodeID,
                phase: phase,
                deliveryOwner: deliveryOwner
            )
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

        coreStoresHydrated = false
        let task = Task {
            // Before the library publishes, so a stored layout doesn't
            // flash the default container first, and a stored Inbox filter
            // applies to the first render.
            libraryDisplaySettings.load(modelContext: modelContext)
            playlistDisplaySettings.load(modelContext: modelContext)
            inboxEpisodeListSettings.load(modelContext: modelContext)
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
            playlists.sortOrder = playlistDisplaySettings.sortOrder
            playlists.load(modelContext: modelContext)
            if let message = playlists.consumeLastErrorMessage() {
                lastPlaylistError = message
            }
            coreStoresHydrated = true
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

    /// CarPlay can be the first user-visible surface, so it needs the same
    /// stale feed check the phone scene performs after its initial load. Keep
    /// the network step out of playback hydration because Siri, App Intents,
    /// and system actions share that short-lived path.
    func ensureCarPlaySurfaceHydratedAndRefreshed(modelContext: ModelContext) async {
        await ensurePlaybackSurfaceHydrated(modelContext: modelContext)
        guard !Task.isCancelled else {
            return
        }

        await refreshLibraryIfStale(modelContext: modelContext)
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

    /// An explicit start position bypasses smart resume and the skip-intro
    /// floor.
    func playEpisode(
        _ episode: EpisodeListItemSnapshot,
        at startPosition: TimeInterval? = nil,
        presentsNowPlaying: Bool = true,
        sourcePlaylistID: String? = nil,
        modelContext: ModelContext
    ) throws {
        try play(
            episode,
            source: preferredPlaybackSource(for: episode.episodeID),
            startPosition: startPosition,
            presentsNowPlaying: presentsNowPlaying,
            sourcePlaylistID: sourcePlaylistID,
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
                    sourcePlaylistID: item.sourcePlaylistID,
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
            currentPlaylistSourceID = nil
        }
        sweepPlayedDownloadsIfEnabled(modelContext: modelContext)
    }

    func performUpNextQueueMutation(_ mutation: () -> Bool) {
        guard !mutation() else {
            return
        }
        lastUpNextError = upNextQueue.consumeLastErrorMessage()
    }

    /// Generic so `create` and `add` still hand back their summary and count.
    /// A successful mutation clears the store's message, so consuming after
    /// every call is safe.
    @discardableResult
    func performPlaylistMutation<Value>(_ mutation: () -> Value) -> Value {
        let value = mutation()
        if let message = playlists.consumeLastErrorMessage() {
            lastPlaylistError = message
        }
        return value
    }

    /// Deletes through the store, then the playlist's Siri donation group;
    /// a failed delete leaves the donations alone.
    @discardableResult
    func deletePlaylist(_ playlistID: String, modelContext: ModelContext) -> Bool {
        let didDelete = performPlaylistMutation { playlists.delete(playlistID, modelContext: modelContext) }
        if didDelete {
            siriMediaDiscovery.deleteDonations(forPlaylistID: playlistID)
        }
        return didDelete
    }

    /// Renames through the store, then drops the donation group that carries
    /// the old name; the next play from the playlist donates the new one.
    @discardableResult
    func renamePlaylist(_ playlistID: String, to name: String, modelContext: ModelContext) -> Bool {
        let didRename = performPlaylistMutation { playlists.rename(playlistID, to: name, modelContext: modelContext) }
        if didRename {
            siriMediaDiscovery.deleteDonations(forPlaylistID: playlistID)
        }
        return didRename
    }

    /// Persists the collection order first, so the store only re-sorts to an
    /// order that will survive a relaunch.
    @discardableResult
    func setPlaylistSortOrder(_ sortOrder: PlaylistSortOrder, modelContext: ModelContext) -> Bool {
        guard playlistDisplaySettings.setSortOrder(sortOrder, modelContext: modelContext) else {
            lastPlaylistError = playlistDisplaySettings.lastErrorMessage
            playlistDisplaySettings.clearLastError()
            return false
        }
        playlists.sortOrder = sortOrder
        return true
    }

    /// Copies the playlist's unplayed, resolvable episodes into Up Next (a
    /// smart playlist's first `smartPlaylistQueueLimit`); the playlist
    /// itself is never consumed. `replace` starts the first episode before
    /// touching the queue, so a failed start leaves the listener's queue as
    /// it was. `addAfter` skips the episode already playing. Shuffle applies
    /// to manual playlists only.
    @discardableResult
    func playPlaylist(
        _ playlistID: String,
        mode: PlaylistPlayMode = .replace,
        shuffle: Bool = false,
        presentsNowPlaying: Bool = true,
        modelContext: ModelContext
    ) -> Bool {
        var episodes = playlistPlaybackCandidates(playlistID, smartLimit: Self.smartPlaylistQueueLimit)
        if shuffle, playlists.playlists.first(where: { $0.playlistID == playlistID })?.kind == .manual {
            episodes.shuffle()
        }
        guard let first = episodes.first else {
            lastPlaylistError = Self.nothingToPlayMessage
            return false
        }

        switch mode {
        case .replace:
            do {
                try playEpisode(
                    first,
                    presentsNowPlaying: presentsNowPlaying,
                    sourcePlaylistID: playlistID,
                    modelContext: modelContext
                )
            } catch {
                lastPlaybackError = error.localizedDescription
                return false
            }
            guard upNextQueue.clear(modelContext: modelContext),
                  upNextQueue.enqueueLast(Array(episodes.dropFirst()), source: playlistID, modelContext: modelContext)
            else {
                lastUpNextError = upNextQueue.consumeLastErrorMessage()
                return false
            }
            return true
        case .addAfter:
            // The playing episode never joins the queue behind itself: it
            // would replay from the start once the queue reached it, the
            // same reason Play Next / Play Last are disabled for it.
            let remainder = episodes.filter { !isCurrentEpisode($0) }
            guard upNextQueue.enqueueLast(remainder, source: playlistID, modelContext: modelContext) else {
                lastUpNextError = upNextQueue.consumeLastErrorMessage()
                return false
            }
            guard playback.currentEpisode == nil else {
                return true
            }
            return advanceToNextQueuedEpisode(modelContext: modelContext)
        }
    }

    /// "Play from here" for a manual playlist row: starts the tapped row,
    /// even a played one, then puts the unplayed, resolvable rows after it
    /// at the front of Up Next, ahead of anything queued by hand. Nothing is
    /// cleared.
    @discardableResult
    func playPlaylistItem(
        _ itemID: String,
        in playlistID: String,
        presentsNowPlaying: Bool = true,
        modelContext: ModelContext
    ) -> Bool {
        let resolvedItems = playlists.resolvedItems(in: playlistID) { episodeSnapshot(for: $0) }
        guard let index = resolvedItems.firstIndex(where: { $0.item.itemID == itemID }) else {
            lastPlaylistError = Self.unavailablePlaylistEpisodeMessage
            return false
        }
        return playManualPlaylist(
            from: index,
            of: resolvedItems,
            in: playlistID,
            presentsNowPlaying: presentsNowPlaying,
            modelContext: modelContext
        )
    }

    /// "Play from here" by episode, for either kind: a manual playlist's
    /// rows in playlist order, or a smart playlist's evaluation in rule
    /// order, where the tapped episode and those queued after it stay within
    /// `smartPlaylistQueueLimit`. The tapped episode must still be listed.
    @discardableResult
    func playPlaylistEpisode(
        _ episodeID: String,
        in playlistID: String,
        presentsNowPlaying: Bool = true,
        modelContext: ModelContext
    ) -> Bool {
        if let summary = playlist(playlistID), summary.kind == .smart {
            let episodes = smartPlaylistEvaluation(for: summary).episodes
            guard let index = episodes.firstIndex(where: { $0.episodeID == episodeID }) else {
                lastPlaylistError = Self.unavailablePlaylistEpisodeMessage
                return false
            }
            let tapped = episodes[index]
            return playPlaylistEpisodes(
                tapped,
                in: playlistID,
                presentsNowPlaying: presentsNowPlaying,
                modelContext: modelContext
            ) {
                var following: [EpisodeListItemSnapshot] = []
                for episode in episodes[(index + 1)...]
                    where episode.episodeID != tapped.episodeID && isSmartPlaylistCandidate(episode) {
                    following.append(episode)
                    if following.count == Self.smartPlaylistQueueLimit - 1 {
                        break
                    }
                }
                return following
            }
        }

        let resolvedItems = playlists.resolvedItems(in: playlistID) { episodeSnapshot(for: $0) }
        guard let index = resolvedItems.firstIndex(where: { $0.item.episodeID == episodeID }) else {
            lastPlaylistError = Self.unavailablePlaylistEpisodeMessage
            return false
        }
        return playManualPlaylist(
            from: index,
            of: resolvedItems,
            in: playlistID,
            presentsNowPlaying: presentsNowPlaying,
            modelContext: modelContext
        )
    }

    private func playManualPlaylist(
        from index: Int,
        of resolvedItems: [PlaylistResolvedItem],
        in playlistID: String,
        presentsNowPlaying: Bool,
        modelContext: ModelContext
    ) -> Bool {
        guard let tapped = resolvedItems[index].snapshot else {
            lastPlaylistError = Self.unavailablePlaylistEpisodeMessage
            return false
        }
        return playPlaylistEpisodes(
            tapped,
            in: playlistID,
            presentsNowPlaying: presentsNowPlaying,
            modelContext: modelContext
        ) {
            resolvedItems[(index + 1)...]
                .compactMap(\.snapshot)
                .filter { $0.episodeID != tapped.episodeID && isPlaylistCandidate($0) }
        }
    }

    /// Starts `tapped`, then queues the episodes `following` returns next,
    /// both tagged with the playlist. `following` runs after the start, so
    /// played state reflects the previous episode's final flush. A failed
    /// start leaves the queue untouched.
    private func playPlaylistEpisodes(
        _ tapped: EpisodeListItemSnapshot,
        in playlistID: String,
        presentsNowPlaying: Bool,
        modelContext: ModelContext,
        following: () -> [EpisodeListItemSnapshot]
    ) -> Bool {
        do {
            try playEpisode(
                tapped,
                presentsNowPlaying: presentsNowPlaying,
                sourcePlaylistID: playlistID,
                modelContext: modelContext
            )
        } catch {
            lastPlaybackError = error.localizedDescription
            return false
        }

        guard upNextQueue.enqueueNext(following(), source: playlistID, modelContext: modelContext) else {
            lastUpNextError = upNextQueue.consumeLastErrorMessage()
            return false
        }
        return true
    }

    /// Play Next / Play Last for a whole playlist (a smart playlist's first
    /// `smartPlaylistQueueLimit` candidates); never starts playback.
    @discardableResult
    func enqueuePlaylist(
        _ playlistID: String,
        position: UpNextQueuePosition,
        modelContext: ModelContext
    ) -> Bool {
        let candidates = playlistPlaybackCandidates(playlistID, smartLimit: Self.smartPlaylistQueueLimit)
        guard !candidates.isEmpty else {
            lastPlaylistError = Self.nothingToPlayMessage
            return false
        }
        // The playing episode never joins the queue behind itself, as in
        // `.addAfter`. When it was the only candidate there is nothing left
        // to queue, which is a no-op rather than an error: it is neither
        // played nor unavailable.
        let episodes = candidates.filter { !isCurrentEpisode($0) }
        guard !episodes.isEmpty else {
            return true
        }

        let didEnqueue = switch position {
        case .next:
            upNextQueue.enqueueNext(episodes, source: playlistID, modelContext: modelContext)
        case .last:
            upNextQueue.enqueueLast(episodes, source: playlistID, modelContext: modelContext)
        }
        guard didEnqueue else {
            lastUpNextError = upNextQueue.consumeLastErrorMessage()
            return false
        }
        return true
    }

    func remainingQueuedCount(forPlaylist playlistID: String) -> Int {
        upNextQueue.items.count(where: { $0.sourcePlaylistID == playlistID })
    }

    /// Unplayed, resolvable episodes a Download All would start. The download
    /// menu's state is the truth: an in-flight download is excluded, since
    /// restarting it would discard its progress, while paused, failed, and
    /// missing-file downloads resume.
    func playlistDownloadAllCandidates(_ playlistID: String) -> [EpisodeListItemSnapshot] {
        playlistPlaybackCandidates(playlistID).filter { downloadMenuState(for: $0) == .available }
    }

    /// The Download All item's enabled state, without touching the disk: any
    /// unplayed, resolvable episode with no download in flight or completed.
    /// The tap-time list above also re-checks completed files on disk.
    /// A smart playlist stops at its first candidate instead of building
    /// the list, which a No Limit rule can make as long as the library.
    func hasPlaylistDownloadAllCandidates(_ playlistID: String) -> Bool {
        if let summary = playlist(playlistID), summary.kind == .smart {
            return smartPlaylistEvaluation(for: summary).episodes.contains { episode in
                canStartDownloadAll(episode) && isSmartPlaylistCandidate(episode)
            }
        }
        return playlistPlaybackCandidates(playlistID).contains { canStartDownloadAll($0) }
    }

    private func canStartDownloadAll(_ episode: EpisodeListItemSnapshot) -> Bool {
        switch downloads.record(for: episode.episodeID)?.state {
        case nil, .paused, .failed, .missing:
            true
        case .downloading, .completed:
            false
        }
    }

    /// Starts every Download All candidate. `DownloadStore` keeps only the
    /// latest start failure, and a later successful start clears it, so the
    /// failures are counted here and reported through the playlist alert.
    @discardableResult
    func downloadAllPlaylistEpisodes(_ playlistID: String, modelContext: ModelContext) -> Bool {
        let candidates = playlistDownloadAllCandidates(playlistID)
        var failureCount = 0
        var firstFailureMessage: String?
        for episode in candidates where !downloads.startDownload(for: episode, modelContext: modelContext) {
            failureCount += 1
            if firstFailureMessage == nil {
                firstFailureMessage = downloads.lastErrorMessage(for: episode.episodeID)
            }
        }
        guard failureCount > 0 else {
            return true
        }
        lastPlaylistError = Self.downloadAllFailureMessage(
            failureCount: failureCount,
            candidateCount: candidates.count,
            reason: firstFailureMessage
        )
        return false
    }

    static func downloadAllFailureMessage(failureCount: Int, candidateCount: Int, reason: String?) -> String {
        // Grammar agreement resolves only on the attributed localization path.
        let subject = failureCount == candidateCount
            ? String(AttributedString(localized: "^[\(failureCount) episode](inflect: true)").characters)
            : "\(failureCount) of \(candidateCount) episodes"
        let sentence = "\(subject) could not be downloaded."
        guard let reason else {
            return sentence
        }
        return "\(sentence) \(reason)"
    }

    /// A smart playlist's episodes, memoized per playlist in the store. The
    /// key reads only the tokens the rule depends on — progress only for a
    /// played-state clause, downloads only for Downloaded Only, the
    /// reference date only for an age clause — so a view calling this
    /// observes nothing else. Empty for a manual playlist or an unreadable
    /// rule.
    func smartPlaylistEvaluation(for summary: PlaylistSummary) -> SmartPlaylistEvaluation {
        guard summary.kind == .smart, let rule = summary.rule else {
            return .empty
        }

        let key = SmartPlaylistEvaluationKey(
            ruleJSON: summary.ruleJSON ?? rule.encodedJSON(),
            episodeRevision: library.episodeSearchCorpusRevision,
            progressRevision: rule.readsProgress ? library.progressChangeRevision : nil,
            downloadsRevision: rule.downloadedOnly ? downloads.recordsRevision : nil,
            referenceDate: rule.maximumAgeDays == nil ? nil : library.newEpisodeReferenceDate
        )
        return playlists.smartEvaluations.evaluation(for: summary.playlistID, key: key) {
            SmartPlaylistEvaluator.make(
                rule: rule,
                library: library,
                downloadRecords: downloads.records,
                now: library.newEpisodeReferenceDate
            )
        }
    }

    /// The most episodes one Play, Play Next, Play Last or play-from-here
    /// takes from a smart playlist (the largest Limit preset): a No Limit
    /// rule can list the whole library, and every Up Next edit refetches
    /// every queued row. The list itself and Download All stay uncapped.
    static let smartPlaylistQueueLimit = 100

    private static let nothingToPlayMessage = "Nothing to play. Every episode in this playlist is played or unavailable."
    private static let unavailablePlaylistEpisodeMessage = "This episode is no longer available."

    func playlist(_ playlistID: String) -> PlaylistSummary? {
        playlists.playlists.first { $0.playlistID == playlistID }
    }

    /// The playlist's resolvable, unplayed episodes: a manual playlist's in
    /// playlist order, a smart playlist's in rule order, stopping after
    /// `smartLimit` of them.
    private func playlistPlaybackCandidates(
        _ playlistID: String,
        smartLimit: Int? = nil
    ) -> [EpisodeListItemSnapshot] {
        if let summary = playlist(playlistID), summary.kind == .smart {
            var candidates: [EpisodeListItemSnapshot] = []
            for episode in smartPlaylistEvaluation(for: summary).episodes where isSmartPlaylistCandidate(episode) {
                candidates.append(episode)
                if candidates.count == smartLimit {
                    break
                }
            }
            return candidates
        }
        return playlists.resolvedItems(in: playlistID) { episodeSnapshot(for: $0) }
            .compactMap(\.snapshot)
            .filter { isPlaylistCandidate($0) }
    }

    /// Whether Play would start anything, without starting it: the router and
    /// the Siri handler answer "nothing to play" before touching playback.
    func hasPlaylistPlaybackCandidates(_ playlistID: String) -> Bool {
        if let summary = playlist(playlistID), summary.kind == .smart {
            return smartPlaylistEvaluation(for: summary).episodes.contains { isSmartPlaylistCandidate($0) }
        }
        return !playlistPlaybackCandidates(playlistID).isEmpty
    }

    /// The count a collection row shows: a manual playlist's items, a smart
    /// playlist's memoized evaluation.
    func playlistEpisodeCount(for summary: PlaylistSummary) -> Int {
        summary.kind == .smart ? smartPlaylistEvaluation(for: summary).count : summary.itemCount
    }

    private func isPlaylistCandidate(_ episode: EpisodeListItemSnapshot) -> Bool {
        library.progressRecord(for: episode.episodeID)?.isPlayed != true
    }

    /// The Episodes chip's definition of unplayed, which also counts a
    /// position at the end as played, so a Played rule has nothing to play.
    private func isSmartPlaylistCandidate(_ episode: EpisodeListItemSnapshot) -> Bool {
        !library.progressSummary(for: episode).isCompleted
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
        Self.episodeSnapshot(for: episodeID, library: library, downloads: downloads)
    }

    private static func episodeSnapshot(
        for episodeID: String,
        library: LibraryStore,
        downloads: DownloadStore
    ) -> EpisodeListItemSnapshot? {
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
            currentPlaylistSourceID = nil
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
        transcriptIntelligence.load(modelContext: modelContext)
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
    /// ad-free drain or remote transcription keeps its card and Generate
    /// stays lifecycle-managed instead of competing for a second
    /// continued-processing task.
    func armTranscriptGenerationBackgroundSessionIfNeeded(episodeTitle: String) {
        guard !transcriptionEngineSettings.prefersAppleSpeech,
              !transcriptGenerationBackgroundSession.isArmed,
              !adFreePassBackgroundSession.isArmed,
              !remoteTranscriptionBackgroundSession.isArmed
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

        switch remoteTranscription.start(
            episode: episode,
            modelContext: modelContext,
            prepareBackgroundSession: { [weak self] in
                self?.armRemoteTranscriptionBackgroundSessionIfNeeded(episode: episode)
            }
        ) {
        case .started:
            return .started(episodeID: episode.episodeID)
        case .rejected(let message):
            return .unavailable(
                message: message
            )
        }
    }

    /// Resume for a remote transcription parked on the server: re-attaches
    /// the current episode's persisted reference without a new estimate
    /// sheet, since no new job is created.
    @discardableResult
    func resumeRemoteTranscriptionForCurrentEpisode(
        modelContext: ModelContext
    ) -> RemoteTranscriptionStartConfirmationOutcome {
        guard let episode = currentPlaybackEpisodeSnapshot else {
            return .unavailable(
                message: "This episode is no longer available. Refresh the podcast and try again."
            )
        }
        switch resumeRemoteTranscription(episode: episode, modelContext: modelContext) {
        case .started:
            return .started(episodeID: episode.episodeID)
        case .rejected(let message):
            return .unavailable(message: message)
        }
    }

    /// Resume and Try Again taps from episode detail, the More menu and Now
    /// Playing: re-attaches the persisted reference and, being a user
    /// action, may arm the system card.
    @discardableResult
    func resumeRemoteTranscription(
        episode: EpisodeListItemSnapshot,
        modelContext: ModelContext
    ) -> EpisodeRemoteTranscriptionCoordinator.StartOutcome {
        remoteTranscription.resume(
            episode: episode,
            modelContext: modelContext,
            prepareBackgroundSession: { [weak self] in
                self?.armRemoteTranscriptionBackgroundSessionIfNeeded(episode: episode)
            }
        )
    }

    /// One continued-processing card per app: while the ad-free or the
    /// transcript-generation card is armed, the remote run stays
    /// foreground-only. Reached only from a user's start or resume, after
    /// the coordinator reserved the episode and created the run; launch and
    /// activation re-attach never arm.
    private func armRemoteTranscriptionBackgroundSessionIfNeeded(episode: EpisodeListItemSnapshot) {
        guard !remoteTranscriptionBackgroundSession.isArmed else {
            return
        }
        guard !adFreePassBackgroundSession.isArmed,
              !transcriptGenerationBackgroundSession.isArmed
        else {
            remoteTranscriptionBackgroundSession.recordRefusedArm(episodeID: episode.episodeID)
            return
        }

        remoteTranscriptionBackgroundSession.arm(episodeID: episode.episodeID, episodeTitle: episode.title)
        requestLocalNotificationAuthorizationIfNeeded()
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
        switch adFreePass.queueStatus(for: episode.episodeID) {
        case .cloudUnavailable:
            startAdFreePass(for: episode, modelContext: modelContext, mode: .onDevice)
            return nil
        case .remoteParked:
            // Resume re-attaches the parked job; it never asks for a mode.
            adFreePass.resumePausedQueue()
            return nil
        default:
            break
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
                self?.armAdFreePassBackgroundSessionIfNeeded(
                    episodeID: episode.episodeID,
                    episodeTitle: episode.title,
                    mode: mode
                )
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

    /// Lifecycle protection counts only local on-device work. A live
    /// ad-free card whose drain is running a cloud item protects nothing on
    /// this device, so an unrelated local transcript still takes its
    /// lifecycle interrupt. The remote transcription card never counts.
    var isProtectingLocalBackgroundWork: Bool {
        let protectsLocalPass = adFreePassBackgroundSession.isProtectingBackgroundExecution
            && adFreePass.activeItem?.mode != .cloud
        return protectsLocalPass || transcriptGenerationBackgroundSession.isProtectingBackgroundExecution
    }

    func armBackgroundContinuationForActiveQueue() {
        guard adFreePass.queueState == .running,
              !adFreePassBackgroundSession.isArmed,
              let activeItem = adFreePass.activeItem
        else {
            return
        }

        armAdFreePassBackgroundSessionIfNeeded(
            episodeID: activeItem.episodeID,
            episodeTitle: activeItem.episode.title,
            mode: activeItem.mode
        )
        adFreePass.republishCurrentStage()
    }

    /// Re-attaches kept remote job references on launch and on scene
    /// activation (`RemoteJobReattacher`). An activation that arrives before
    /// the launch restore has loaded the library does nothing; the launch
    /// trigger covers it. Returns the recovery pass, shared with any pass
    /// already running.
    @discardableResult
    func reattachRemoteJobsIfNeeded(
        modelContext: ModelContext,
        trigger: RemoteJobReattacher.Trigger
    ) -> Task<Void, Never>? {
        guard trigger == .launch || hasRestoredPlaybackSurface else {
            return nil
        }
        return remoteJobReattacher.reattachIfNeeded(modelContext: modelContext)
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
        adFreePass.resumeRemoteParkedQueueIfNeeded()

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

    /// One continued-processing card per app: while the transcript
    /// generation or remote transcription card is armed the drain stays
    /// foreground-only. A drain of cloud items alone never asks for GPU.
    private func armAdFreePassBackgroundSessionIfNeeded(
        episodeID: String,
        episodeTitle: String,
        mode: AdDetectionMode
    ) {
        guard !adFreePassBackgroundSession.isArmed else {
            return
        }
        guard !transcriptGenerationBackgroundSession.isArmed,
              !remoteTranscriptionBackgroundSession.isArmed
        else {
            let holder = transcriptGenerationBackgroundSession.isArmed ? "transcriptGeneration" : "remoteTranscription"
            AdFreePassBackgroundRunLog.record("arm skipped reason=\(holder)HoldsCard episodeID=\(episodeID)")
            recordCloudSessionEvent(.sessionForegroundOnly, episodeID: episodeID, mode: mode)
            return
        }

        adFreePassBackgroundSession.arm(
            episodeTitle: episodeTitle,
            requiresGPU: adFreePass.holdsOnDeviceWork,
            cancellationSource: adFreePass.cancellationSource
        )
        recordCloudSessionEvent(
            adFreePassBackgroundSession.isArmed ? .sessionArmed : .sessionForegroundOnly,
            episodeID: episodeID,
            mode: mode
        )
        requestLocalNotificationAuthorizationIfNeeded()
    }

    /// The remote-job trail notes how a cloud item's card request ended.
    private func recordCloudSessionEvent(
        _ kind: RemoteJobDiagnosticEvent.Kind,
        episodeID: String,
        mode: AdDetectionMode
    ) {
        guard mode == .cloud else {
            return
        }
        let store = remoteTranscription.store
        let reference = store.existingReference(for: episodeID, purpose: .adDetection)
        store.diagnostics.record(RemoteJobDiagnosticEvent(
            component: .backgroundSession,
            kind: kind,
            episodeID: episodeID,
            jobID: reference?.jobID,
            clientRequestID: reference?.clientRequestID,
            purpose: .adDetection
        ))
    }

    private func requestLocalNotificationAuthorizationIfNeeded() {
        Task { [adFreePassNotificationCenter] in
            guard await adFreePassNotificationCenter.authorizationStatus() == .notDetermined else {
                return
            }
            await adFreePassNotificationCenter.requestProvisionalAuthorization()
        }
    }

    /// The remote-job trail records the decisions that concern a remote
    /// job: the parked cloud head's notification, and each remote-owned
    /// outcome the local summary left out.
    private func scheduleAdFreePassCompletionNotificationIfNeeded(terminal: AdFreePassQueueTerminalOutcome) {
        let scheduler = AdFreePassCompletionNotificationScheduler(center: adFreePassNotificationCenter)
        let outcomes = adFreePass.drainOutcomes
        let isSceneActive = isSceneActive
        let jobStore = remoteTranscription.store
        let diagnostics = jobStore.diagnostics
        let parkedHead: (episodeID: String, reference: RemoteTranscriptionJobReference?)? =
            if case .remoteParked = terminal, let head = adFreePass.queueItems.first {
                (head.episodeID, jobStore.existingReference(for: head.episodeID, purpose: .adDetection))
            } else {
                nil
            }
        if case .drained = terminal {
            for outcome in outcomes where outcome.completionDeliveryOwner == .remote {
                diagnostics.record(CompletionDeliveryDecision.suppressed(.remoteOwner).diagnosticEvent(
                    episodeID: outcome.episodeID,
                    reference: nil,
                    purpose: .adDetection
                ))
            }
        }
        Task {
            let decision = await scheduler.scheduleIfNeeded(
                terminal: terminal,
                outcomes: outcomes,
                isSceneActive: isSceneActive
            )
            if let parkedHead {
                diagnostics.record(decision.diagnosticEvent(
                    episodeID: parkedHead.episodeID,
                    reference: parkedHead.reference,
                    purpose: .adDetection
                ))
            }
        }
    }

    /// One delivery decision per plain run ending. The owner is the run's
    /// own snapshot. A parked reference also tells delivery whether a server
    /// job may exist; a completed or failed run has already cleared it.
    private func scheduleRemoteTranscriptionNotificationIfNeeded(
        episodeID: String,
        phase: RemoteTranscriptionRequestPhase,
        deliveryOwner: JobCompletionDeliveryOwner
    ) {
        let store = remoteTranscription.store
        let scheduler = RemoteTranscriptionNotificationScheduler(center: adFreePassNotificationCenter)
        let episodeTitle = store.activeEpisodeID == episodeID ? store.activeEpisodeTitle : nil
        let reference = store.existingReference(for: episodeID)
        let diagnostics = store.diagnostics
        let isSceneActive = isSceneActive
        remoteTranscriptionDeliveryTask = Task {
            let decision = await scheduler.scheduleIfNeeded(
                phase: phase,
                episodeTitle: episodeTitle,
                deliveryOwner: deliveryOwner,
                isSceneActive: isSceneActive,
                createState: reference?.createState
            )
            diagnostics.record(decision.diagnosticEvent(
                episodeID: episodeID,
                reference: reference,
                purpose: .transcription
            ))
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
        // The server keeps working: expiration only stops local polling and
        // keeps the reference for Resume. It never touches local
        // transcription and never cancels the job.
        remoteTranscriptionBackgroundSession.onExpiration = { [weak self] episodeID in
            guard let self, remoteTranscription.store.activeEpisodeID == episodeID else {
                return nil
            }
            // Park now; hand back the run's unwind and its notification
            // decision, so the session completes the task only after both.
            let run = remoteTranscription.park(exit: .parked)
            return Task { [weak self] in
                await run?.value
                await self?.remoteTranscriptionDeliveryTask?.value
            }
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
            // Wait for the local asset's duration unless its matching
            // transcript already measured it. RSS can exclude inserted ads.
            episode.duration = nil
            if let transcript = transcriptions.record(for: snapshot.episodeID),
               let duration = sanitizedDuration(transcript.audioDuration),
               TranscriptSourceAlignment.downloadMatchesTranscript(
                   trustedDownloadSHA256: downloads.completedSourceIdentity(for: snapshot.episodeID)?.sha256,
                   documentSHA256: transcript.sourceFileSHA256
               ) {
                episode.duration = duration
            }
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
            playbackRestorePreference.remember(
                episode.id.rawValue,
                sourcePlaylistID: currentPlaylistSourceID,
                modelContext: modelContext
            )
        }
        return didSave
    }

    func restorePreviousPlaybackIfAvailable(modelContext: ModelContext) {
        guard playback.currentEpisode == nil else {
            return
        }

        guard let record = restorableEpisode(modelContext: modelContext) else {
            playbackRestorePreference.clear(modelContext: modelContext)
            currentPlaylistSourceID = nil
            return
        }

        let storedSourcePlaylistID = playbackRestorePreference.storedSourcePlaylistID(modelContext: modelContext)
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
            currentPlaylistSourceID = storedSourcePlaylistID
            playbackRestorePreference.remember(
                record.episodeID,
                sourcePlaylistID: storedSourcePlaylistID,
                modelContext: modelContext
            )
        } catch {
            playbackRestorePreference.clear(modelContext: modelContext)
            currentPlaylistSourceID = nil
        }
    }

    func requestNowPlayingPresentation() {
        nowPlayingPresentationRequest += 1
    }

    func requestAddToPlaylist(episodeID: String) {
        addToPlaylistPresentationRequest = AddToPlaylistPresentationRequest(episodeID: episodeID, token: UUID())
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

    func requestDataNukeConfirmationPresentation() {
        dataNukeConfirmationPresentationRequest += 1
    }

    @discardableResult
    func presentImportedSubscriptionsNotification(feedURLStrings: Set<String>) -> ImportedSubscriptionsNotification? {
        guard !feedURLStrings.isEmpty else {
            return nil
        }

        if let existing = importedSubscriptionsNotification {
            let notification = existing.merging(feedURLStrings: feedURLStrings)
            importedSubscriptionsNotification = notification
            return notification
        }
        importedSubscriptionsNotificationID += 1
        let notification = ImportedSubscriptionsNotification(
            id: importedSubscriptionsNotificationID,
            feedURLStrings: feedURLStrings
        )
        importedSubscriptionsNotification = notification
        return notification
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
            currentPlaylistSourceID = nil
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
            currentPlaylistSourceID = nil
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

    @discardableResult
    func setTapToPlayEnabled(
        _ isEnabled: Bool,
        modelContext: ModelContext
    ) -> Bool {
        playbackSettings.setTapToPlayEnabled(isEnabled, modelContext: modelContext)
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
        coreStoresHydrated = false
        lastPlaybackError = nil
        lastUpNextError = nil
        lastPlaylistError = nil
        lastUnsubscribeErrorMessage = nil
        playbackRestorePreference.resetAfterDataNuke()
        currentPlaylistSourceID = nil
        library.resetAfterDataNuke()
        await downloads.load(modelContext: modelContext)
        transcriptions.load(modelContext: modelContext)
        adAnalyses.load(modelContext: modelContext)
        transcriptAnalysisQueue.resetAfterDataNuke()
        transcriptAnalyses.load(modelContext: modelContext)
        transcriptIntelligence.load(modelContext: modelContext)
        adFreePass.reset()
        upNextQueue.resetAfterDataNuke()
        playlists.resetAfterDataNuke()
        adFreePassBackgroundSession.reset()
        transcriptGenerationBackgroundSession.reset()
        remoteTranscriptionBackgroundSession.reset()
        transcriptImprovement.resetForDataNuke()
        transcriptionModels.resetAfterDataNuke()
        transcriptionEngineSettings.load(modelContext: modelContext)
        appearanceSettings.load(modelContext: modelContext)
        appIcon.load()
        podcastEpisodeListSettings.load(modelContext: modelContext)
        libraryDisplaySettings.load(modelContext: modelContext)
        playlistDisplaySettings.load(modelContext: modelContext)
        playlists.sortOrder = playlistDisplaySettings.sortOrder
        inboxEpisodeListSettings.load(modelContext: modelContext)
        recentSearches.load(modelContext: modelContext)
        playbackSettings.load(modelContext: modelContext, playback: playback)
        notificationSettings.resetAfterDataNuke()
        onboardingState.load(modelContext: modelContext)
        coreStoresHydrated = true
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
        sourcePlaylistID: String? = nil,
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
        // Assigned only once the load succeeds: the flush above remembered
        // the previous episode's pair, and a failed start keeps it.
        currentPlaylistSourceID = sourcePlaylistID
            ?? upNextQueue.items.first { $0.episodeID == snapshot.episodeID }?.sourcePlaylistID
        _ = upNextQueue.remove(episodeID: snapshot.episodeID, modelContext: modelContext)
        downloadCleanup.deferPlayedSweep(modelContext: modelContext)
        refreshPlaybackSkipZonesForCurrentEpisode()
        nowPlayingProbeMark("play-loaded")
        playbackRestorePreference.remember(
            snapshot.episodeID,
            sourcePlaylistID: currentPlaylistSourceID,
            modelContext: modelContext
        )
        if autoplay {
            playback.play()
            nowPlayingProbeMark("play-started")
            siriMediaDiscovery.donatePlaybackIfNeeded(for: snapshot)
            if let currentPlaylistSourceID, let playlist = playlist(currentPlaylistSourceID) {
                siriMediaDiscovery.donatePlaylistPlaybackIfNeeded(playlistID: playlist.playlistID, name: playlist.name)
            }
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
        var isReplaySuppressed = false
        if let transcript = try? await transcriptions.loadDocument(for: episode.episodeID) {
            do { isReplaySuppressed = try await adAnalyses.automaticReplayError(for: transcript) != nil }
            catch { isReplaySuppressed = true }
        }
        let policy = AdAutoDetectPlayPolicy(
            isAutoDetectEnabled: library.isAdAutoDetectEnabled(forPodcastID: episode.podcastID),
            hasCurrentCompletedAnalysis: hasCurrentCompletedAnalysis,
            queueStatus: adFreePass.queueStatus(for: episode.episodeID),
            isReplaySuppressed: isReplaySuppressed
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
