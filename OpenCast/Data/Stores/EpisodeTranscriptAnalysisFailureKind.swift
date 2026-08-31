/// Deferred-not-failed kinds: auto-run treats these as queued for a later
/// probe rather than terminal failures.
/// - `capExceeded`: typed daily-cap denial — re-probed on a later foreground
///   session (a transcription backlog can legitimately hit the per-key cap).
/// - `insufficientSeconds`: typed pay-gate 402 — the account cannot cover
///   the run's charge; re-probed on the foreground session probe AND when
///   the shared transcription balance increases (H8).
enum EpisodeTranscriptAnalysisFailureKind: String {
    case generic
    case capExceeded
    case insufficientSeconds
}
