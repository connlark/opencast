import Foundation
import OpenCastAnalysis
import OpenCastAnalysisProviders
import Security
import Testing
@testable import OpenCast

@MainActor
@Suite("AI Services UI-test seams")
struct AnalysisUITestSeamTests {
    private let allSeams = [
        "OpenCast",
        "--opencast-seed-analysis-key-google",
        "--opencast-seed-analysis-key-openai",
        "--opencast-seed-analysis-keys-local-only",
        "--opencast-seed-analysis-policy=no-openai-chapters",
        "--opencast-seed-analysis-trial=units-left-3",
        "--opencast-seed-analysis-key-test=invalid_key,accepted",
        "--opencast-seed-analysis-key-test-delay-ms=2500",
        "--opencast-seed-analysis-key-test-gated",
        "--opencast-seed-analysis-key-faults=delete-synced,update-local",
        "--opencast-present-analysis-key-required=chapters_summary",
        "--opencast-force-analysis-key-notice",
    ]

    @Test("Every seam is ignored outside UI testing")
    func seamsNeedUITesting() {
        let configuration = OpenCastLaunchConfiguration.resolving(
            arguments: allSeams,
            environment: [
                "OPENCAST_SEED_ANALYSIS_KEY_GOOGLE": "1",
                "OPENCAST_SEED_ANALYSIS_KEY_OPENAI": "1",
                "OPENCAST_SEED_ANALYSIS_KEYS_LOCAL_ONLY": "1",
            ]
        )

        #expect(configuration.seededAnalysisKeyProviders.isEmpty)
        #expect(!configuration.seedsAnalysisKeysLocalOnly)
        #expect(configuration.uiTestAnalysisPolicy == nil)
        #expect(configuration.uiTestAnalysisTrialStatus == nil)
        #expect(configuration.uiTestAnalysisKeyTestResults == nil)
        #expect(configuration.uiTestAnalysisKeyTestDelayMilliseconds == nil)
        #expect(!configuration.uiTestAnalysisKeyTestGated)
        #expect(configuration.uiTestAnalysisKeyStorageFailures == nil)
        #expect(configuration.uiTestAnalysisKeyRequiredFeature == nil)
        #expect(!configuration.seedsAnalysisKeyNoticeSeen)
    }

    @Test("Under UI testing every seam parses")
    func uiTestingSeamsParse() {
        let configuration = OpenCastLaunchConfiguration.resolving(
            arguments: allSeams + ["--opencast-ui-testing"],
            environment: [:]
        )

        #expect(configuration.seededAnalysisKeyProviders == [.google, .openai])
        #expect(configuration.seedsAnalysisKeysLocalOnly)
        #expect(configuration.uiTestAnalysisPolicy == AnalysisUITestFixtures.policySnapshot(variant: "no-openai-chapters"))
        #expect(configuration.uiTestAnalysisTrialStatus == .unitsLeft(3))
        #expect(configuration.uiTestAnalysisKeyTestResults == [.failed(.invalidKey), .accepted])
        #expect(configuration.uiTestAnalysisKeyTestDelayMilliseconds == 2500)
        #expect(configuration.uiTestAnalysisKeyTestGated)
        #expect(configuration.uiTestAnalysisKeyStorageFailures == [
            AnalysisUITestFixtures.KeyStorageFailure(operation: .delete, synchronizable: true),
            AnalysisUITestFixtures.KeyStorageFailure(operation: .update, synchronizable: false),
        ])
        #expect(configuration.uiTestAnalysisKeyRequiredFeature == .chaptersSummary)
        #expect(!configuration.seedsAnalysisKeyNoticeSeen)

        let mirrored = OpenCastLaunchConfiguration.resolving(
            arguments: ["OpenCast"],
            environment: [
                "OPENCAST_UI_TESTING": "1",
                "OPENCAST_SEED_ANALYSIS_KEY_OPENAI": "1",
                "OPENCAST_FORCE_ANALYSIS_KEY_NOTICE": "1",
            ]
        )
        #expect(mirrored.seededAnalysisKeyProviders == [.openai])
        #expect(!mirrored.seedsAnalysisKeysLocalOnly)
        #expect(!mirrored.seedsAnalysisKeyNoticeSeen)
    }

    @Test("The Keychain fault seam parses its entries and fails each matching call once")
    func keyStorageFaults() throws {
        let failures = try #require(AnalysisUITestFixtures.keyStorageFailures("delete-synced,update-local,delete-synced,bogus,read-nowhere"))
        #expect(failures.count == 3)
        #expect(AnalysisUITestFixtures.keyStorageFailures("bogus") == nil)
        #expect(AnalysisUITestFixtures.keyStorageFailures(nil) == nil)

        let fault = AnalysisUITestFixtures.keyStorageFault(failing: failures)
        #expect(fault(.delete, false) == nil)
        #expect(fault(.update, true) == nil)
        #expect(fault(.delete, true) == errSecNotAvailable)
        #expect(fault(.update, false) == errSecNotAvailable)
        #expect(fault(.update, false) == nil)
        #expect(fault(.delete, true) == errSecNotAvailable)
        #expect(fault(.delete, true) == nil)
    }
}
