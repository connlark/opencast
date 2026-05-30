import Foundation

public struct OPMLParseResult: Sendable, Equatable {
    public var feedReferences: [OPMLFeedReference]
    public var usableFeedReferenceCount: Int
    public var duplicateFeedReferenceCount: Int

    public init(
        feedReferences: [OPMLFeedReference],
        usableFeedReferenceCount: Int,
        duplicateFeedReferenceCount: Int
    ) {
        self.feedReferences = feedReferences
        self.usableFeedReferenceCount = usableFeedReferenceCount
        self.duplicateFeedReferenceCount = duplicateFeedReferenceCount
    }
}
