import Foundation

public struct FeedFetchOutcome: Sendable {
    /// nil when a conditional fetch determined the feed is unchanged.
    public var snapshot: FeedSnapshot?
    public var finalURL: URL?
    public var newFeedURL: URL?
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
