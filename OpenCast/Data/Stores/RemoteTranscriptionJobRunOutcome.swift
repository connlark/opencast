import OpenCastTranscription

/// The runner clears the reference before it returns, so completion delivery reads the owner
/// from here, never from the store.
nonisolated struct RemoteTranscriptionJobRunOutcome {
    let jobID: String
    let document: EpisodeTranscriptDocument
    let adAnalysis: OpenCastRemoteTranscriptionAdAnalysisOutcome?
    let completionDeliveryOwner: JobCompletionDeliveryOwner
}
