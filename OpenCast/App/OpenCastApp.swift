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
            modelContainer = try OpenCastModelContainerFactory.make(
                inMemory: launchConfiguration.usesInMemoryStore
            )
            if launchConfiguration.seedsUITestData {
                try OpenCastUITestSeedData.seed(
                    in: modelContainer,
                    includesCompletedDownload: launchConfiguration.seedsCompletedDownload,
                    includesEpisodeProgress: launchConfiguration.seedsEpisodeProgress
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
            if launchConfiguration.seedsNotificationPromoBannerResolved {
                try OpenCastUITestSeedData.seedNotificationPromoBannerResolved(in: modelContainer)
            }
            if launchConfiguration.schedulesNotificationLookFixture {
                UITestNotificationLookFixtureScheduler.schedule()
            }
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
            _appModel = State(initialValue: OpenCastAppModel(
                cacheController: cacheController,
                httpClient: httpClient,
                localLibraryCacheStore: localLibraryCacheStore,
                playback: playback,
                onboardingState: onboardingState,
                voiceBoostDiagnostics: voiceBoostDiagnostics,
                exposesVoiceBoostDiagnosticsStatus: launchConfiguration.exposesVoiceBoostDiagnosticsStatus,
                runsVoiceBoostDeviceProbe: launchConfiguration.runsVoiceBoostDeviceProbe,
                podcastDirectoryService: podcastDirectoryService,
                allowsAutomaticFeedRefresh: !launchConfiguration.usesInMemoryStore
            ))
        } catch {
            fatalError("Unable to create OpenCast model container: \(error)")
        }
    }

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
}
