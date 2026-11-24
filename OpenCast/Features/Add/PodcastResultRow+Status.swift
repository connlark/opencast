import OpenCastCore

extension PodcastResultRow.Status {
    init(
        of result: DirectoryPodcastResult,
        addFlow: DirectorySubscriptionFlowStore,
        knownPodcasts: KnownPodcastsStore,
        activePodcastIDs: Set<String>
    ) {
        let key = result.knownPodcastKey
        if !result.canResolveFeed {
            self = .noFeed
        } else if knownPodcasts.libraryFeedURL(for: key, activePodcastIDs: activePodcastIDs) != nil {
            self = addFlow.addedShowIDs.contains(result.id) ? .justAdded : .inLibrary
        } else if addFlow.subscribingResultID == result.id || (!addFlow.isBusy && knownPodcasts.isAdding(key)) {
            self = .adding
        } else {
            self = .addable
        }
    }

    func openHint(opensShowPage: Bool) -> String {
        switch self {
        case .noFeed:
            "This podcast cannot be opened because the directory did not provide an RSS feed."
        case .inLibrary, .justAdded:
            opensShowPage ? "Opens this podcast in your library." : "Shows this podcast."
        case .addable, .adding:
            "Shows this podcast before you subscribe."
        }
    }
}
