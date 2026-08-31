/// Client-side gates for Chapters & Summary capabilities that ship dark.
/// Each flag both enables its behavior and admits its sentence into the
/// generate disclosure — the dialog must never claim something that isn't
/// live.
enum TranscriptAnalysisFeatureFlags {
    /// Cross-user result sharing (`SHARED_RESULTS_ENABLED` on the worker).
    /// While false the client sends `allow_shared: false` on every request.
    nonisolated static let isSharingEnabled = false
    /// Pay gate: runs charge transcription minutes at the configured flat
    /// rate. Lit only after every lane a billing-aware build talks to runs
    /// worker billing (`BILLING_REQUIRED`), and the flag also lights the
    /// ready-state cost label and the needs-minutes surfaces.
    nonisolated static let chargesTranscriptionMinutes = true
}
