import Foundation

struct OpenCastLaunchConfiguration {
    static let seedVoiceBoostModeEnvironmentKey = "OPENCAST_SEED_VOICE_BOOST_MODE"

    var usesInMemoryStore: Bool
    var seedsUITestData: Bool
    var seedsAppStoreScreenshotData: Bool
    var seedsCompletedDownload: Bool
    var seedsEpisodeProgress: Bool
    var forcedAppearance: ForcedAppearance
    var capturesVoiceBoostDiagnostics: Bool
    var exposesVoiceBoostDiagnosticsStatus: Bool
    var runsVoiceBoostDeviceProbe: Bool
    var seedsOnboardingCompleted: Bool
    var uiTestLibraryLoadDelayMilliseconds: Int?

    static var current: OpenCastLaunchConfiguration {
        let processInfo = ProcessInfo.processInfo
        return resolving(
            arguments: processInfo.arguments,
            environment: processInfo.environment
        )
    }

    static func resolving(
        arguments: [String],
        environment: [String: String]
    ) -> OpenCastLaunchConfiguration {
        let arguments = Set(arguments)
        let isUITesting = arguments.contains("--opencast-ui-testing")
            || environment["OPENCAST_UI_TESTING"] == "1"
        let shouldSeedUITestData = arguments.contains("--opencast-seed-ui-library")
            || environment["OPENCAST_SEED_UI_LIBRARY"] == "1"
        let shouldSeedAppStoreScreenshotData = arguments.contains("--opencast-seed-app-store-screenshots")
            || environment["OPENCAST_SEED_APP_STORE_SCREENSHOTS"] == "1"
        let shouldSeedCompletedDownload = arguments.contains("--opencast-seed-completed-download")
            || environment["OPENCAST_SEED_COMPLETED_DOWNLOAD"] == "1"
        let shouldSeedEpisodeProgress = arguments.contains("--opencast-seed-episode-progress")
            || environment["OPENCAST_SEED_EPISODE_PROGRESS"] == "1"
        let shouldForceDarkAppearance = arguments.contains("--opencast-force-dark-mode")
            || environment["OPENCAST_FORCE_DARK_MODE"] == "1"
        let shouldForceLightAppearance = arguments.contains("--opencast-force-light-mode")
            || environment["OPENCAST_FORCE_LIGHT_MODE"] == "1"
        let shouldCaptureVoiceBoostDiagnostics = arguments.contains("--opencast-capture-voiceboost-diagnostics")
            || environment["OPENCAST_CAPTURE_VOICEBOOST_DIAGNOSTICS"] == "1"
        let shouldRunVoiceBoostDeviceProbe = arguments.contains("--opencast-run-voiceboost-device-probe")
            || environment["OPENCAST_RUN_VOICEBOOST_DEVICE_PROBE"] == "1"
        let shouldForceOnboarding = arguments.contains("--opencast-force-onboarding")
            || environment["OPENCAST_FORCE_ONBOARDING"] == "1"
        let uiTestLibraryLoadDelayMilliseconds = isUITesting
            ? Self.uiTestLibraryLoadDelayMilliseconds(environment: environment)
            : nil
        #if DEBUG
        let runsVoiceBoostDeviceProbe = shouldRunVoiceBoostDeviceProbe
        let capturesVoiceBoostDiagnostics = shouldCaptureVoiceBoostDiagnostics || runsVoiceBoostDeviceProbe
        let exposesVoiceBoostDiagnosticsStatus = isUITesting && capturesVoiceBoostDiagnostics
        #else
        let runsVoiceBoostDeviceProbe = false
        let capturesVoiceBoostDiagnostics = isUITesting && shouldCaptureVoiceBoostDiagnostics
        let exposesVoiceBoostDiagnosticsStatus = isUITesting && capturesVoiceBoostDiagnostics
        #endif
        let forcedAppearance = isUITesting
            ? ForcedAppearance.resolving(
                dark: shouldForceDarkAppearance,
                light: shouldForceLightAppearance
            )
            : .system

        return OpenCastLaunchConfiguration(
            usesInMemoryStore: isUITesting,
            seedsUITestData: isUITesting && shouldSeedUITestData,
            seedsAppStoreScreenshotData: isUITesting && shouldSeedAppStoreScreenshotData,
            seedsCompletedDownload: isUITesting && shouldSeedCompletedDownload,
            seedsEpisodeProgress: isUITesting && shouldSeedEpisodeProgress,
            forcedAppearance: forcedAppearance,
            capturesVoiceBoostDiagnostics: capturesVoiceBoostDiagnostics,
            exposesVoiceBoostDiagnosticsStatus: exposesVoiceBoostDiagnosticsStatus,
            runsVoiceBoostDeviceProbe: runsVoiceBoostDeviceProbe,
            seedsOnboardingCompleted: isUITesting && !shouldForceOnboarding,
            uiTestLibraryLoadDelayMilliseconds: uiTestLibraryLoadDelayMilliseconds
        )
    }

    private static func uiTestLibraryLoadDelayMilliseconds(environment: [String: String]) -> Int? {
        guard let rawValue = environment["OPENCAST_UI_TEST_LIBRARY_LOAD_DELAY_MILLISECONDS"],
              let milliseconds = Int(rawValue),
              milliseconds > 0
        else {
            return nil
        }

        return milliseconds
    }
}
