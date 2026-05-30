import Foundation

public struct OPMLFeedReference: Codable, Hashable, Identifiable, Sendable {
    public var id: String {
        canonicalFeedURL
    }

    public var title: String?
    public var feedURL: URL
    public var canonicalFeedURL: String
    public var htmlURL: URL?

    public init(
        title: String? = nil,
        feedURL: URL,
        htmlURL: URL? = nil
    ) {
        let trimmedTitle = title?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.title = trimmedTitle?.isEmpty == false ? trimmedTitle : nil
        self.feedURL = feedURL
        canonicalFeedURL = URLCanonicalizer.canonicalString(for: feedURL)
        self.htmlURL = htmlURL
    }
}
