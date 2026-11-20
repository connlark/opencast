import Testing
@testable import OpenCast

@MainActor
@Suite("OpenCast launch configuration")
struct OpenCastLaunchConfigurationTests {
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
    }

    @Test("UI testing never waits on the real CloudKit account check unless asked to")
    func uiTestingDefaultsToAFixedCloudKitAccountStatus() {
        func status(_ override: String?) -> SyncAccountStatus? {
            OpenCastLaunchConfiguration.resolving(
                arguments: ["OpenCast", "--opencast-ui-testing"],
                environment: override.map { ["OPENCAST_UI_TEST_CLOUDKIT_ACCOUNT_STATUS": $0] } ?? [:]
            ).uiTestCloudKitAccountStatus
        }

        #expect(status(nil) == .noAccount)
        #expect(status("available") == .available)
        #expect(status("not-a-status") == .noAccount)
        #expect(status("system") == nil)
        #expect(
            OpenCastLaunchConfiguration.resolving(arguments: ["OpenCast"], environment: [:])
                .uiTestCloudKitAccountStatus == nil
        )
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
