/// Client-side gates for Chapters & Summary capabilities that ship dark.
/// Each flag both enables its behavior and admits its sentence into the
/// generate disclosure — the dialog must never claim something that isn't
/// live.
enum TranscriptAnalysisFeatureFlags {
    /// Chapters & Summary runs on the device with the listener's own provider
    /// key (or the free trial), so it no longer charges transcription
    /// minutes. While false the ready-state cost label, the needs-minutes
    /// surfaces and the disclosure's minutes sentence stay dark; the billing
    /// rate stays pinned until the analysis service retires.
    nonisolated static let chargesTranscriptionMinutes = false
}
