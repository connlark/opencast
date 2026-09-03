/// Wire keys of the analysis workers' shared job envelope (`{job_id,
/// state, poll_after_seconds}`), the shape both the ad and transcript
/// analysis workers use for accepted and still-running jobs.
nonisolated enum AnalysisJobEnvelopeCodingKeys: String, CodingKey {
    case jobID = "job_id"
    case state
    case pollAfter = "poll_after_seconds"
}
