import Foundation

/// Conditional-request material for one feed: the server's validators plus a
/// hash of the last body for hosts that serve no usable validators at all.
/// Persisted app-side; the fetch only consumes and reproduces them.
public struct FeedValidators: Equatable, Sendable {
    public var entityTag: String?
    public var lastModified: String?
    /// SHA-256 hex of the last fully-fetched body.
    public var bodyHash: String?

    public init(
        entityTag: String? = nil,
        lastModified: String? = nil,
        bodyHash: String? = nil
    ) {
        self.entityTag = entityTag
        self.lastModified = lastModified
        self.bodyHash = bodyHash
    }

    public var hasConditionalHeaders: Bool {
        entityTag != nil || lastModified != nil
    }

    public var isEmpty: Bool {
        entityTag == nil && lastModified == nil && bodyHash == nil
    }
}
