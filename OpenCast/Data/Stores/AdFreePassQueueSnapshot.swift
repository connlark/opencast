struct AdFreePassQueueSnapshot: Equatable {
    var state: AdFreePassQueueState = .idle
    var activeEpisodeID: String?
    var activeEpisodeTitle: String?
    var activeArtworkURL: String?
    var activeItemMode: AdDetectionMode?
    var currentStage: EpisodeAdFreePassStage?
    var finishedItemCount = 0
    var totalItemCount = 0
    var completedCount = 0
    var failedCount = 0
    var fractionCompleted: Double = 0
    var outcomes: [AdFreePassQueueItemOutcome] = []
    var pendingItems: [AdFreePassQueueItem] = []
    var pendingModelConsentByteCount: Int64?
}
