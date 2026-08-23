import Foundation

/// One feed URL a directory result can resolve to, with optional
/// provider-reported hints. Hints are never displayed as truth; the
/// app parses candidate feeds itself before showing counts.
public struct DirectoryFeedCandidate: Codable, Hashable, Identifiable, Sendable {
    public var source: PodcastDirectorySource
    public var feedURL: URL
    public var reportedEpisodeCount: Int?
    public var reportedUpdatedAt: Date?

    public var id: String {
        canonicalFeedURLString
    }

    public var canonicalFeedURLString: String {
        URLCanonicalizer.canonicalString(for: feedURL)
    }

    public init(
        source: PodcastDirectorySource,
        feedURL: URL,
        reportedEpisodeCount: Int? = nil,
        reportedUpdatedAt: Date? = nil
    ) {
        self.source = source
        self.feedURL = feedURL
        self.reportedEpisodeCount = reportedEpisodeCount
        self.reportedUpdatedAt = reportedUpdatedAt
    }
}
