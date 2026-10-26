import Foundation
import OpenCastAnalysis
import OpenCastAnalysisProviders

struct OpenCastLaunchConfiguration {
    static let seedVoiceBoostModeEnvironmentKey = "OPENCAST_SEED_VOICE_BOOST_MODE"

    var usesInMemoryStore: Bool
    var seedsUITestData: Bool
    var seedsAppStoreScreenshotData: Bool
    var seedsCompletedDownload: Bool
    var seedsChapters: Bool
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
    var schedulesAppStoreEpisodeNotification: Bool
    var resetsAdAnalysisAppAttestCredential: Bool
    var adFreePassPresentationOverride: EpisodeAdFreePassPresentation?
    var adFreePassQueueOverride: AdFreePassQueueUITestOverride?
    /// UI-test seam: scripts PCC eligibility so the recap entries and the
    /// sheet's unavailable state can be exercised on a simulator.
    var uiTestTranscriptIntelligenceAvailability: TranscriptIntelligenceModelAvailability?
    /// App Store screenshot pins: keep the "Skipped promo" pill on screen, and
    /// seed the Sound Lab reveal at a fixed progress for a mid-slide still.
    var pinsAppStoreAutoSkipPill: Bool
    var appStoreSoundLabRevealProgress: Double?
    var uiTestLibraryLoadDelayMilliseconds: Int?
    var uiTestCloudKitAccountStatus: SyncAccountStatus?
    /// UI-test seam: holds the fixed account status back, so a test can show
    /// what the app does while a slow iCloud account check is outstanding.
    var uiTestCloudKitAccountStatusDelayMilliseconds: Int?
    /// UI-test seam: replaces how long launch work waits for that answer.
    var uiTestCloudKitAccountStatusPatienceMilliseconds: Int?
    var usesUITestSeedFeedRefreshService: Bool
    /// UI-test seam: every feed fetch fails with this transport error.
    var uiTestFeedTransportFailure: URLError.Code?
    /// UI-test seams for AI Services: the providers whose fixture key the
    /// in-memory key storage holds (synced unless local-only), the policy
    /// variant, the trial status, the key test's answer and a key screen
    /// presented at launch.
    var seededAnalysisKeyProviders: [AnalysisProvider]
    var seedsAnalysisKeysLocalOnly: Bool
    var uiTestAnalysisPolicy: AnalysisPolicySnapshot?
    var uiTestAnalysisTrialStatus: AnalysisTrialStatus?
    /// The key test's answers: call n answers the n-th (the last repeats).
    var uiTestAnalysisKeyTestResults: [AnalysisKeyTestResult]?
    /// How long the key test takes to answer, so a test can change the draft
    /// while it runs.
    var uiTestAnalysisKeyTestDelayMilliseconds: Int?
    /// Each key test waits until the UI test releases it
    /// (`AnalysisKeyTestReleaseGate`).
    var uiTestAnalysisKeyTestGated: Bool
    /// Keychain calls the in-memory key storage fails, each once: turning
    /// sync off can stop after its local write, a replacement key's write
    /// can fail.
    var uiTestAnalysisKeyStorageFailures: [AnalysisUITestFixtures.KeyStorageFailure]?
    var uiTestAnalysisKeyRequiredFeature: AnalysisFeature?
    /// How the fixture transport answers analysis runs; every UI-test run
    /// uses it, `fixture` unless a test picks a failure.
    var uiTestAnalysisTransport: AnalysisUITestTransportMode?
    /// The Chapters & Summary card: armed at once, or refused; `nil` uses
    /// the system scheduler.
    var uiTestChaptersSummarySession: UITestAnalysisContinuedTaskScheduler.Mode?
    /// Seen unless a test forces the notice, so the Detect Ads and Generate
    /// flows run as before.
    var seedsAnalysisKeyNoticeSeen: Bool
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
        let analysisPolicyVariant = BenchmarkHarnessSupport.argumentValue(
            from: arguments,
            flag: "--opencast-seed-analysis-policy"
        )
        let analysisTrialStatus = BenchmarkHarnessSupport.argumentValue(
            from: arguments,
            flag: "--opencast-seed-analysis-trial"
        )
        let analysisKeyTestResult = BenchmarkHarnessSupport.argumentValue(
            from: arguments,
            flag: "--opencast-seed-analysis-key-test"
        )
        let analysisKeyTestDelay = BenchmarkHarnessSupport.argumentValue(
            from: arguments,
            flag: "--opencast-seed-analysis-key-test-delay-ms"
        )
        let analysisKeyStorageFailures = BenchmarkHarnessSupport.argumentValue(
            from: arguments,
            flag: "--opencast-seed-analysis-key-faults"
        )
        let analysisTransportAnswer = BenchmarkHarnessSupport.argumentValue(
            from: arguments,
            flag: "--opencast-ui-test-analysis-transport"
        ) ?? environment["OPENCAST_UI_TEST_ANALYSIS_TRANSPORT"]
        let analysisKeyRequiredFeature = BenchmarkHarnessSupport.argumentValue(
            from: arguments,
            flag: "--opencast-present-analysis-key-required"
        )
        let chaptersSummarySession = BenchmarkHarnessSupport.argumentValue(
            from: arguments,
            flag: "--opencast-ui-test-chapters-session"
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
        let shouldSeedChapters = environment["OPENCAST_SEED_CHAPTERS"] == "1"
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
        let shouldScheduleAppStoreEpisodeNotification =
            arguments.contains("--opencast-schedule-app-store-episode-notification")
            || environment["OPENCAST_SCHEDULE_APP_STORE_EPISODE_NOTIFICATION"] == "1"
        let shouldPinAppStoreAutoSkipPill = arguments.contains("--opencast-pin-app-store-autoskip-pill")
            || environment["OPENCAST_PIN_APP_STORE_AUTOSKIP_PILL"] == "1"
        let shouldSeedGoogleAnalysisKey = arguments.contains("--opencast-seed-analysis-key-google")
            || environment["OPENCAST_SEED_ANALYSIS_KEY_GOOGLE"] == "1"
        let shouldSeedOpenAIAnalysisKey = arguments.contains("--opencast-seed-analysis-key-openai")
            || environment["OPENCAST_SEED_ANALYSIS_KEY_OPENAI"] == "1"
        let shouldSeedAnalysisKeysLocalOnly = arguments.contains("--opencast-seed-analysis-keys-local-only")
            || environment["OPENCAST_SEED_ANALYSIS_KEYS_LOCAL_ONLY"] == "1"
        let holdsAnalysisTransport = arguments.contains("--opencast-ui-test-analysis-transport-hold")
            || environment["OPENCAST_UI_TEST_ANALYSIS_TRANSPORT_HOLD"] == "1"
        let shouldForceAnalysisKeyNotice = arguments.contains("--opencast-force-analysis-key-notice")
            || environment["OPENCAST_FORCE_ANALYSIS_KEY_NOTICE"] == "1"
        let shouldGateAnalysisKeyTest = arguments.contains("--opencast-seed-analysis-key-test-gated")
        let seededAnalysisKeyProviders: [AnalysisProvider] = isUITesting
            ? AnalysisProvider.allCases.filter { provider in
                switch provider {
                case .google: shouldSeedGoogleAnalysisKey
                case .openai: shouldSeedOpenAIAnalysisKey
                }
            }
            : []
        let appStoreSoundLabRevealProgress = isUITesting
            ? environment["OPENCAST_PIN_APP_STORE_SOUND_LAB_REVEAL"].flatMap(Double.init)
            : nil
        let shouldResetAdAnalysisAppAttestCredential = environment["OPENCAST_RESET_AD_ANALYSIS_APP_ATTEST_CREDENTIAL"] == "1"
        let adFreePassPresentationOverride = isUITesting
            ? OpenCastUITestAdFreePassPresentationOverride.resolve(environment: environment)
            : nil
        let adFreePassQueueOverride = isUITesting
            ? AdFreePassQueueUITestOverride.resolve(environment: environment)
            : nil
        let uiTestLibraryLoadDelayMilliseconds = isUITesting
            ? Self.uiTestLibraryLoadDelayMilliseconds(environment: environment)
            : nil
        #if DEBUG
        let uiTestTranscriptIntelligenceAvailability = isUITesting
            ? UITestTranscriptIntelligenceClient.resolve(environment: environment)
            : nil
        #else
        let uiTestTranscriptIntelligenceAvailability: TranscriptIntelligenceModelAvailability? = nil
        #endif
        let uiTestCloudKitAccountStatus = isUITesting
            ? Self.uiTestCloudKitAccountStatus(environment: environment)
            : nil
        let uiTestCloudKitAccountStatusDelayMilliseconds = isUITesting
            ? Self.positiveMilliseconds(
                environment["OPENCAST_UI_TEST_CLOUDKIT_ACCOUNT_STATUS_DELAY_MILLISECONDS"]
            )
            : nil
        let uiTestCloudKitAccountStatusPatienceMilliseconds = isUITesting
            ? Self.positiveMilliseconds(
                environment["OPENCAST_UI_TEST_CLOUDKIT_ACCOUNT_STATUS_PATIENCE_MILLISECONDS"]
            )
            : nil
        let usesUITestSeedFeedRefreshService = isUITesting
            && environment["OPENCAST_UI_TEST_REFRESH_SEED_FEED"] == "1"
        let uiTestFeedTransportFailure = isUITesting
            ? OpenCastUITestFeedTransportFailureService.resolve(environment: environment)
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
            seedsChapters: isUITesting && shouldSeedChapters,
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
            schedulesAppStoreEpisodeNotification: isUITesting
                && shouldScheduleAppStoreEpisodeNotification,
            resetsAdAnalysisAppAttestCredential: isUITesting && shouldResetAdAnalysisAppAttestCredential,
            adFreePassPresentationOverride: adFreePassPresentationOverride,
            adFreePassQueueOverride: adFreePassQueueOverride,
            uiTestTranscriptIntelligenceAvailability: uiTestTranscriptIntelligenceAvailability,
            pinsAppStoreAutoSkipPill: isUITesting && shouldPinAppStoreAutoSkipPill,
            appStoreSoundLabRevealProgress: appStoreSoundLabRevealProgress,
            uiTestLibraryLoadDelayMilliseconds: uiTestLibraryLoadDelayMilliseconds,
            uiTestCloudKitAccountStatus: uiTestCloudKitAccountStatus,
            uiTestCloudKitAccountStatusDelayMilliseconds: uiTestCloudKitAccountStatusDelayMilliseconds,
            uiTestCloudKitAccountStatusPatienceMilliseconds: uiTestCloudKitAccountStatusPatienceMilliseconds,
            usesUITestSeedFeedRefreshService: usesUITestSeedFeedRefreshService,
            uiTestFeedTransportFailure: uiTestFeedTransportFailure,
            seededAnalysisKeyProviders: seededAnalysisKeyProviders,
            seedsAnalysisKeysLocalOnly: isUITesting && shouldSeedAnalysisKeysLocalOnly,
            uiTestAnalysisPolicy: isUITesting
                ? AnalysisUITestFixtures.policySnapshot(variant: analysisPolicyVariant)
                : nil,
            uiTestAnalysisTrialStatus: isUITesting
                ? AnalysisUITestFixtures.trialStatus(analysisTrialStatus)
                : nil,
            uiTestAnalysisKeyTestResults: isUITesting
                ? AnalysisUITestFixtures.keyTestResults(analysisKeyTestResult)
                : nil,
            uiTestAnalysisKeyTestDelayMilliseconds: isUITesting
                ? Self.positiveMilliseconds(analysisKeyTestDelay)
                : nil,
            uiTestAnalysisKeyTestGated: isUITesting && shouldGateAnalysisKeyTest,
            uiTestAnalysisKeyStorageFailures: isUITesting
                ? AnalysisUITestFixtures.keyStorageFailures(analysisKeyStorageFailures)
                : nil,
            uiTestAnalysisKeyRequiredFeature: isUITesting
                ? analysisKeyRequiredFeature.flatMap(AnalysisFeature.init(rawValue:))
                : nil,
            uiTestAnalysisTransport: isUITesting
                ? AnalysisUITestTransportMode(
                    answer: analysisTransportAnswer.flatMap(AnalysisUITestTransportMode.Answer.init(rawValue:)) ?? .fixture,
                    holds: holdsAnalysisTransport
                )
                : nil,
            uiTestChaptersSummarySession: isUITesting
                ? chaptersSummarySession.flatMap(UITestAnalysisContinuedTaskScheduler.Mode.init(rawValue:))
                : nil,
            seedsAnalysisKeyNoticeSeen: isUITesting && !shouldForceAnalysisKeyNotice,
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
        positiveMilliseconds(environment["OPENCAST_UI_TEST_LIBRARY_LOAD_DELAY_MILLISECONDS"])
    }

    private static func positiveMilliseconds(_ rawValue: String?) -> Int? {
        guard let rawValue,
              let milliseconds = Int(rawValue),
              milliseconds > 0
        else {
            return nil
        }

        return milliseconds
    }

    // UI testing runs on an in-memory store that never syncs, so the account
    // status is fixed instead of asked of CloudKit: launch setup waits for
    // that answer, and on a freshly booted simulator the real check has taken
    // over 30 seconds. "system" opts back into the real check.
    private static func uiTestCloudKitAccountStatus(environment: [String: String]) -> SyncAccountStatus? {
        guard let rawValue = environment["OPENCAST_UI_TEST_CLOUDKIT_ACCOUNT_STATUS"]?.lowercased()
        else {
            return .noAccount
        }

        switch rawValue {
        case "system":
            return nil
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
            return .noAccount
        }
    }
}
