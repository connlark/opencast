import SwiftData
import SwiftUI
import OpenCastCore
import OpenCastPlayback

@main
struct OpenCastApp: App {
    @UIApplicationDelegateAdaptor(OpenCastAppDelegate.self) private var appDelegate

    private let launchConfiguration: OpenCastLaunchConfiguration
    private let modelContainer: ModelContainer
    @State private var appModel: OpenCastAppModel

    init() {
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
            if launchConfiguration.seedsUITestData {
                try OpenCastUITestSeedData.seed(
                    in: modelContainer,
                    includesCompletedDownload: launchConfiguration.seedsCompletedDownload,
                    includesFailedDownload: launchConfiguration.seedsFailedDownload,
                    includesEpisodeProgress: launchConfiguration.seedsEpisodeProgress,
                    includesCompletedTranscript: launchConfiguration.seedsCompletedTranscript,
                    includesCompletedAdAnalysis: launchConfiguration.seedsCompletedAdAnalysis,
                    includesAdAnalysisSpanAtStart: launchConfiguration.seedsAdAnalysisSpanAtStart
                )
            }
            #if DEBUG
            if launchConfiguration.seedsAppStoreScreenshotData {
                try AppStoreScreenshotSeedData.seed(in: modelContainer)
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
                launchConfiguration: launchConfiguration
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
            _appModel = State(initialValue: OpenCastAppModel(
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
            ))
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

    var body: some Scene {
        WindowGroup {
            OpenCastRootView()
                .environment(appModel)
                .modelContainer(modelContainer)
                .preferredColorScheme(preferredColorScheme)
        }
    }

    private var preferredColorScheme: ColorScheme? {
        switch launchConfiguration.forcedAppearance {
        case .system:
            userPreferredColorScheme
        case .dark:
            .dark
        case .light:
            .light
        }
    }

    private var userPreferredColorScheme: ColorScheme? {
        switch appModel.appearanceSettings.mode {
        case .system:
            nil
        case .dark:
            .dark
        case .light:
            .light
        }
    }

    private static func localLibraryCacheStore(
        launchConfiguration: OpenCastLaunchConfiguration
    ) -> (any LocalLibraryCacheStore)? {
        guard launchConfiguration.usesInMemoryStore else {
            return nil
        }

        let cacheStore = SQLiteLocalLibraryCacheStore.inMemory()
        #if DEBUG
        if let delayMilliseconds = launchConfiguration.uiTestLibraryLoadDelayMilliseconds {
            return UITestDelayedLocalLibraryCacheStore(
                base: cacheStore,
                loadDelay: .milliseconds(delayMilliseconds)
            )
        }
        #endif
        return cacheStore
    }

    private static func syncStatusStore(launchConfiguration: OpenCastLaunchConfiguration) -> SyncStatusStore {
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
