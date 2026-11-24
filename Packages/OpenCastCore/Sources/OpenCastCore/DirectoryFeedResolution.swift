import Foundation

public struct ResolvedFeedCandidate: Hashable, Sendable {
    public let candidate: DirectoryFeedCandidate
    public let podcast: Podcast
    private let legacySnapshot: FeedSnapshot?
    private let prepared: PreparedFeed?
    public let finalURL: URL?
    public let episodeCount: Int
    public let newestEpisodeDate: Date?
    public let isSalvaged: Bool

    public init(candidate: DirectoryFeedCandidate, snapshot: FeedSnapshot, finalURL: URL? = nil) {
        self.candidate = candidate
        podcast = snapshot.podcast
        legacySnapshot = snapshot
        prepared = nil
        self.finalURL = finalURL
        episodeCount = snapshot.episodes.count
        newestEpisodeDate = snapshot.episodes.compactMap(\.publishedAt).max()
        isSalvaged = snapshot.isSalvaged
    }

    public init(candidate: DirectoryFeedCandidate, prepared: PreparedFeed, finalURL: URL? = nil) {
        self.candidate = candidate
        self.prepared = prepared
        legacySnapshot = nil
        podcast = prepared.podcast
        self.finalURL = finalURL
        episodeCount = prepared.episodeCount
        newestEpisodeDate = prepared.episodes.newestPublishedAt
        isSalvaged = prepared.isSalvaged
    }

    @concurrent
    public func preparedFeed() async throws -> PreparedFeed {
        if let prepared { return prepared }
        guard let legacySnapshot else { throw OpenCastCoreError.invalidHTTPResponse }
        return try PreparedFeed(snapshot: legacySnapshot)
    }

    public var canonicalResolvedURLString: String {
        URLCanonicalizer.canonicalString(for: finalURL ?? candidate.feedURL)
    }
}

public struct DirectoryFeedResolution: Sendable {
    public enum Outcome: Sendable {
        case subscribe(ResolvedFeedCandidate)
        case choice(DirectoryFeedChoice)
    }

    public let outcome: Outcome
    /// Canonical requested and final URLs of every candidate read, offered or not.
    public let readFeedURLs: Set<String>

    public init(outcome: Outcome, readFeedURLs: Set<String>) {
        self.outcome = outcome
        self.readFeedURLs = readFeedURLs
    }
}

public struct DirectoryFeedChoice: Hashable, Sendable {
    public enum Reason: Hashable, Sendable {
        case fullerFeedPromoted
        case fullerFeedStale
        case fullerFeedSalvaged
    }

    public let primary: ResolvedFeedCandidate
    public let secondary: ResolvedFeedCandidate
    public let reason: Reason

    public init(primary: ResolvedFeedCandidate, secondary: ResolvedFeedCandidate, reason: Reason) {
        self.primary = primary
        self.secondary = secondary
        self.reason = reason
    }
}
