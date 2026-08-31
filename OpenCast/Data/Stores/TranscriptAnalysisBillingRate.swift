import Foundation

/// Client-side mirror of the worker's flat blended analysis rate
/// (`billing.rs::ANALYSIS_CREDIT_SECONDS_PER_AUDIO_HOUR`) for display
/// estimates only — the server recomputes the charge from its own
/// authoritative duration at reserve, so a drifted mirror can mis-display
/// but never mis-charge. Both sides pin the committed fixture
/// `Server/TranscriptAnalysisWorker/tests/fixtures/analysis_credit_rate.json`,
/// so the constants cannot drift apart silently.
nonisolated enum TranscriptAnalysisBillingRate {
    static let creditSecondsPerAudioHour = 7_850

    /// Mirror of `billing.rs::charge_seconds_for_duration`: `ceil(duration ×
    /// RATE / 3600)` in integer credit-seconds, nil when the duration cannot
    /// price a run.
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
