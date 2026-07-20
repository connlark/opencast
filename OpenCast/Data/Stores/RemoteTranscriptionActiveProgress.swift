/// Atomic UI snapshot: stage, durable chunk counts, monotonic fraction, and
/// ETA always move through the observable store together.
nonisolated struct RemoteTranscriptionActiveProgress: Equatable {
    let stage: RemoteTranscriptionActiveStage
    let completedChunks: Int?
    let totalChunks: Int?
    let fractionCompleted: Double?
    let estimate: RemoteTranscriptionEstimate?
}
