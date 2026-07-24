import OpenCastTranscription

/// What a successful `RemoteTranscriptionJobRunner` run hands back after the
/// transcript's durable local import and ack: the job id (provenance), the
/// imported document, and the chained ad-analysis block when the job
/// requested one.
nonisolated struct RemoteTranscriptionJobRunOutcome {
    let jobID: String
    let document: EpisodeTranscriptDocument
    let adAnalysis: OpenCastRemoteTranscriptionAdAnalysisOutcome?
}
