import OpenCastTranscription

/// What a successful `RemoteTranscriptionJobRunner` run hands back after the
/// transcript's durable local import and ack: the job id (provenance), the
/// imported document, the chained ad-analysis block when the job requested
/// one, and the reference's delivery owner as the run read it. The runner
/// clears the reference before it returns, so completion delivery reads
/// the owner from here, never from the store.
nonisolated struct RemoteTranscriptionJobRunOutcome {
    let jobID: String
    let document: EpisodeTranscriptDocument
    let adAnalysis: OpenCastRemoteTranscriptionAdAnalysisOutcome?
    let completionDeliveryOwner: JobCompletionDeliveryOwner
}
