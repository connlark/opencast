/// Deferred-not-failed kinds: retry sweeps treat these as queued for a
/// later probe rather than terminal failures.
/// - `capExceeded`: typed daily-cap denial — re-probed on a later foreground
///   session (a transcription backlog can legitimately hit the per-key cap).
/// - `insufficientSeconds`: typed pay-gate 402 from the Chapters & Summary
///   worker only (ad analysis is not pay-gated) — the account cannot cover
///   the run's charge; re-probed on the foreground session probe AND when
///   the shared transcription balance increases (H8).
enum EpisodeAnalysisFailureKind: String {
    case generic
    case capExceeded
    case insufficientSeconds
}
