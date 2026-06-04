import SwiftData
import SwiftUI
import OpenCastCore
import OpenCastPlayback

@main
struct OpenCastApp: App {
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
            _appModel = State(initialValue: OpenCastAppModel(
                cacheController: cacheController,
                httpClient: httpClient,
                playback: playback,
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
}
