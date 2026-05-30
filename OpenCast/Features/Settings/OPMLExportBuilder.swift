import Foundation
import OpenCastCore

enum OPMLExportBuilder {
    static func data(
        from subscriptions: [SubscriptionRecord],
        generatedAt: Date = .now
    ) throws -> Data {
        try OPMLExporter().export(
            feedReferences: feedReferences(from: subscriptions),
            generatedAt: generatedAt
        )
    }

    static func document(
        from subscriptions: [SubscriptionRecord],
        generatedAt: Date = .now
    ) throws -> OPMLFileDocument {
        try OPMLFileDocument(data: data(from: subscriptions, generatedAt: generatedAt))
    }

    static func feedReferences(from subscriptions: [SubscriptionRecord]) -> [OPMLFeedReference] {
        // Keep this helper defensive for tests and synthetic callers that pass unsanitized rows.
        var seenCanonicalFeedURLs: Set<String> = []
        var references: [OPMLFeedReference] = []

        for subscription in subscriptions where !subscription.isArchived {
            guard let feedURL = validWebURL(from: subscription.feedURL) else {
                continue
            }

            let reference = OPMLFeedReference(
                title: subscription.title,
                feedURL: feedURL
            )

            guard seenCanonicalFeedURLs.insert(reference.canonicalFeedURL).inserted else {
                continue
            }

            references.append(reference)
        }

        return references
    }

    private static func validWebURL(from rawValue: String) -> URL? {
        guard let url = URL(string: rawValue.trimmingCharacters(in: .whitespacesAndNewlines)),
              let scheme = url.scheme?.lowercased(),
              (scheme == "http" || scheme == "https"),
              url.host?.isEmpty == false
        else {
            return nil
        }

        return url
    }
}
