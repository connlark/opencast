import Testing
@testable import OpenCast

@MainActor
@Suite("OpenCast launch configuration")
struct OpenCastLaunchConfigurationTests {
    @Test("Voice Boost diagnostics can be captured outside UI tests in Debug builds")
    func voiceBoostDiagnosticsFlagWorksOutsideUITestsInDebugBuilds() {
        let configuration = OpenCastLaunchConfiguration.resolving(
            arguments: [
                "OpenCast",
                "--opencast-capture-voiceboost-diagnostics"
            ],
            environment: [:]
        )

        #if DEBUG
        #expect(configuration.capturesVoiceBoostDiagnostics == true)
        #else
        #expect(configuration.capturesVoiceBoostDiagnostics == false)
        #endif
        #expect(configuration.exposesVoiceBoostDiagnosticsStatus == false)
        #expect(configuration.usesInMemoryStore == false)
        #expect(configuration.seedsUITestData == false)
        #expect(configuration.seedsAppStoreScreenshotData == false)
        #expect(configuration.seedsCompletedDownload == false)
        #expect(configuration.completesTranscriptRequestsForUITesting == false)
        #expect(configuration.seedsCompletedAdAnalysis == false)
        #expect(configuration.seedsAdAnalysisSpanAtStart == false)
        #expect(configuration.seedsEpisodeProgress == false)
        #expect(configuration.forcesOnboarding == false)
        #expect(configuration.forcedAppearance == .system)
        #expect(configuration.adFreePassPresentationOverride == nil)
        #expect(configuration.uiTestLibraryLoadDelayMilliseconds == nil)
    }

    @Test("Voice Boost device probe is Debug-only and implies diagnostics")
    func voiceBoostDeviceProbeIsDebugOnlyAndImpliesDiagnostics() {
        let configuration = OpenCastLaunchConfiguration.resolving(
            arguments: [
                "OpenCast",
                "--opencast-run-voiceboost-device-probe"
            ],
            environment: [:]
        )

        #if DEBUG
        #expect(configuration.runsVoiceBoostDeviceProbe == true)
        #expect(configuration.capturesVoiceBoostDiagnostics == true)
        #else
        #expect(configuration.runsVoiceBoostDeviceProbe == false)
        #expect(configuration.capturesVoiceBoostDiagnostics == false)
        #endif
        #expect(configuration.exposesVoiceBoostDiagnosticsStatus == false)
        #expect(configuration.usesInMemoryStore == false)
        #expect(configuration.seedsUITestData == false)
        #expect(configuration.seedsAppStoreScreenshotData == false)
        #expect(configuration.seedsCompletedDownload == false)
        #expect(configuration.completesTranscriptRequestsForUITesting == false)
        #expect(configuration.seedsCompletedAdAnalysis == false)
        #expect(configuration.seedsAdAnalysisSpanAtStart == false)
        #expect(configuration.seedsEpisodeProgress == false)
        #expect(configuration.forcesOnboarding == false)
        #expect(configuration.forcedAppearance == .system)
        #expect(configuration.adFreePassPresentationOverride == nil)
        #expect(configuration.uiTestLibraryLoadDelayMilliseconds == nil)
    }

    @Test("UI-test seed and appearance flags require UI testing mode")
    func uiTestSeedAndAppearanceFlagsRequireUITestingMode() {
        let configuration = OpenCastLaunchConfiguration.resolving(
            arguments: [
                "OpenCast",
                "--opencast-seed-ui-library",
                "--opencast-seed-app-store-screenshots",
                "--opencast-force-dark-mode",
                "--opencast-seed-completed-ad-analysis",
                "--opencast-seed-ad-analysis-span-at-start",
                "--opencast-complete-transcript-requests",
                "--opencast-seed-episode-progress"
            ],
            environment: [
                "OPENCAST_SEED_COMPLETED_DOWNLOAD": "1",
                "OPENCAST_UI_TEST_AD_FREE_PASS_STAGE": "completed"
            ]
        )

        #expect(configuration.usesInMemoryStore == false)
        #expect(configuration.seedsUITestData == false)
        #expect(configuration.seedsAppStoreScreenshotData == false)
        #expect(configuration.seedsCompletedDownload == false)
        #expect(configuration.completesTranscriptRequestsForUITesting == false)
        #expect(configuration.seedsCompletedAdAnalysis == false)
        #expect(configuration.seedsAdAnalysisSpanAtStart == false)
        #expect(configuration.seedsEpisodeProgress == false)
        #expect(configuration.forcesOnboarding == false)
        #expect(configuration.forcedAppearance == .system)
        #expect(configuration.adFreePassPresentationOverride == nil)
        #expect(configuration.uiTestLibraryLoadDelayMilliseconds == nil)
    }

    @Test("UI-test launch flags enable in-memory seeded runs")
    func uiTestLaunchFlagsEnableInMemorySeededRuns() {
        let configuration = OpenCastLaunchConfiguration.resolving(
            arguments: [
                "OpenCast",
                "--opencast-ui-testing",
                "--opencast-seed-ui-library",
                "--opencast-seed-app-store-screenshots",
                "--opencast-force-light-mode",
                "--opencast-seed-completed-ad-analysis",
                "--opencast-complete-transcript-requests",
                "--opencast-seed-episode-progress"
            ],
            environment: [
                "OPENCAST_SEED_COMPLETED_DOWNLOAD": "1",
                "OPENCAST_SEED_AD_ANALYSIS_SPAN_AT_START": "1",
                "OPENCAST_UI_TEST_AD_FREE_PASS_STAGE": "completed"
            ]
        )

        #expect(configuration.usesInMemoryStore == true)
        #expect(configuration.seedsUITestData == true)
        #expect(configuration.seedsAppStoreScreenshotData == true)
        #expect(configuration.seedsCompletedDownload == true)
        #expect(configuration.completesTranscriptRequestsForUITesting == true)
        #expect(configuration.seedsCompletedAdAnalysis == true)
        #expect(configuration.seedsAdAnalysisSpanAtStart == true)
        #expect(configuration.seedsEpisodeProgress == true)
        #expect(configuration.forcesOnboarding == false)
        #expect(configuration.forcedAppearance == .light)
        #expect(configuration.adFreePassPresentationOverride?.stage == .completed(zoneCount: 2))
        #expect(configuration.uiTestLibraryLoadDelayMilliseconds == nil)
    }

    @Test("UI-test ad-free pass presentation override requires UI testing mode")
    func uiTestAdFreePassPresentationOverrideRequiresUITestingMode() {
        let ignoredConfiguration = OpenCastLaunchConfiguration.resolving(
            arguments: [
                "OpenCast"
            ],
            environment: [
                "OPENCAST_UI_TEST_AD_FREE_PASS_STAGE": "failed"
            ]
        )
        let enabledConfiguration = OpenCastLaunchConfiguration.resolving(
            arguments: [
                "OpenCast",
                "--opencast-ui-testing"
            ],
            environment: [
                "OPENCAST_UI_TEST_AD_FREE_PASS_STAGE": "failed"
            ]
        )

        #expect(ignoredConfiguration.adFreePassPresentationOverride == nil)
        #expect(enabledConfiguration.adFreePassPresentationOverride?.stage == .failed(
            message: "Daily promo/ad analysis limit reached."
        ))
    }

    @Test("UI-test library load delay only applies in UI testing mode")
    func uiTestLibraryLoadDelayRequiresUITestingMode() {
        let ignoredConfiguration = OpenCastLaunchConfiguration.resolving(
            arguments: [
                "OpenCast"
            ],
            environment: [
                "OPENCAST_UI_TEST_LIBRARY_LOAD_DELAY_MILLISECONDS": "750"
            ]
        )
        let enabledConfiguration = OpenCastLaunchConfiguration.resolving(
            arguments: [
                "OpenCast",
                "--opencast-ui-testing"
            ],
            environment: [
                "OPENCAST_UI_TEST_LIBRARY_LOAD_DELAY_MILLISECONDS": "750"
            ]
        )

        #expect(ignoredConfiguration.uiTestLibraryLoadDelayMilliseconds == nil)
        #expect(enabledConfiguration.uiTestLibraryLoadDelayMilliseconds == 750)
    }

    @Test("UI-test CloudKit account status override requires UI testing mode")
    func uiTestCloudKitAccountStatusRequiresUITestingMode() {
        let ignoredConfiguration = OpenCastLaunchConfiguration.resolving(
            arguments: [
                "OpenCast"
            ],
            environment: [
                "OPENCAST_UI_TEST_CLOUDKIT_ACCOUNT_STATUS": "noAccount"
            ]
        )
        let enabledConfiguration = OpenCastLaunchConfiguration.resolving(
            arguments: [
                "OpenCast",
                "--opencast-ui-testing"
            ],
            environment: [
                "OPENCAST_UI_TEST_CLOUDKIT_ACCOUNT_STATUS": "noAccount"
            ]
        )

        #expect(ignoredConfiguration.uiTestCloudKitAccountStatus == nil)
        #expect(enabledConfiguration.uiTestCloudKitAccountStatus == .noAccount)
    }

    @Test("UI-test diagnostics status exposure is explicit")
    func uiTestDiagnosticsStatusExposureIsExplicit() {
        let configuration = OpenCastLaunchConfiguration.resolving(
            arguments: [
                "OpenCast",
                "--opencast-ui-testing",
                "--opencast-capture-voiceboost-diagnostics"
            ],
            environment: [:]
        )

        #expect(configuration.capturesVoiceBoostDiagnostics == true)
        #expect(configuration.exposesVoiceBoostDiagnosticsStatus == true)
    }

    @Test("UI-test forced onboarding suppresses completed seeding")
    func uiTestForcedOnboardingSuppressesCompletedSeeding() {
        let configuration = OpenCastLaunchConfiguration.resolving(
            arguments: [
                "OpenCast",
                "--opencast-ui-testing",
                "--opencast-force-onboarding"
            ],
            environment: [:]
        )

        #expect(configuration.forcesOnboarding == true)
        #expect(configuration.seedsOnboardingCompleted == false)
    }

    @Test("Ad-free-pass notification look fixture requires UI testing mode")
    func adFreePassNotificationLookFixtureRequiresUITestingMode() {
        let ignoredConfiguration = OpenCastLaunchConfiguration.resolving(
            arguments: [
                "OpenCast",
                "--opencast-schedule-adfreepass-notification-look-fixture"
            ],
            environment: [:]
        )
        let enabledConfiguration = OpenCastLaunchConfiguration.resolving(
            arguments: [
                "OpenCast",
                "--opencast-ui-testing",
                "--opencast-schedule-adfreepass-notification-look-fixture"
            ],
            environment: [:]
        )

        #expect(ignoredConfiguration.schedulesAdFreePassNotificationLookFixture == false)
        #expect(enabledConfiguration.schedulesAdFreePassNotificationLookFixture == true)
    }

    @Test("App Store ad-free-pass notification fixture requires UI testing mode")
    func appStoreAdFreePassNotificationFixtureRequiresUITestingMode() {
        let ignoredConfiguration = OpenCastLaunchConfiguration.resolving(
            arguments: [
                "OpenCast",
                "--opencast-schedule-app-store-adfreepass-notification"
            ],
            environment: [:]
        )
        let enabledConfiguration = OpenCastLaunchConfiguration.resolving(
            arguments: [
                "OpenCast",
                "--opencast-ui-testing"
            ],
            environment: [
                "OPENCAST_SCHEDULE_APP_STORE_ADFREEPASS_NOTIFICATION": "1"
            ]
        )

        #expect(ignoredConfiguration.schedulesAppStoreAdFreePassNotification == false)
        #expect(enabledConfiguration.schedulesAppStoreAdFreePassNotification == true)
    }

    @Test("Ad-analysis App Attest reset requires UI testing mode")
    func adAnalysisAppAttestResetRequiresUITestingMode() {
        let ignoredConfiguration = OpenCastLaunchConfiguration.resolving(
            arguments: [
                "OpenCast"
            ],
            environment: [
                "OPENCAST_RESET_AD_ANALYSIS_APP_ATTEST_CREDENTIAL": "1"
            ]
        )
        let enabledConfiguration = OpenCastLaunchConfiguration.resolving(
            arguments: [
                "OpenCast",
                "--opencast-ui-testing"
            ],
            environment: [
                "OPENCAST_RESET_AD_ANALYSIS_APP_ATTEST_CREDENTIAL": "1"
            ]
        )

        #expect(ignoredConfiguration.resetsAdAnalysisAppAttestCredential == false)
        #expect(enabledConfiguration.resetsAdAnalysisAppAttestCredential == true)
    }
}
