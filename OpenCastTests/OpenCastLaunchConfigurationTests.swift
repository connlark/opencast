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
        #expect(configuration.seedsEpisodeProgress == false)
        #expect(configuration.forcedAppearance == .system)
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
        #expect(configuration.seedsEpisodeProgress == false)
        #expect(configuration.forcedAppearance == .system)
    }

    @Test("UI-test seed and appearance flags require UI testing mode")
    func uiTestSeedAndAppearanceFlagsRequireUITestingMode() {
        let configuration = OpenCastLaunchConfiguration.resolving(
            arguments: [
                "OpenCast",
                "--opencast-seed-ui-library",
                "--opencast-seed-app-store-screenshots",
                "--opencast-force-dark-mode",
                "--opencast-seed-episode-progress"
            ],
            environment: [
                "OPENCAST_SEED_COMPLETED_DOWNLOAD": "1"
            ]
        )

        #expect(configuration.usesInMemoryStore == false)
        #expect(configuration.seedsUITestData == false)
        #expect(configuration.seedsAppStoreScreenshotData == false)
        #expect(configuration.seedsCompletedDownload == false)
        #expect(configuration.seedsEpisodeProgress == false)
        #expect(configuration.forcedAppearance == .system)
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
                "--opencast-seed-episode-progress"
            ],
            environment: [
                "OPENCAST_SEED_COMPLETED_DOWNLOAD": "1"
            ]
        )

        #expect(configuration.usesInMemoryStore == true)
        #expect(configuration.seedsUITestData == true)
        #expect(configuration.seedsAppStoreScreenshotData == true)
        #expect(configuration.seedsCompletedDownload == true)
        #expect(configuration.seedsEpisodeProgress == true)
        #expect(configuration.forcedAppearance == .light)
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
}
