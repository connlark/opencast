import OpenCastCore

extension DirectoryPodcastResult {
    /// Whether this directory result is already an active subscription,
    /// matched by canonical feed URL against every candidate so a
    /// merged result reads as one logical subscription. Shared by the
    /// Add, Onboarding, and Search/Discover result sections.
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
