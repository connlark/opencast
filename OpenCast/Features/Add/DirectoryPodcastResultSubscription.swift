import OpenCastCore

extension DirectoryPodcastResult {
    /// Whether this directory result is already an active subscription,
    /// matched by canonical feed URL. Shared by the Add, Onboarding, and
    /// Search/Discover result sections.
    func isSubscribed(activePodcastIDs: Set<String>) -> Bool {
        guard let feedURLString else {
            return false
        }
        return activePodcastIDs.contains(URLCanonicalizer.canonicalString(forRawString: feedURLString))
    }
}
