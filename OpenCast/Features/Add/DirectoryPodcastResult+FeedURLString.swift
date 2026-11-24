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

    func enrichedFeedCandidates(using directoryService: any PodcastDirectoryService) async throws -> [DirectoryFeedCandidate] {
        var candidates = feedCandidates
        if candidates.isEmpty, let feedURL {
            candidates = [DirectoryFeedCandidate(source: .apple, feedURL: feedURL)]
        }
        guard isAppleLookupEnrichable, let appleID else {
            return candidates
        }
        do {
            let enrichment = try await directoryService.lookup(appleID: appleID)
            return candidates + (enrichment?.feedCandidates ?? [])
        } catch {
            guard candidates.isEmpty, FeedTransportErrorClassifier.isUnreachable(error) else {
                return candidates
            }
            throw error
        }
    }
}
