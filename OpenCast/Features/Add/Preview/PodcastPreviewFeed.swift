import Foundation
import OpenCastCore

struct PodcastPreviewFeed: Identifiable {
    static let newestEpisodeLimit = 8

    let candidate: ResolvedFeedCandidate
    let digest: FeedDigest
    let description: String

    init(candidate: ResolvedFeedCandidate, digest: FeedDigest) {
        self.candidate = candidate
        self.digest = digest
        description = candidate.podcast.summary.map(HTMLPlainText.collapsedText(from:)) ?? ""
    }

    var id: String {
        candidate.candidate.canonicalFeedURLString
    }

    var knownFeedURLs: Set<String> {
        [id, candidate.podcast.id.rawValue, candidate.canonicalResolvedURLString]
    }

    var sampleEpisode: Episode? {
        guard let newest = digest.newestEpisodes.first,
              let scheme = newest.audioURL?.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              newest.audioURL?.host()?.isEmpty == false
        else {
            return nil
        }
        return newest
    }

    static func read(_ candidate: ResolvedFeedCandidate) async throws -> PodcastPreviewFeed {
        let digest = try await candidate.preparedFeed().digest(
            newest: newestEpisodeLimit,
            asOf: .now,
            timeZone: .current
        )
        return PodcastPreviewFeed(candidate: candidate, digest: digest)
    }
}
