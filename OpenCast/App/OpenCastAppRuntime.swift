import Foundation
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
            // Read before the container opens, so the copy never depends on
            // what that open does to the playlist tables it no longer maps.
            let legacyLocalPlaylists = Self.legacyLocalPlaylists(launchConfiguration: launchConfiguration)
            modelContainer = try OpenCastModelContainerFactory.make(
                inMemory: launchConfiguration.usesInMemoryStore
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
                playback: playback,
                onboardingState: onboardingState,
                voiceBoostDiagnostics: voiceBoostDiagnostics,
                exposesVoiceBoostDiagnosticsStatus: launchConfiguration.exposesVoiceBoostDiagnosticsStatus,
                runsVoiceBoostDeviceProbe: launchConfiguration.runsVoiceBoostDeviceProbe,
                syncStatus: syncStatus,
                allowsAutomaticFeedRefresh: !launchConfiguration.usesInMemoryStore,
                adFreePassPresentationOverride: launchConfiguration.adFreePassPresentationOverride,
                adFreePassQueueOverride: launchConfiguration.adFreePassQueueOverride,
                legacyLocalPlaylists: legacyLocalPlaylists
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

    /// nil for an in-memory launch and once the copy has completed. A store
    /// with nothing to copy yields an empty snapshot so the migration records
    /// itself as done and later launches skip the file check. A failed read
    /// must never reach the launch's `fatalError`: it is logged, yields nil,
    /// and the next launch tries again.
    private static func legacyLocalPlaylists(
        launchConfiguration: OpenCastLaunchConfiguration
    ) -> LegacyLocalPlaylistSnapshot? {
        guard !launchConfiguration.usesInMemoryStore,
              !UserDefaults.standard.bool(forKey: PlaylistLocalStoreMigration.completedDefaultsKey)
        else {
            return nil
        }
        do {
            return try LegacyLocalPlaylistReader.read(storeURL: OpenCastModelContainerFactory.localStoreURL)
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
        for keychainService in AdAnalysisAppAttestKeychainServices.all {
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
