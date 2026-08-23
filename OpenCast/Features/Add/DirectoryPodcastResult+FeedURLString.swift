import OpenCastCore

extension DirectoryPodcastResult {
    var feedURLString: String? {
        feedURL?.absoluteString
    }

    /// An Apple-only result with an Apple ID can have its feed
    /// candidates filled in by the directory's selection-time lookup.
    var isAppleLookupEnrichable: Bool {
        sources == [.apple] && appleID != nil
    }

    /// Whether the subscribe flow can resolve a feed for this result:
    /// it already carries a feed, or the Apple-ID lookup may recover
    /// one. Shared by the flow store and every result-row surface.
    var canResolveFeed: Bool {
        !feedCandidates.isEmpty || feedURL != nil || isAppleLookupEnrichable
    }
}
