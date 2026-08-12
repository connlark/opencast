import Foundation

struct OpenCastLaunchConfiguration {
    static let seedVoiceBoostModeEnvironmentKey = "OPENCAST_SEED_VOICE_BOOST_MODE"

    var usesInMemoryStore: Bool
    var seedsUITestData: Bool
    var seedsAppStoreScreenshotData: Bool
    var seedsCompletedDownload: Bool
    var seedsFailedDownload: Bool
    var seedsTranscriptionModelInstalled: Bool
    var seedsCompletedTranscript: Bool
    var completesTranscriptRequestsForUITesting: Bool
    var seedsCompletedAdAnalysis: Bool
    var seedsAdAnalysisSpanAtStart: Bool
    var seedsEpisodeProgress: Bool
    var forcedAppearance: ForcedAppearance
    var capturesVoiceBoostDiagnostics: Bool
    var exposesVoiceBoostDiagnosticsStatus: Bool
    var runsVoiceBoostDeviceProbe: Bool
    var forcesOnboarding: Bool
    var seedsOnboardingCompleted: Bool
    var schedulesNotificationLookFixture: Bool
    var schedulesAdFreePassNotificationLookFixture: Bool
    var schedulesAppStoreAdFreePassNotification: Bool
    var resetsAdAnalysisAppAttestCredential: Bool
    var adFreePassPresentationOverride: EpisodeAdFreePassPresentation?
    var uiTestLibraryLoadDelayMilliseconds: Int?
    var uiTestCloudKitAccountStatus: SyncAccountStatus?
    var usesUITestSeedFeedRefreshService: Bool
    // Search cold-start probe flags are Release-capable benchmark seams, so
    // unlike the seams above they are deliberately not gated on UI testing.
    var runsSearchColdStartProbe = false
    var seedsSearchColdStartCorpus = false
    var disablesSearchIndexPreparation = false
    var searchColdStartProbeLabel: String?

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
        let searchColdStartProbeLabel = BenchmarkHarnessSupport.argumentValue(
            from: arguments,
            flag: SearchColdStartProbe.labelArgument
        )
        let arguments = Set(arguments)
        let isUITesting = arguments.contains("--opencast-ui-testing")
            || environment["OPENCAST_UI_TESTING"] == "1"
        let shouldSeedUITestData = arguments.contains("--opencast-seed-ui-library")
            || environment["OPENCAST_SEED_UI_LIBRARY"] == "1"
        let shouldSeedAppStoreScreenshotData = arguments.contains("--opencast-seed-app-store-screenshots")
            || environment["OPENCAST_SEED_APP_STORE_SCREENSHOTS"] == "1"
        let shouldSeedCompletedDownload = arguments.contains("--opencast-seed-completed-download")
            || environment["OPENCAST_SEED_COMPLETED_DOWNLOAD"] == "1"
        let shouldSeedFailedDownload = arguments.contains("--opencast-seed-failed-download")
            || environment["OPENCAST_SEED_FAILED_DOWNLOAD"] == "1"
        let shouldSeedTranscriptionModelInstalled = arguments.contains("--opencast-seed-transcription-model")
            || environment["OPENCAST_SEED_TRANSCRIPTION_MODEL"] == "1"
        let shouldSeedCompletedTranscript = arguments.contains("--opencast-seed-completed-transcript")
            || environment["OPENCAST_SEED_COMPLETED_TRANSCRIPT"] == "1"
        let shouldCompleteTranscriptRequests =
            arguments.contains("--opencast-complete-transcript-requests")
            || environment["OPENCAST_UI_TEST_COMPLETE_TRANSCRIPT_REQUESTS"] == "1"
        let shouldSeedCompletedAdAnalysis = arguments.contains("--opencast-seed-completed-ad-analysis")
            || environment["OPENCAST_SEED_COMPLETED_AD_ANALYSIS"] == "1"
        let shouldSeedAdAnalysisSpanAtStart = arguments.contains("--opencast-seed-ad-analysis-span-at-start")
            || environment["OPENCAST_SEED_AD_ANALYSIS_SPAN_AT_START"] == "1"
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
        let shouldScheduleNotificationLookFixture = arguments.contains("--opencast-schedule-notification-look-fixture")
            || environment["OPENCAST_SCHEDULE_NOTIFICATION_LOOK_FIXTURE"] == "1"
        let shouldScheduleAdFreePassNotificationLookFixture =
            arguments.contains("--opencast-schedule-adfreepass-notification-look-fixture")
            || environment["OPENCAST_SCHEDULE_ADFREEPASS_NOTIFICATION_LOOK_FIXTURE"] == "1"
        let shouldScheduleAppStoreAdFreePassNotification =
            arguments.contains("--opencast-schedule-app-store-adfreepass-notification")
            || environment["OPENCAST_SCHEDULE_APP_STORE_ADFREEPASS_NOTIFICATION"] == "1"
        let shouldResetAdAnalysisAppAttestCredential = environment["OPENCAST_RESET_AD_ANALYSIS_APP_ATTEST_CREDENTIAL"] == "1"
        let adFreePassPresentationOverride = isUITesting
            ? OpenCastUITestAdFreePassPresentationOverride.resolve(environment: environment)
            : nil
        let uiTestLibraryLoadDelayMilliseconds = isUITesting
            ? Self.uiTestLibraryLoadDelayMilliseconds(environment: environment)
            : nil
        let uiTestCloudKitAccountStatus = isUITesting
            ? Self.uiTestCloudKitAccountStatus(environment: environment)
            : nil
        let usesUITestSeedFeedRefreshService = isUITesting
            && environment["OPENCAST_UI_TEST_REFRESH_SEED_FEED"] == "1"
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
            seedsFailedDownload: isUITesting && shouldSeedFailedDownload,
            seedsTranscriptionModelInstalled: isUITesting && shouldSeedTranscriptionModelInstalled,
            seedsCompletedTranscript: isUITesting && shouldSeedCompletedTranscript,
            completesTranscriptRequestsForUITesting: isUITesting && shouldCompleteTranscriptRequests,
            seedsCompletedAdAnalysis: isUITesting && shouldSeedCompletedAdAnalysis,
            seedsAdAnalysisSpanAtStart: isUITesting && shouldSeedAdAnalysisSpanAtStart,
            seedsEpisodeProgress: isUITesting && shouldSeedEpisodeProgress,
            forcedAppearance: forcedAppearance,
            capturesVoiceBoostDiagnostics: capturesVoiceBoostDiagnostics,
            exposesVoiceBoostDiagnosticsStatus: exposesVoiceBoostDiagnosticsStatus,
            runsVoiceBoostDeviceProbe: runsVoiceBoostDeviceProbe,
            forcesOnboarding: isUITesting && shouldForceOnboarding,
            seedsOnboardingCompleted: isUITesting && !shouldForceOnboarding,
            schedulesNotificationLookFixture: isUITesting && shouldScheduleNotificationLookFixture,
            schedulesAdFreePassNotificationLookFixture: isUITesting
                && shouldScheduleAdFreePassNotificationLookFixture,
            schedulesAppStoreAdFreePassNotification: isUITesting
                && shouldScheduleAppStoreAdFreePassNotification,
            resetsAdAnalysisAppAttestCredential: isUITesting && shouldResetAdAnalysisAppAttestCredential,
            adFreePassPresentationOverride: adFreePassPresentationOverride,
            uiTestLibraryLoadDelayMilliseconds: uiTestLibraryLoadDelayMilliseconds,
            uiTestCloudKitAccountStatus: uiTestCloudKitAccountStatus,
            usesUITestSeedFeedRefreshService: usesUITestSeedFeedRefreshService,
            runsSearchColdStartProbe: arguments.contains(
                SearchColdStartProbe.probeArgument
            ),
            seedsSearchColdStartCorpus: arguments.contains(
                SearchColdStartProbe.seedArgument
            ),
            disablesSearchIndexPreparation: arguments.contains(
                SearchColdStartProbe.disablePreparationArgument
            ),
            searchColdStartProbeLabel: searchColdStartProbeLabel
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

    private static func uiTestCloudKitAccountStatus(environment: [String: String]) -> SyncAccountStatus? {
        guard let rawValue = environment["OPENCAST_UI_TEST_CLOUDKIT_ACCOUNT_STATUS"]?.lowercased()
        else {
            return nil
        }

        switch rawValue {
        case "available":
            return .available
        case "noaccount", "no-account", "no_account":
            return .noAccount
        case "restricted":
            return .restricted
        case "couldnotdetermine", "could-not-determine", "could_not_determine":
            return .couldNotDetermine
        case "temporarilyunavailable", "temporarily-unavailable", "temporarily_unavailable":
            return .temporarilyUnavailable("UI test iCloud account status override.")
        default:
            return nil
        }
    }
}
