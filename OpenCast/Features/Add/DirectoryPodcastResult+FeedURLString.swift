import OpenCastCore

extension DirectoryPodcastResult {
    var feedURLString: String? {
        feedURL?.absoluteString
    }

    var isAppleLookupEnrichable: Bool {
        sources == [.apple] && appleID != nil
    }

    var canResolveFeed: Bool {
        !feedCandidates.isEmpty || feedURL != nil || isAppleLookupEnrichable
    }
}
