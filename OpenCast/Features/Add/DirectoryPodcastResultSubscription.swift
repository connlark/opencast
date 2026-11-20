import OpenCastCore

extension DirectoryPodcastResult {
    func isSubscribed(activePodcastIDs: Set<String>) -> Bool {
        !activePodcastIDs.isDisjoint(with: candidateCanonicalFeedURLStrings)
    }

    var candidateCanonicalFeedURLStrings: Set<String> {
        var urls = Set(feedCandidates.map(\.canonicalFeedURLString))
        if let feedURLString {
            urls.insert(URLCanonicalizer.canonicalString(forRawString: feedURLString))
        }
        return urls
    }
}
