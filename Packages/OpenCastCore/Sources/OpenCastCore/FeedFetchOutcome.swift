import Foundation

/// Everything a feed fetch learned beyond the parsed snapshot: where the
/// response was actually served from and whether the publisher declared a
/// move. Conditional fetches short-circuit with a nil snapshot.
public struct FeedFetchOutcome: Sendable {
    /// nil when a conditional fetch determined the feed is unchanged.
    public var snapshot: FeedSnapshot?
    /// The post-redirect URL the response was served from.
    public var finalURL: URL?
    /// The publisher's `itunes:new-feed-url` declaration, when present.
    public var newFeedURL: URL?
    /// The response's validators for the caller to persist toward the next
    /// conditional fetch.
    public var validators: FeedValidators?

    public init(
        snapshot: FeedSnapshot?,
        finalURL: URL? = nil,
        newFeedURL: URL? = nil,
        validators: FeedValidators? = nil
    ) {
        self.snapshot = snapshot
        self.finalURL = finalURL
        self.newFeedURL = newFeedURL
        self.validators = validators
    }
}
