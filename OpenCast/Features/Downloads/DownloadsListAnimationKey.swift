struct DownloadsListAnimationKey: Equatable {
    let downloadingEpisodeIDs: [String]
    let failedEpisodeIDs: [String]
    let downloadedEpisodeIDs: [String]
    let stateRawValuesByEpisodeID: [String: String]
}
