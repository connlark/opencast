import Foundation
import OpenCastCore
import OpenCastPlayback
import SwiftData

final class OpenCastAppRuntime {
    static let shared = OpenCastAppRuntime()

    let launchConfiguration: OpenCastLaunchConfiguration
    let modelContainer: ModelContainer
    let appModel: OpenCastAppModel

    private init() {
        do {
            let launchConfiguration = OpenCastLaunchConfiguration.current
            self.launchConfiguration = launchConfiguration
            #if DEBUG
            NowPlayingFramePacingProbe.shared.enableIfRequested()
            #endif
            #if DEBUG || INTERNAL_NOTIFICATIONS_DIAGNOSTICS
            if launchConfiguration.resetsAdAnalysisAppAttestCredential {
                try Self.deleteAdAnalysisAppAttestCredentials()
            }
            #endif
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
            let podcastDirectoryService = ITunesPodcastDirectoryService(httpClient: httpClient)
            let playback = AVFoundationPlaybackController(
                voiceBoostTapDiagnostics: voiceBoostDiagnostics,
                nowPlayingArtworkLoader: SharedNowPlayingArtworkLoader()
            )
            let localLibraryCacheStore = Self.localLibraryCacheStore(
                launchConfiguration: launchConfiguration,
                inMemoryStore: inMemoryCacheStore
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
                localLibraryCacheStore: localLibraryCacheStore,
                transcriptionModels: transcriptionModels,
                appleSpeechAssets: appleSpeechAssets,
                transcriptions: transcriptions,
                playback: playback,
                onboardingState: onboardingState,
                voiceBoostDiagnostics: voiceBoostDiagnostics,
                exposesVoiceBoostDiagnosticsStatus: launchConfiguration.exposesVoiceBoostDiagnosticsStatus,
                runsVoiceBoostDeviceProbe: launchConfiguration.runsVoiceBoostDeviceProbe,
                podcastDirectoryService: podcastDirectoryService,
                syncStatus: syncStatus,
                allowsAutomaticFeedRefresh: !launchConfiguration.usesInMemoryStore,
                adFreePassPresentationOverride: launchConfiguration.adFreePassPresentationOverride
            )
        } catch {
            fatalError("Unable to create OpenCast model container: \(error)")
        }
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

    private static func syncStatusStore(
        launchConfiguration: OpenCastLaunchConfiguration
    ) -> SyncStatusStore {
        #if DEBUG
        if let status = launchConfiguration.uiTestCloudKitAccountStatus {
            return SyncStatusStore(
                accountStatusProvider: OpenCastUITestCloudKitAccountStatusProvider(status: status)
            )
        }
        #endif
        return SyncStatusStore()
    }
}
