import Foundation

/// A display-only mirror of `billing.rs::ANALYSIS_CREDIT_SECONDS_PER_AUDIO_HOUR`; both sides pin
/// `Server/TranscriptAnalysisWorker/tests/fixtures/analysis_credit_rate.json`.
nonisolated enum TranscriptAnalysisBillingRate {
    static let creditSecondsPerAudioHour = 7_850

    /// Mirrors `billing.rs::charge_seconds_for_duration`.
    static func estimatedChargeSeconds(durationSeconds: Double) -> Int64? {
        guard durationSeconds.isFinite, durationSeconds > 0 else {
            return nil
        }
        let charge = (durationSeconds * Double(creditSecondsPerAudioHour) / 3_600).rounded(.up)
        guard charge.isFinite, charge >= 1, charge <= 9_007_199_254_740_992 else {
            return nil
        }
        return Int64(charge)
    }
}
