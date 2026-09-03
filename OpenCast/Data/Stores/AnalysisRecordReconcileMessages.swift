/// The user-facing failure copy an analysis store's reconciler writes onto
/// records it has to fail.
struct AnalysisRecordReconcileMessages {
    let interrupted: String
    let documentMissing: String
    let transcriptMismatch: String
}
