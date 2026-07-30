import Foundation
import Observation
import OpenCastCore
import OpenCastPlayback
import OpenCastTranscription
import SwiftData
import UserNotifications

@Observable
final class OpenCastAppModel {
    private static let lastPlaybackEpisodeIDKey = "playback.lastEpisodeID"
    private static let playbackProgressPersistenceInterval = Duration.seconds(5)

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
    let remoteTranscriptionPurchases: RemoteTranscriptionPurchaseStore
    let adAnalyses: EpisodeAdAnalysisStore
    let adFreePass: EpisodeAdFreePassCoordinator
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
    let syncStatus: SyncStatusStore
    let allowsAutomaticFeedRefresh: Bool
    let adFreePassPresentationOverride: EpisodeAdFreePassPresentation?
    let adFreePassNotificationCenter: any AdFreePassNotificationCenter
    /// Tracked from the root lifecycle modifier; completion notifications are
    /// suppressed at scheduling time while the scene is active.
    var isSceneActive = true
    var nowPlayingPresentationRequest = 0
    var isNowPlayingPresented = false
    var onboardingPresentationRequest = 0
    var lastPlaybackError: String?
    var importedSubscriptionsNotification: ImportedSubscriptionsNotification?
    var replacesNowPlayingArtworkWithPlaybackDiagnostics = false {
        didSet {
            guard oldValue != replacesNowPlayingArtworkWithPlaybackDiagnostics else {
                return
            }
            playback.setPlaybackDiagnosticsEnabled(replacesNowPlayingArtworkWithPlaybackDiagnostics)
        }
    }
    var isNukingData = false
    var lastDataNukeErrorMessage: String?
    var dataNukeCompletionID = 0
    /// Sub-floor confidence zones for the current episode: rendered dimmed on
    /// the timeline, never handed to `PlaybackAdSkipPolicy`.
    private(set) var displayOnlySkipZones: [PlaybackSkipZone] = []
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
    @ObservationIgnored private var progressPersistenceTask: Task<Void, Never>?
    @ObservationIgnored private var progressBoundaryPersistenceTask: Task<Void, Never>?
    // The 5-second flush calls rememberLastPlaybackEpisode every tick; the
    // cached record makes the unchanged-episode tick a pure no-op instead of
    // a refetch plus a guaranteed dirty save.
    @ObservationIgnored private var lastPlaybackEpisodeRecordCache: LocalPreferenceRecord?
    @ObservationIgnored private let siriMediaDiscovery: SiriMediaDiscovery
    @ObservationIgnored private var siriMediaUserContextObservationTask: Task<Void, Never>?
    @ObservationIgnored private var hasRunVoiceBoostDeviceProbe = false
    @ObservationIgnored private var importedSubscriptionsNotificationID = 0

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
        adFreePass: EpisodeAdFreePassCoordinator = EpisodeAdFreePassCoordinator(),
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
        siriMediaDiscovery: SiriMediaDiscovery = SiriMediaDiscovery()
    ) {
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
        self.adFreePass = adFreePass
        self.adFreePassBackgroundSession = adFreePassBackgroundSession
        self.transcriptGenerationBackgroundSession = transcriptGenerationBackgroundSession
        self.transcriptImprovement = EpisodeTranscriptImprovementCoordinator(
            appleSpeechAssets: appleSpeechAssets,
            transcriptions: transcriptions
        )
        self.playback = playback ?? AVFoundationPlaybackController(
            nowPlayingArtworkLoader: SharedNowPlayingArtworkLoader()
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
        let defaultPodcastDirectoryService = ITunesPodcastDirectoryService(httpClient: resolvedHTTPClient)
        let resolvedPodcastDirectoryService = podcastDirectoryService ?? defaultPodcastDirectoryService
        self.podcastDirectoryService = resolvedPodcastDirectoryService
        self.syncStatus = syncStatus
        self.allowsAutomaticFeedRefresh = allowsAutomaticFeedRefresh
        self.adFreePassPresentationOverride = adFreePassPresentationOverride
        self.adFreePassNotificationCenter = adFreePassNotificationCenter ?? UNUserNotificationCenter.current()
        self.siriMediaDiscovery = siriMediaDiscovery
        self.transcriptions.onEpisodeStateChanged = { [weak self] episodeID in
            self?.refreshPlaybackSkipZonesIfCurrentEpisode(episodeID: episodeID)
        }
        self.transcriptions.onAppleSpeechRunInterrupted = { [weak self] episodeID, restoredPriorTranscript in
            self?.scheduleTranscriptionInterruptedNotificationIfNeeded(
                episodeID: episodeID,
                restoredPriorTranscript: restoredPriorTranscript
            )
        }
        self.adAnalyses.onEpisodeStateChanged = { [weak self] episodeID in
            self?.refreshPlaybackSkipZonesIfCurrentEpisode(episodeID: episodeID)
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
        startSiriMediaUserContextObservation()
    }

    deinit {
        siriMediaUserContextObservationTask?.cancel()
    }

    func ensureCoreStoresLoaded(modelContext: ModelContext) async {
        if let coreStoresLoadTask {
            await coreStoresLoadTask.value
            return
        }

        let task = Task {
            await library.load(modelContext: modelContext)
            downloads.load(modelContext: modelContext)
            playbackSettings.load(modelContext: modelContext, playback: playback)
            podcastEpisodeListSettings.load(modelContext: modelContext)
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

    func unsubscribe(feedURL: String, modelContext: ModelContext) async {
        let podcastID = PodcastID(rawValue: feedURL)
        if playback.currentEpisode?.podcastID == podcastID {
            playback.unload()
            clearLastPlaybackEpisode(modelContext: modelContext)
        }

        do {
            try adAnalyses.deleteAnalyses(forPodcastID: feedURL, modelContext: modelContext)
            try transcriptions.deleteTranscripts(forPodcastID: feedURL, modelContext: modelContext)
        } catch {
            lastPlaybackError = error.localizedDescription
        }
        if !podcastEpisodeListSettings.removePreferences(
            forPodcastID: feedURL,
            modelContext: modelContext
        ) {
            lastPlaybackError = podcastEpisodeListSettings.lastErrorMessage
        }
        await library.unsubscribe(feedURL: feedURL, modelContext: modelContext, downloadStore: downloads)
        guard !library.isActivelySubscribed(to: feedURL) else {
            return
        }
        siriMediaDiscovery.deleteDonations(forPodcastID: feedURL)
    }

    func loadLocalTranscriptionState(modelContext: ModelContext) {
        transcriptionModels.load(modelContext: modelContext)
        transcriptionEngineSettings.load(modelContext: modelContext)
        adDetectionSettings.load(modelContext: modelContext)
        transcriptions.load(modelContext: modelContext)
        adAnalyses.load(modelContext: modelContext)
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

        Task {
            await transcribeDownloadedEpisodeResolvingEngine(
                episode,
                downloadRecord: downloadRecord,
                localFileURL: localFileURL,
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

    func startRemoteTranscriptionForCurrentEpisode(modelContext: ModelContext) {
        guard let episode = currentPlaybackEpisodeSnapshot,
              !transcriptions.hasCompletedTranscript(for: episode.episodeID)
        else {
            return
        }

        remoteTranscription.start(episode: episode, modelContext: modelContext)
    }

    private func transcribeDownloadedEpisodeResolvingEngine(
        _ episode: EpisodeListItemSnapshot,
        downloadRecord: EpisodeDownloadRecord,
        localFileURL: URL,
        modelContext: ModelContext
    ) async {
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
            downloads: downloads,
            transcriptionModels: transcriptionModels,
            appleSpeechAssets: appleSpeechAssets,
            transcriptions: transcriptions,
            adAnalyses: adAnalyses,
            modelContext: modelContext,
            transcriptionEngine: transcriptionEngine,
            podcastLanguageCode: podcastLanguageCode(forPodcastID: episode.podcastID),
            mode: mode,
            remoteRunner: remoteTranscriptionRunner,
            remoteJobStore: remoteTranscription.store,
            remotePurchases: remoteTranscriptionPurchases,
            prepareBackgroundSession: { [weak self] in
                // Cloud items never arm the continued-processing card: the
                // server keeps working while the app is suspended.
                guard mode == .onDevice else {
                    return
                }
                self?.armAdFreePassBackgroundSessionIfNeeded(episodeTitle: episode.title)
            },
            refreshSkipZones: { [weak self] in
                self?.zoneCountAfterPass(for: episode) ?? 0
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
            downloads: downloads,
            transcriptionModels: transcriptionModels,
            appleSpeechAssets: appleSpeechAssets,
            transcriptions: transcriptions,
            adAnalyses: adAnalyses,
            modelContext: modelContext,
            podcastLanguageCode: { [weak self] podcastID in
                self?.podcastLanguageCode(forPodcastID: podcastID)
            },
            remoteRunner: remoteTranscriptionRunner,
            remoteJobStore: remoteTranscription.store,
            remotePurchases: remoteTranscriptionPurchases,
            refreshSkipZones: { [weak self] episode in
                self?.zoneCountAfterPass(for: episode) ?? 0
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

    private func zoneCountAfterPass(for episode: EpisodeListItemSnapshot) -> Int {
        if isCurrentEpisode(episode) {
            refreshPlaybackSkipZonesForCurrentEpisode()
            return playback.skipZones.count
        }

        return currentAdAnalysisZoneTiers(
            episodeID: episode.episodeID,
            duration: episode.duration
        ).autoSkip.count
    }

    func refreshPlaybackSkipZonesForCurrentEpisode() {
        guard let episode = playback.currentEpisode else {
            playback.setSkipZones([])
            displayOnlySkipZones = []
            return
        }

        let tiers = currentAdAnalysisZoneTiers(
            episodeID: episode.id.rawValue,
            duration: playback.duration ?? episode.duration
        )
        playback.setSkipZones(tiers.autoSkip)
        displayOnlySkipZones = tiers.displayOnly
    }

    /// Pill undo: jump back to the start of the last auto-skipped zone with a
    /// `.scrub`-landing seek so the zone plays through once and re-arms after
    /// exit (existing `PlaybackAdSkipPolicy` disarm semantics).
    func undoLastAutoSkip() {
        guard let target = NowPlayingAutoSkipUndo.seekTarget(
            for: playback.lastAutoSkipEvent,
            zones: playback.skipZones
        ) else {
            return
        }

        playback.seek(to: target, intent: NowPlayingAutoSkipUndo.seekIntent)
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

    func deleteDownload(
        _ record: EpisodeDownloadRecord,
        modelContext: ModelContext
    ) {
        let localFileURL = downloads.localFileURL(for: record)
        transcriptions.handleDownloadDeletion(record, localFileURL: localFileURL, modelContext: modelContext)
        downloads.deleteDownload(record, modelContext: modelContext)
    }

    func deleteDownloads(
        _ records: [EpisodeDownloadRecord],
        modelContext: ModelContext
    ) {
        handleTranscriptionCleanupForDeletedDownloads(records, modelContext: modelContext)
        downloads.deleteDownloads(records, modelContext: modelContext)
    }

    func deleteAllDownloads(modelContext: ModelContext) {
        transcriptions.handleAllDownloadsDeleted(modelContext: modelContext)
        downloads.deleteAllDownloads(modelContext: modelContext)
    }

    func deleteCompletedDownloads(
        forPodcastID podcastID: String,
        modelContext: ModelContext
    ) throws {
        let completedRecords = downloads.records.filter {
            $0.podcastID == podcastID && $0.state == .completed
        }
        handleTranscriptionCleanupForDeletedDownloads(completedRecords, modelContext: modelContext)
        for record in completedRecords {
            try downloads.deleteDownloadThrowing(record, modelContext: modelContext)
        }
    }

    func deleteDownloads(forPodcastID podcastID: String, modelContext: ModelContext) {
        let records = downloads.records.filter { $0.podcastID == podcastID }
        handleTranscriptionCleanupForDeletedDownloads(records, modelContext: modelContext)

        do {
            try downloads.deleteDownloads(forPodcastID: podcastID, modelContext: modelContext)
        } catch {
            lastPlaybackError = "Unable to delete this podcast's downloads: \(error.localizedDescription)"
        }
    }

    func sweepPlayedDownloadsIfEnabled(modelContext: ModelContext) {
        guard downloads.autoDeletesPlayedDownloads else {
            return
        }

        deletePlayedDownloads(modelContext: modelContext)
    }

    func deletePlayedDownloads(modelContext: ModelContext) {
        let eligibleRecords = downloads.records.filter { record in
            guard record.state == .completed else {
                return false
            }
            guard library.progressRecord(for: record.episodeID)?.isPlayed == true,
                  playback.currentEpisode?.id.rawValue != record.episodeID,
                  !transcriptions.isActivelyTranscribing(episodeID: record.episodeID)
            else {
                return false
            }
            // A download whose bytes a transcript describes is that
            // transcript's karaoke asset; sweeping it would strand the
            // transcript on a mismatch no re-download can repair (dynamic
            // enclosures return different assemblies).
            if TranscriptSourceAlignment.downloadMatchesTranscript(
                trustedDownloadSHA256: record.sourceFileSHA256,
                documentSHA256: transcriptions.record(for: record.episodeID)?.sourceFileSHA256 ?? ""
            ) {
                return false
            }

            switch adFreePass.queueStatus(for: record.episodeID) {
            case .queued, .running, .capDeferred:
                return false
            case .notQueued, .completed, .failed, .cloudUnavailable:
                return true
            }
        }
        deleteDownloads(eligibleRecords, modelContext: modelContext)
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

    /// Appended to the Now Playing diagnostics text so one report establishes
    /// both source-identity invariants for the current episode: which bytes
    /// the transcript and download recorded, which asset the live player item
    /// actually loaded, whether their timelines agree, and the resulting
    /// alignment verdict — plus the build that produced the report.
    var playbackSourceIdentityDiagnostics: String {
        guard let episodeID = playback.currentEpisode?.id.rawValue else {
            return ""
        }

        let transcriptRecord = transcriptions.record(for: episodeID)
        let downloadRecord = downloads.record(for: episodeID)
        let itemIdentity = playback.currentItemSourceIdentity
        let alignment = TranscriptSourceAlignment.resolve(
            documentSHA256: transcriptRecord?.sourceFileSHA256 ?? "",
            trustedDownloadSHA256: downloads.completedSourceIdentity(for: episodeID)?.sha256,
            downloadFileURL: downloadRecord.flatMap(downloads.localFileURL(for:)),
            playerItemURL: itemIdentity?.assetURL
        )

        return """


        app.build: \(diagnosticsValue(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String)) (\(diagnosticsValue(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String)))
        sourceIdentity.transcript.sha256: \(diagnosticsValue(transcriptRecord?.sourceFileSHA256))
        sourceIdentity.transcript.audioDuration: \(diagnosticsSeconds(transcriptRecord?.audioDuration))
        sourceIdentity.download.sha256: \(diagnosticsValue(downloadRecord?.sourceFileSHA256))
        sourceIdentity.download.trusted.sha256: \(diagnosticsValue(downloads.completedSourceIdentity(for: episodeID)?.sha256))
        sourceIdentity.player.assetURL: \(diagnosticsValue(itemIdentity?.assetURL.absoluteString))
        sourceIdentity.player.kind: \(diagnosticsItemKind(itemIdentity?.kind))
        sourceIdentity.player.itemDuration: \(diagnosticsSeconds(itemIdentity?.itemDuration))
        sourceIdentity.alignment: \(diagnosticsAlignment(alignment))
        """
    }

    private func diagnosticsValue(_ value: String?) -> String {
        guard let value, !value.isEmpty else {
            return "nil"
        }
        return value
    }

    private func diagnosticsSeconds(_ value: TimeInterval?) -> String {
        guard let value, value.isFinite else {
            return "nil"
        }
        return value.formatted(.number.precision(.fractionLength(3)))
    }

    private func diagnosticsItemKind(_ kind: PlaybackItemSourceIdentity.Kind?) -> String {
        switch kind {
        case .localFile:
            "local file"
        case .networkStream:
            "network stream"
        case .streamingCache:
            "streaming cache"
        case nil:
            "nil"
        }
    }

    private func diagnosticsAlignment(_ alignment: TranscriptSourceAlignment) -> String {
        switch alignment {
        case .verified:
            "verified"
        case .mismatched(let canSwitch):
            "mismatched (switchable=\(canSwitch))"
        }
    }

    @discardableResult
    func flushPlaybackProgress(
        modelContext: ModelContext,
        refreshObservableProgress: Bool = true
    ) -> Bool {
        guard let episode = playback.currentEpisode else {
            return false
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
            clearLastPlaybackEpisode(modelContext: modelContext)
        } else {
            rememberLastPlaybackEpisode(episode.id.rawValue, modelContext: modelContext)
        }
        return didSave
    }

    func restorePreviousPlaybackIfAvailable(modelContext: ModelContext) {
        guard playback.currentEpisode == nil else {
            return
        }

        guard let record = restorableEpisode(modelContext: modelContext) else {
            clearLastPlaybackEpisode(modelContext: modelContext)
            return
        }

        do {
            let episode = try resolvedPlaybackEpisode(
                for: record,
                source: preferredPlaybackSource(for: record.episodeID),
                modelContext: modelContext
            )
            applyVoiceBoostSetting(for: episode, modelContext: modelContext)
            try playback.load(episode, startPosition: library.resumePosition(for: record.episodeID))
            refreshPlaybackSkipZonesForCurrentEpisode()
            rememberLastPlaybackEpisode(record.episodeID, modelContext: modelContext)
        } catch {
            clearLastPlaybackEpisode(modelContext: modelContext)
        }
    }

    func requestNowPlayingPresentation() {
        nowPlayingPresentationRequest += 1
    }

    @discardableResult
    func dismissCurrentPlayback(modelContext: ModelContext) -> Bool {
        let hadCurrentEpisode = playback.currentEpisode != nil
        flushPlaybackProgress(modelContext: modelContext)
        playback.unload()
        clearLastPlaybackEpisode(modelContext: modelContext)
        isNowPlayingPresented = false
        sweepPlayedDownloadsIfEnabled(modelContext: modelContext)
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
        guard !isNukingData else {
            return
        }

        isNukingData = true
        lastDataNukeErrorMessage = nil
        defer {
            isNukingData = false
        }

        do {
            let accountStatus = await syncStatus.refreshAccountStatus(force: true)
            guard accountStatus == .available else {
                throw DataNukeError.iCloudUnavailable(accountStatus)
            }

            transcriptionRequests.resetForDataNuke()
            await notificationSettings.deleteInstallIfRegistered()
            library.prepareForDataNuke()
            try await adAnalyses.nukeAllAnalyses(modelContext: modelContext)
            try await transcriptions.nukeAllTranscripts(modelContext: modelContext)
            try downloads.nukeAllDownloads(modelContext: modelContext)
            try transcriptionModels.deleteInstalledModelImmediately()
            let siriPodcastIDs = library.activePodcastIDs
            try deleteAllModelRows(modelContext: modelContext)
            siriMediaDiscovery.deleteDonations(forPodcastIDs: siriPodcastIDs)
            // Reset runtime state before any suspension so the UI never renders
            // the deleted-and-saved SwiftData records, even if a later step throws.
            resetRuntimeStateAfterDataNuke(modelContext: modelContext)
            try await library.deleteAllLocalCache()
            try await cacheController.clearCachesNow()
            dataNukeCompletionID += 1
        } catch {
            lastDataNukeErrorMessage = error.localizedDescription
            throw error
        }
    }

    func clearDataNukeError() {
        lastDataNukeErrorMessage = nil
    }

    @discardableResult
    func markEpisodePlayed(
        _ episode: EpisodeListItemSnapshot,
        modelContext: ModelContext
    ) -> Bool {
        let didSave = library.markEpisodePlayed(episode, modelContext: modelContext)
        if isCurrentEpisode(episode) {
            // Mark Played is a playback command too, so unload even when persistence was already complete.
            playback.unload()
            clearLastPlaybackEpisode(modelContext: modelContext)
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
            clearLastPlaybackEpisode(modelContext: modelContext)
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
        if playback.currentEpisode?.podcastID.rawValue == podcastID {
            playback.unload()
            clearLastPlaybackEpisode(modelContext: modelContext)
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

    private func deleteAllModelRows(modelContext: ModelContext) throws {
        try deleteAll(SubscriptionRecord.self, modelContext: modelContext)
        try deleteAll(EpisodeProgressRecord.self, modelContext: modelContext)
        try deleteAll(PodcastCacheRecord.self, modelContext: modelContext)
        try deleteAll(EpisodeCacheRecord.self, modelContext: modelContext)
        try deleteAll(RefreshLogRecord.self, modelContext: modelContext)
        try deleteAll(LocalPreferenceRecord.self, modelContext: modelContext)
        try deleteAll(EpisodeDownloadRecord.self, modelContext: modelContext)
        try deleteAll(EpisodeTranscriptRecord.self, modelContext: modelContext)
        try deleteAll(EpisodeAdAnalysisRecord.self, modelContext: modelContext)
        try deleteAll(AdFreePassQueueItemRecord.self, modelContext: modelContext)
        try modelContext.save()
    }

    private func deleteAll<Model: PersistentModel>(
        _ modelType: Model.Type,
        modelContext: ModelContext
    ) throws {
        for record in try modelContext.fetch(FetchDescriptor<Model>()) {
            modelContext.delete(record)
        }
    }

    private func resetRuntimeStateAfterDataNuke(modelContext: ModelContext) {
        playback.unload()
        isNowPlayingPresented = false
        lastPlaybackError = nil
        lastPlaybackEpisodeRecordCache = nil
        library.resetAfterDataNuke()
        downloads.load(modelContext: modelContext)
        transcriptions.load(modelContext: modelContext)
        adAnalyses.load(modelContext: modelContext)
        adFreePass.reset()
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

    private func handleTranscriptionCleanupForDeletedDownloads(
        _ records: [EpisodeDownloadRecord],
        modelContext: ModelContext
    ) {
        for record in records {
            let localFileURL = downloads.localFileURL(for: record)
            transcriptions.handleDownloadDeletion(
                record,
                localFileURL: localFileURL,
                modelContext: modelContext
            )
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
        flushPlaybackProgress(modelContext: modelContext)
        let episode = try resolvedPlaybackEpisode(for: snapshot, source: source, modelContext: modelContext)
        nowPlayingProbeMark("play-validated")
        applyVoiceBoostSetting(for: episode, modelContext: modelContext)
        try playback.load(
            episode,
            startPosition: startPosition ?? library.resumePosition(for: snapshot.episodeID)
        )
        sweepPlayedDownloadsIfEnabled(modelContext: modelContext)
        refreshPlaybackSkipZonesForCurrentEpisode()
        nowPlayingProbeMark("play-loaded")
        rememberLastPlaybackEpisode(snapshot.episodeID, modelContext: modelContext)
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

        // Auto passes never arm the background session (decision 1);
        // continuation requires an explicit tap. They follow the stored
        // detection mode (decision 3): cloud mode enqueues a cloud job on
        // play with no per-episode confirmation; the authoritative credits
        // check lives inside the cloud pass itself.
        adFreePass.enqueue(
            episode: episode,
            origin: .auto,
            downloads: downloads,
            transcriptionModels: transcriptionModels,
            appleSpeechAssets: appleSpeechAssets,
            transcriptions: transcriptions,
            adAnalyses: adAnalyses,
            modelContext: modelContext,
            podcastLanguageCode: podcastLanguageCode(forPodcastID: episode.podcastID),
            mode: adDetectionSettings.mode ?? .onDevice,
            remoteRunner: remoteTranscriptionRunner,
            remoteJobStore: remoteTranscription.store,
            remotePurchases: remoteTranscriptionPurchases,
            refreshSkipZones: { [weak self] in
                self?.zoneCountAfterPass(for: episode) ?? 0
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

    private func refreshPlaybackSkipZonesIfCurrentEpisode(episodeID: String) {
        guard playback.currentEpisode?.id.rawValue == episodeID else {
            return
        }

        refreshPlaybackSkipZonesForCurrentEpisode()
    }

    private func currentAdAnalysisZoneTiers(
        episodeID: String,
        duration: TimeInterval?
    ) -> EpisodeAdAnalysisZoneTiers {
        guard adAnalyses.record(for: episodeID)?.state == .completed,
              let transcriptDocument = transcriptions.document(for: episodeID),
              let analysisDocument = adAnalyses.document(for: episodeID),
              adAnalyses.isCurrentAnalysisDocument(analysisDocument, for: transcriptDocument)
        else {
            return .empty
        }

        return EpisodeAdAnalysisZoneMapper.zoneTiers(for: analysisDocument, duration: duration)
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
        guard let episodeID = storedLastPlaybackEpisodeID(modelContext: modelContext),
              let episode = library.episode(with: episodeID),
              library.canRestorePlayback(for: episode)
        else {
            return nil
        }

        return episode
    }

    private func rememberLastPlaybackEpisode(_ episodeID: String, modelContext: ModelContext) {
        if lastPlaybackEpisodeRecordCache?.value == episodeID {
            return
        }

        let record: LocalPreferenceRecord
        if let cachedRecord = lastPlaybackEpisodeRecordCache {
            record = cachedRecord
        } else if let existingRecord = lastPlaybackEpisodePreference(modelContext: modelContext) {
            lastPlaybackEpisodeRecordCache = existingRecord
            guard existingRecord.value != episodeID else {
                return
            }
            record = existingRecord
        } else {
            record = LocalPreferenceRecord(
                key: Self.lastPlaybackEpisodeIDKey,
                value: episodeID
            )
            modelContext.insert(record)
            lastPlaybackEpisodeRecordCache = record
        }

        record.value = episodeID
        record.updatedAt = .now
        try? modelContext.save()
    }

    private func clearLastPlaybackEpisode(modelContext: ModelContext) {
        lastPlaybackEpisodeRecordCache = nil
        let records = lastPlaybackEpisodePreferences(modelContext: modelContext)
        guard !records.isEmpty else {
            return
        }

        for record in records {
            modelContext.delete(record)
        }
        try? modelContext.save()
    }

    private func storedLastPlaybackEpisodeID(modelContext: ModelContext) -> String? {
        lastPlaybackEpisodePreference(modelContext: modelContext)?.value.trimmedNonEmpty
    }

    private func lastPlaybackEpisodePreference(modelContext: ModelContext) -> LocalPreferenceRecord? {
        lastPlaybackEpisodePreferences(modelContext: modelContext).first
    }

    private func lastPlaybackEpisodePreferences(modelContext: ModelContext) -> [LocalPreferenceRecord] {
        let key = Self.lastPlaybackEpisodeIDKey
        let descriptor = FetchDescriptor<LocalPreferenceRecord>(
            predicate: #Predicate<LocalPreferenceRecord> { record in
                record.key == key
            },
            sortBy: [SortDescriptor(\.updatedAt, order: .reverse)]
        )
        return (try? modelContext.fetch(descriptor)) ?? []
    }

    private func sanitizedPosition(_ position: TimeInterval, duration: TimeInterval?) -> TimeInterval {
        let lowerBounded = position.isFinite ? max(0, position) : 0
        guard let duration else {
            return lowerBounded
        }
        return min(lowerBounded, duration)
    }

    private func sanitizedDuration(_ duration: TimeInterval?) -> TimeInterval? {
        guard let duration, duration.isFinite, duration > 0 else {
            return nil
        }
        return duration
    }
}
