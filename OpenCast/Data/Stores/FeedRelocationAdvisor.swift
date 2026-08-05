import Foundation
import OpenCastCore

/// Session-scoped redirect bookkeeping behind the "Update Feed Address"
/// suggestion: counts consecutive same-target host divergences per feed and
/// remembers which `http://` feeds already probed their https twin this
/// launch. Redirects are routinely CDN noise, so a single divergence never
/// suggests anything. The observable suggestion map stays on LibraryStore —
/// this type only advises.
struct FeedRelocationAdvisor {
    enum Verdict: Equatable {
        /// Redirects landed back on the subscribed host: any standing
        /// suggestion is stale.
        case clearSuggestion
        case none
        case suggest(URL)
    }

    static let redirectDivergenceThreshold = 3

    private var redirectDivergenceByFeedURL: [String: (targetCanonicalURL: String, count: Int)] = [:]
    private var httpsUpgradeProbedFeedURLs: Set<String> = []

    mutating func recordRedirect(feedURLString: String, finalURL: URL?) -> Verdict {
        guard let finalURL,
              let subscribedHost = URL(string: feedURLString)?.host?.lowercased(),
              let finalHost = finalURL.host?.lowercased()
        else {
            return .none
        }
        guard finalHost != subscribedHost else {
            redirectDivergenceByFeedURL[feedURLString] = nil
            return .clearSuggestion
        }

        let targetCanonicalURL = URLCanonicalizer.canonicalString(for: finalURL)
        var divergence = redirectDivergenceByFeedURL[feedURLString] ?? (targetCanonicalURL, 0)
        if divergence.targetCanonicalURL == targetCanonicalURL {
            divergence.count += 1
        } else {
            divergence = (targetCanonicalURL, 1)
        }
        redirectDivergenceByFeedURL[feedURLString] = divergence
        return divergence.count >= Self.redirectDivergenceThreshold ? .suggest(finalURL) : .none
    }

    /// Test-and-mark: true exactly once per feed per launch.
    mutating func shouldProbeHTTPSUpgrade(_ feedURLString: String) -> Bool {
        httpsUpgradeProbedFeedURLs.insert(feedURLString).inserted
    }

    mutating func clearDivergence(_ feedURLString: String) {
        redirectDivergenceByFeedURL[feedURLString] = nil
    }
}
