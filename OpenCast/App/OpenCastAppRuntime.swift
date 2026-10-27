import Foundation
import OpenCastAnalysis
import OpenCastAnalysisProviders
import OpenCastCore
import OpenCastPlayback
import OSLog
import SwiftData

final class OpenCastAppRuntime {
    static let shared = OpenCastAppRuntime()

    let launchConfiguration: OpenCastLaunchConfiguration
    let modelContainer: ModelContainer
    let appModel: OpenCastAppModel
    let performanceDiagnostics = PerformanceDiagnosticsService()

    private init() {
        SearchColdStartProbe.recordProcessStart()
        do {
            let launchConfiguration = OpenCastLaunchConfiguration.current
            self.launchConfiguration = launchConfiguration
            #if DEBUG || OPENCAST_PERFORMANCE_PROBES
            NowPlayingFramePacingProbe.shared.enableIfRequested()
            #endif
            #if DEBUG || INTERNAL_NOTIFICATIONS_DIAGNOSTICS
            if launchConfiguration.resetsAdAnalysisAppAttestCredential {
                try Self.deleteAdAnalysisAppAttestCredentials()
            }
            #endif
            let stores = Self.resolveModelStores(
                layout: .current(),
                usesInMemoryStore: launchConfiguration.usesInMemoryStore,
                relocate: { ModelStoreRelocation.relocate($0) },
                relocationLog: ModelStoreRelocationLog(),
                defaults: .standard
            )
            modelContainer = try OpenCastModelContainerFactory.make(
                inMemory: launchConfiguration.usesInMemoryStore,
                layout: stores.layout
            )
            // Seeds write cache data through the same store the app reads, so
            // harness data exercises upsertCache rather than the one-time
            // legacy import (finding 49).
            let inMemoryCacheStore = launchConfiguration.usesInMemoryStore
                ? SQLiteLocalLibraryCacheStore.inMemory()
                : nil
            if launchConfiguration.seedsUITestData, let inMemoryCacheStore {
                try OpenCastUITestSeedData.seed(
                    in: modelContainer,
                    cacheStore: inMemoryCacheStore,
                    includesCompletedDownload: launchConfiguration.seedsCompletedDownload,
                    includesFailedDownload: launchConfiguration.seedsFailedDownload,
                    includesEpisodeProgress: launchConfiguration.seedsEpisodeProgress,
                    includesCompletedTranscript: launchConfiguration.seedsCompletedTranscript,
                    includesCompletedAdAnalysis: launchConfiguration.seedsCompletedAdAnalysis,
                    includesAdAnalysisSpanAtStart: launchConfiguration.seedsAdAnalysisSpanAtStart
                )
            }
            #if DEBUG
            if launchConfiguration.seedsAppStoreScreenshotData, let inMemoryCacheStore {
                try AppStoreScreenshotSeedData.seed(
                    in: modelContainer,
                    cacheStore: inMemoryCacheStore
                )
            }
            #endif
            if launchConfiguration.seedsOnboardingCompleted {
                try OpenCastUITestSeedData.seedOnboardingCompleted(in: modelContainer)
            }
            if launchConfiguration.seedsAnalysisKeyNoticeSeen {
                try AnalysisUITestFixtures.seedKeyNoticeSeen(in: modelContainer)
            }
            if launchConfiguration.schedulesNotificationLookFixture {
                UITestNotificationLookFixtureScheduler.schedule()
            }
            if launchConfiguration.schedulesAdFreePassNotificationLookFixture {
                UITestAdFreePassNotificationLookFixtureScheduler.schedule()
            }
            #if DEBUG
            if launchConfiguration.schedulesAppStoreAdFreePassNotification {
                AppStoreScreenshotNotificationFixture.schedule()
            }
            if launchConfiguration.schedulesAppStoreEpisodeNotification {
                AppStoreScreenshotEpisodeNotificationFixture.schedule()
            }
            #endif
            let voiceBoostDiagnostics = launchConfiguration.capturesVoiceBoostDiagnostics
                ? VoiceBoostAudioTapDiagnostics()
                : nil
            let cacheController = OpenCastCacheController()
            let httpClient = URLSessionOpenCastHTTPClient(
                configuration: OpenCastURLSessionFactory.sharedConfiguration(
                    cacheDirectory: cacheController.httpCacheDirectory
                )
            )
            let playback = AVFoundationPlaybackController(
                voiceBoostTapDiagnostics: voiceBoostDiagnostics,
                nowPlayingArtworkLoader: SharedNowPlayingArtworkLoader()
            )
            let localLibraryCacheStore = Self.localLibraryCacheStore(
                launchConfiguration: launchConfiguration,
                inMemoryStore: inMemoryCacheStore
            )
            let library = Self.libraryStore(
                launchConfiguration: launchConfiguration,
                localCacheStore: localLibraryCacheStore
            )
            let onboardingState = OnboardingStateStore()
            let transcriptionModels = launchConfiguration.usesInMemoryStore
                ? TranscriptionModelStore(
                    installer: OpenCastUITestTranscriptionModelInstaller(
                        isInstalled: launchConfiguration.seedsTranscriptionModelInstalled
                    )
                )
                : TranscriptionModelStore()
            let syncStatus = Self.syncStatusStore(launchConfiguration: launchConfiguration)
            let appleSpeechAssets = Self.makeAppleSpeechAssetStore()
            let transcriptions = Self.transcriptionStore(launchConfiguration: launchConfiguration)
            appModel = OpenCastAppModel(
                cacheController: cacheController,
                httpClient: httpClient,
                library: library,
                localLibraryCacheStore: localLibraryCacheStore,
                transcriptionModels: transcriptionModels,
                appleSpeechAssets: appleSpeechAssets,
                transcriptions: transcriptions,
                transcriptIntelligence: Self.transcriptIntelligenceStore(launchConfiguration: launchConfiguration),
                analysisPolicy: Self.analysisPolicyStore(launchConfiguration: launchConfiguration),
                analysisKeys: Self.analysisKeyStore(launchConfiguration: launchConfiguration),
                analysisKeyNotice: AnalysisKeyNoticeStore(trialStatus: launchConfiguration.uiTestAnalysisTrialStatus),
                analysisKeyRequired: Self.analysisKeyRequiredPresenter(launchConfiguration: launchConfiguration),
                analysisKeyTester: Self.analysisKeyTester(launchConfiguration: launchConfiguration),
                analysisRuns: Self.analysisRunRecordStore(launchConfiguration: launchConfiguration),
                analysisTrialConnection: Self.analysisTrialConnection(launchConfiguration: launchConfiguration),
                analysisTransportFixture: launchConfiguration.uiTestAnalysisTransport,
                analysisContinuedTaskScheduler: launchConfiguration.uiTestChaptersSummarySession
                    .map(UITestAnalysisContinuedTaskScheduler.init(mode:)),
                analysisTrialStatusDefaults: Self.analysisTrialStatusDefaults(launchConfiguration: launchConfiguration),
                playback: playback,
                onboardingState: onboardingState,
                voiceBoostDiagnostics: voiceBoostDiagnostics,
                exposesVoiceBoostDiagnosticsStatus: launchConfiguration.exposesVoiceBoostDiagnosticsStatus,
                runsVoiceBoostDeviceProbe: launchConfiguration.runsVoiceBoostDeviceProbe,
                syncStatus: syncStatus,
                allowsAutomaticFeedRefresh: !launchConfiguration.usesInMemoryStore,
                adFreePassPresentationOverride: launchConfiguration.adFreePassPresentationOverride,
                adFreePassQueueOverride: launchConfiguration.adFreePassQueueOverride,
                uiTestSeededChapters: launchConfiguration.seedsChapters ? OpenCastUITestSeedData.seededChapters : nil,
                legacyLocalPlaylists: stores.legacyLocalPlaylists
            )
            #if DEBUG
            if launchConfiguration.seedsUITestData {
                UITestNowPlayingCompletionFixture.installIfRequested(
                    appModel: appModel,
                    modelContext: modelContainer.mainContext
                )
            }
            #endif
        } catch {
            fatalError("Unable to create OpenCast model container: \(error)")
        }
    }

    /// Everything that must happen before the container opens, in order: the
    /// relocation, one log line per store, then the legacy playlist read at
    /// the local URL the relocation resolved, so the read sees the file the
    /// container will open and never depends on what that open does to the
    /// playlist tables it no longer maps. An in-memory launch does none of it;
    /// its configurations never read the layout.
    static func resolveModelStores(
        layout: ModelStoreLayout,
        usesInMemoryStore: Bool,
        relocate: (ModelStoreLayout) -> (layout: ModelStoreLayout, results: [ModelStoreRelocationResult]),
        relocationLog: ModelStoreRelocationLog,
        defaults: UserDefaults
    ) -> (layout: ModelStoreLayout, legacyLocalPlaylists: LegacyLocalPlaylistSnapshot?) {
        guard !usesInMemoryStore else {
            return (layout, nil)
        }
        let relocation = relocate(layout)
        relocationLog.record(relocation.results)
        return (
            relocation.layout,
            legacyLocalPlaylists(storeURL: relocation.layout.localStoreURL, defaults: defaults)
        )
    }

    /// nil once the copy has completed. A store with nothing to copy yields an
    /// empty snapshot so the migration records itself as done and later
    /// launches skip the file check. A failed read must never reach the
    /// launch's `fatalError`: it is logged, yields nil, and the next launch
    /// tries again.
    private static func legacyLocalPlaylists(
        storeURL: URL,
        defaults: UserDefaults
    ) -> LegacyLocalPlaylistSnapshot? {
        guard !defaults.bool(forKey: PlaylistLocalStoreMigration.completedDefaultsKey) else {
            return nil
        }
        do {
            return try LegacyLocalPlaylistReader.read(storeURL: storeURL)
                ?? LegacyLocalPlaylistSnapshot()
        } catch {
            Logger(subsystem: "com.connor.opencast", category: "PlaylistMigration")
                .error("legacy playlist read failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    private static func transcriptIntelligenceStore(
        launchConfiguration: OpenCastLaunchConfiguration
    ) -> TranscriptIntelligenceStore {
        #if DEBUG
        if let availability = launchConfiguration.uiTestTranscriptIntelligenceAvailability {
            return TranscriptIntelligenceStore(
                client: UITestTranscriptIntelligenceClient(modelAvailability: availability)
            )
        }
        #endif
        return TranscriptIntelligenceStore()
    }

    // UI tests never reach the Keychain or the network: the keys live in
    // memory, the policy is a fixed variant and the key test answers at once.
    private static func analysisPolicyStore(
        launchConfiguration: OpenCastLaunchConfiguration
    ) -> AnalysisPolicySnapshotStore {
        guard launchConfiguration.usesInMemoryStore else {
            return .live()
        }
        return .fixed(launchConfiguration.uiTestAnalysisPolicy ?? .baked)
    }

    private static func analysisKeyStore(
        launchConfiguration: OpenCastLaunchConfiguration
    ) -> AnalysisProviderKeyStore {
        guard launchConfiguration.usesInMemoryStore else {
            return AnalysisProviderKeyStore(storage: KeychainAnalysisProviderKeyStorage())
        }
        let syncs = !launchConfiguration.seedsAnalysisKeysLocalOnly
        var seeded: [AnalysisProvider: (AnalysisProviderKey, syncs: Bool)] = [:]
        for provider in launchConfiguration.seededAnalysisKeyProviders {
            seeded[provider] = (AnalysisUITestFixtures.key(for: provider), syncs: syncs)
        }
        let fault = launchConfiguration.uiTestAnalysisKeyStorageFailures
            .map(AnalysisUITestFixtures.keyStorageFault(failing:))
        return AnalysisProviderKeyStore(storage: InMemoryAnalysisProviderKeyStorage(seeded: seeded, fault: fault))
    }

    private static func analysisKeyRequiredPresenter(
        launchConfiguration: OpenCastLaunchConfiguration
    ) -> AnalysisKeyRequiredPresenter {
        let presenter = AnalysisKeyRequiredPresenter()
        if let feature = launchConfiguration.uiTestAnalysisKeyRequiredFeature {
            presenter.present(
                feature: feature,
                trialStatus: launchConfiguration.uiTestAnalysisTrialStatus ?? .exhausted
            )
        }
        return presenter
    }

    /// UI tests keep run records in a directory of their own launch.
    private static func analysisRunRecordStore(launchConfiguration: OpenCastLaunchConfiguration) -> AnalysisRunRecordStore {
        guard launchConfiguration.usesInMemoryStore else { return AnalysisRunRecordStore() }
        return AnalysisRunRecordStore(
            directory: FileManager.default.temporaryDirectory.appending(path: "AnalysisRuns-\(UUID().uuidString)", directoryHint: .isDirectory)
        )
    }

    /// UI tests cache the trial status in a suite of their own launch, so a
    /// status an earlier launch read never outlives it.
    private static func analysisTrialStatusDefaults(launchConfiguration: OpenCastLaunchConfiguration) -> UserDefaults {
        guard launchConfiguration.usesInMemoryStore,
              let suite = UserDefaults(suiteName: "opencast.uitest.trial-status.\(UUID().uuidString)")
        else {
            return .standard
        }
        return suite
    }

    /// UI tests answer the trial status from the seeded one and never reach
    /// the trial service.
    private static func analysisTrialConnection(launchConfiguration: OpenCastLaunchConfiguration) -> AnalysisTrialConnection {
        guard launchConfiguration.usesInMemoryStore else { return AnalysisTrialConnection() }
        let trial = (launchConfiguration.uiTestAnalysisPolicy ?? .baked).bundle.trial
        let status: AnalysisTrialProxyStatus = switch launchConfiguration.uiTestAnalysisTrialStatus {
        case .unitsLeft(let units)?:
            AnalysisTrialProxyStatus(mode: .trial, unitsRemaining: max(units, 0), startsAt: trial.startsAt, monthPaused: false)
        case .exhausted?:
            AnalysisTrialProxyStatus(mode: .trial, unitsRemaining: 0, startsAt: trial.startsAt, monthPaused: false)
        case .notStarted?, nil:
            AnalysisTrialProxyStatus(mode: .open, unitsRemaining: trial.lifetimeUnits, startsAt: trial.startsAt, monthPaused: false)
        }
        return AnalysisTrialConnection(fixtureStatus: status, isFixture: true)
    }

    private static func analysisKeyTester(
        launchConfiguration: OpenCastLaunchConfiguration
    ) -> any AnalysisKeyTesting {
        guard launchConfiguration.usesInMemoryStore else {
            return AnalysisProviderKeyTester()
        }
        return FixedAnalysisKeyTester(
            results: launchConfiguration.uiTestAnalysisKeyTestResults ?? [.accepted],
            delay: .milliseconds(launchConfiguration.uiTestAnalysisKeyTestDelayMilliseconds ?? 0),
            gate: launchConfiguration.uiTestAnalysisKeyTestGated ? AnalysisKeyTestReleaseGate() : nil
        )
    }

    private static func makeAppleSpeechAssetStore() -> AppleSpeechAssetStore {
        #if DEBUG
        if let forcedProvider = DebugForcedAppleSpeechAssetProvider.requestedProvider {
            return AppleSpeechAssetStore(provider: forcedProvider)
        }
        #endif
        return AppleSpeechAssetStore()
    }

    private static func transcriptionStore(
        launchConfiguration: OpenCastLaunchConfiguration
    ) -> EpisodeTranscriptionStore {
        #if DEBUG
        if launchConfiguration.completesTranscriptRequestsForUITesting {
            return EpisodeTranscriptionStore(
                transcriber: OpenCastUITestCompletingEpisodeTranscriber()
            )
        }
        #endif
        return EpisodeTranscriptionStore()
    }

    #if DEBUG || INTERNAL_NOTIFICATIONS_DIAGNOSTICS
    private static func deleteAdAnalysisAppAttestCredentials() throws {
        for keychainService in AdAnalysisAppAttestKeychainServices.all + TrialProxyAppAttestKeychainServices.all {
            try AppAttestKeychain(service: keychainService).deleteAll()
        }
    }
    #endif

    private static func localLibraryCacheStore(
        launchConfiguration: OpenCastLaunchConfiguration,
        inMemoryStore: SQLiteLocalLibraryCacheStore?
    ) -> (any LocalLibraryCacheStore)? {
        if let databaseURL = SearchColdStartProbe.dedicatedDatabaseURL {
            return SQLiteLocalLibraryCacheStore(databaseURL: databaseURL)
        }
        guard let inMemoryStore else {
            return nil
        }

        #if DEBUG
        if let delayMilliseconds = launchConfiguration.uiTestLibraryLoadDelayMilliseconds {
            return UITestDelayedLocalLibraryCacheStore(
                base: inMemoryStore,
                loadDelay: .milliseconds(delayMilliseconds)
            )
        }
        #endif
        return inMemoryStore
    }

    private static func libraryStore(
        launchConfiguration: OpenCastLaunchConfiguration,
        localCacheStore: (any LocalLibraryCacheStore)?
    ) -> LibraryStore? {
        guard let localCacheStore else {
            return nil
        }
        let feedService: any FeedService
        if let failureCode = launchConfiguration.uiTestFeedTransportFailure {
            feedService = OpenCastUITestFeedTransportFailureService(code: failureCode)
        } else if launchConfiguration.usesUITestSeedFeedRefreshService {
            feedService = OpenCastUITestSeedFeedRefreshService()
        } else {
            return nil
        }
        return LibraryStore(feedService: feedService, localCache: localCacheStore)
    }

    private static func syncStatusStore(
        launchConfiguration: OpenCastLaunchConfiguration
    ) -> SyncStatusStore {
        #if DEBUG
        if let status = launchConfiguration.uiTestCloudKitAccountStatus {
            return SyncStatusStore(
                accountStatusProvider: OpenCastUITestCloudKitAccountStatusProvider(
                    status: status,
                    delay: .milliseconds(launchConfiguration.uiTestCloudKitAccountStatusDelayMilliseconds ?? 0)
                ),
                accountStatusPatience: launchConfiguration.uiTestCloudKitAccountStatusPatienceMilliseconds
                    .map { .milliseconds($0) } ?? SyncStatusStore.defaultAccountStatusPatience
            )
        }
        #endif
        return SyncStatusStore()
    }
}
