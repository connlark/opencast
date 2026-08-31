import Foundation
import Testing
@testable import OpenCast

@Suite("Transcript analysis billing rate mirror")
struct TranscriptAnalysisBillingRateTests {
    @Test("Charge math mirrors the worker's charge_seconds_for_duration")
    func chargeMathMirrorsWorker() {
        #expect(TranscriptAnalysisBillingRate.estimatedChargeSeconds(durationSeconds: 3_600) == 7_850)
        // One second of audio still charges one credit-second (ceil).
        #expect(TranscriptAnalysisBillingRate.estimatedChargeSeconds(durationSeconds: 0.25) == 1)
        // 3.454 h QA fixture: 12434.5 s × 7850 / 3600 = 27114.1… → 27115.
        #expect(TranscriptAnalysisBillingRate.estimatedChargeSeconds(durationSeconds: 12_434.5) == 27_115)
        #expect(TranscriptAnalysisBillingRate.estimatedChargeSeconds(durationSeconds: 0) == nil)
        #expect(TranscriptAnalysisBillingRate.estimatedChargeSeconds(durationSeconds: -5) == nil)
        #expect(TranscriptAnalysisBillingRate.estimatedChargeSeconds(durationSeconds: .nan) == nil)
        #expect(TranscriptAnalysisBillingRate.estimatedChargeSeconds(durationSeconds: .infinity) == nil)
    }

    @Test("Client rate pins the shared worker fixture")
    func clientRatePinsSharedWorkerFixture() throws {
        // The worker's host suite pins the same file against its constant
        // (`billing.rs::rate_matches_shared_client_fixture`), so an H11 rate
        // change must touch the fixture — which fails both suites until both
        // constants follow. Display drift can mis-display but never
        // mis-charge; this pin exists so it can't happen silently.
        let fixtureURL = URL(filePath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appending(path: "Server/TranscriptAnalysisWorker/tests/fixtures/analysis_credit_rate.json")
        let fixture = try JSONDecoder().decode(
            [String: Int].self,
            from: Data(contentsOf: fixtureURL)
        )
        #expect(
            fixture["analysis_credit_seconds_per_audio_hour"]
                == TranscriptAnalysisBillingRate.creditSecondsPerAudioHour
        )
    }
}
