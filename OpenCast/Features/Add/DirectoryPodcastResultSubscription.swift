import OpenCastCore

extension DirectoryPodcastResult {
    var knownPodcastKey: KnownPodcastsStore.Key {
        KnownPodcastsStore.Key(resultID: id, feedURLs: candidateCanonicalFeedURLStrings)
    }

    var candidateCanonicalFeedURLStrings: Set<String> {
        var urls = Set(feedCandidates.map(\.canonicalFeedURLString))
        if let feedURLString {
            urls.insert(URLCanonicalizer.canonicalString(forRawString: feedURLString))
        }
        return urls
    }
}
