import Foundation

/// A candidate feed the resolver fetched and parsed. Parsed values —
/// never provider hints — are what selection decisions and UI show.
public struct ResolvedFeedCandidate: Hashable, Sendable {
    public let candidate: DirectoryFeedCandidate
    public let snapshot: FeedSnapshot
    /// The post-redirect final URL when the fetch exposed one.
    public let finalURL: URL?
    /// Deduplicated parsed episode count.
    public let episodeCount: Int
    public let newestEpisodeDate: Date?
    /// True when the parse was salvaged from an incomplete document:
    /// the count reads as "at least N episodes".
    public let isSalvaged: Bool

    public init(candidate: DirectoryFeedCandidate, snapshot: FeedSnapshot, finalURL: URL? = nil) {
        self.candidate = candidate
        self.snapshot = snapshot
        self.finalURL = finalURL
        episodeCount = snapshot.episodes.count
        newestEpisodeDate = snapshot.episodes.compactMap(\.publishedAt).max()
        isSalvaged = snapshot.isSalvaged
    }

    public var canonicalResolvedURLString: String {
        URLCanonicalizer.canonicalString(for: finalURL ?? candidate.feedURL)
    }
}

public enum DirectoryFeedResolution: Sendable {
    /// One working candidate (or all candidates resolve to the same
    /// feed, or the difference is immaterial): subscribe directly.
    case subscribe(ResolvedFeedCandidate)
    /// Materially different catalogs: present both and let the user
    /// choose, with `primary` as the primary action.
    case choice(DirectoryFeedChoice)
}

public struct DirectoryFeedChoice: Hashable, Sendable {
    public enum Reason: Hashable, Sendable {
        /// The secondary is the original directory feed; the fuller
        /// current feed was promoted to the primary action.
        case fullerFeedPromoted
        /// The secondary is fuller but its newest episode trails the
        /// primary's by more than the staleness tolerance: a full
        /// archive that is no longer updating.
        case fullerFeedStale
        /// The secondary parses fuller but only partially (salvaged);
        /// a partial count never outranks a clean feed on its own.
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
