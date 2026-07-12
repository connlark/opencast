struct AdFreePassQueueContext: Equatable {
    var finishedItemCount: Int
    var totalItemCount: Int
    var episodeTitle: String

    init(
        finishedItemCount: Int = 0,
        totalItemCount: Int = 1,
        episodeTitle: String = ""
    ) {
        self.finishedItemCount = finishedItemCount
        self.totalItemCount = totalItemCount
        self.episodeTitle = episodeTitle
    }
}
