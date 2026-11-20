/// The fields always change together, as one value; `fractionCompleted` never decreases.
nonisolated struct RemoteTranscriptionActiveProgress: Equatable {
    let stage: RemoteTranscriptionActiveStage
    let completedChunks: Int?
    let totalChunks: Int?
    let fractionCompleted: Double?
    let estimate: RemoteTranscriptionEstimate?
}
