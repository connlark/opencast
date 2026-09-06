import CryptoKit
import Foundation

public protocol FeedService: Sendable {
    func prepareFeed(at url: URL, validators: FeedValidators?) async throws -> PreparedFeedOutcome
    func fetchFeed(at url: URL) async throws -> FeedSnapshot
    /// The full fetch outcome: snapshot plus relocation signals (post-redirect
    /// final URL, `itunes:new-feed-url`) and response validators. Callers that
    /// hold validators from a prior fetch pass them in; the fetch then
    /// short-circuits to a nil-snapshot outcome when the feed is unchanged.
    /// Defaults to wrapping `fetchFeed` with no extra signals, so
    /// snapshot-only conformers keep working.
    func fetchFeedOutcome(at url: URL, validators: FeedValidators?) async throws -> FeedFetchOutcome
}

public extension FeedService {
    func prepareFeed(at url: URL, validators: FeedValidators? = nil) async throws -> PreparedFeedOutcome {
        let outcome = try await fetchFeedOutcome(at: url, validators: validators)
        let feed = try outcome.snapshot.map(PreparedFeed.init)
        return PreparedFeedOutcome(feed: feed, finalURL: outcome.finalURL,
            validators: feed?.isSalvaged == true ? nil : outcome.validators)
    }

    func fetchFeedOutcome(at url: URL, validators: FeedValidators?) async throws -> FeedFetchOutcome {
        FeedFetchOutcome(snapshot: try await fetchFeed(at: url))
    }

    func fetchFeedOutcome(at url: URL) async throws -> FeedFetchOutcome {
        try await fetchFeedOutcome(at: url, validators: nil)
    }
}

public struct DefaultFeedService: FeedService {
    public static let maximumFeedBodyByteCount = FeedResourcePolicy.maximumDecodedBytes
    static let acceptHeaderValue = "application/rss+xml, application/xml;q=0.9, */*;q=0.8"

    private let parser: RSSFeedParser
    private let httpClient: any OpenCastHTTPClient

    public init(
        parser: RSSFeedParser = RSSFeedParser(),
        httpClient: any OpenCastHTTPClient = URLSessionOpenCastHTTPClient(configuration: OpenCastURLSessionFactory.feedConfiguration())
    ) {
        self.parser = parser
        self.httpClient = httpClient
    }

    @concurrent
    public func fetchFeed(at url: URL) async throws -> FeedSnapshot {
        guard let snapshot = try await fetchFeedOutcome(at: url, validators: nil).snapshot else {
            throw OpenCastCoreError.invalidHTTPResponse
        }
        return snapshot
    }

    @concurrent
    public func fetchFeedOutcome(at url: URL, validators: FeedValidators?) async throws -> FeedFetchOutcome {
        let outcome = try await prepareFeed(at: url, validators: validators)
        return FeedFetchOutcome(snapshot: try outcome.feed?.materialized(), finalURL: outcome.finalURL,
                                newFeedURL: outcome.newFeedURL, validators: outcome.validators)
    }

    @concurrent
    public func prepareFeed(at url: URL, validators: FeedValidators? = nil) async throws -> PreparedFeedOutcome {
        try await FeedPreparationGate.shared.acquire()
        do {
            let result = try await prepareAdmittedFeed(at: url, validators: validators)
            await FeedPreparationGate.shared.release()
            return result
        } catch {
            await FeedPreparationGate.shared.release()
            throw error
        }
    }

    private func prepareAdmittedFeed(at url: URL, validators: FeedValidators?) async throws -> PreparedFeedOutcome {
        // Owned validators are the only feed cache; no full-body URLCache.
        var request: URLRequest
        if let validators, validators.hasConditionalHeaders {
            request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData)
            if let entityTag = validators.entityTag {
                request.setValue(entityTag, forHTTPHeaderField: "If-None-Match")
            }
            if let lastModified = validators.lastModified {
                request.setValue(lastModified, forHTTPHeaderField: "If-Modified-Since")
            }
        } else {
            request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData)
        }
        request.setValue(Self.acceptHeaderValue, forHTTPHeaderField: "Accept")

        let result = try await httpClient.feedFile(for: request, maximumBodyByteCount: Self.maximumFeedBodyByteCount)
        defer { withExtendedLifetime(result) {} }
        guard let statusCode = result.response.statusCode else {
            throw OpenCastCoreError.invalidHTTPResponse
        }
        if statusCode == 304 {
            guard validators?.hasConditionalHeaders == true else {
                throw OpenCastCoreError.unexpectedStatusCode(statusCode)
            }
            // A 304 need not repeat validator headers; absent ones keep their
            // stored values instead of erasing them.
            return PreparedFeedOutcome(
                feed: nil,
                finalURL: result.response.url,
                validators: FeedValidators(
                    entityTag: result.response.headerValue("ETag") ?? validators?.entityTag,
                    lastModified: result.response.headerValue("Last-Modified") ?? validators?.lastModified,
                    bodyHash: validators?.bodyHash
                )
            )
        }
        guard (200..<300).contains(statusCode) else {
            throw OpenCastCoreError.unexpectedStatusCode(statusCode)
        }
        let bodyHash = result.bodyHash
        let responseValidators = refreshedValidators(from: result.response, bodyHash: bodyHash)
        if result.incompleteReason == nil, let knownBodyHash = validators?.bodyHash, knownBodyHash == bodyHash {
            return PreparedFeedOutcome(
                feed: nil,
                finalURL: result.response.url,
                validators: responseValidators
            )
        }

        let feed = try await parser.prepare(fileURL: result.fileURL, feedURL: url, transferIssue: result.incompleteReason)
        return PreparedFeedOutcome(feed: feed, finalURL: result.response.url,
                                   validators: feed.completeness.isComplete ? responseValidators : nil)
    }

    private func refreshedValidators(
        from response: OpenCastHTTPResponse,
        bodyHash: String?
    ) -> FeedValidators {
        FeedValidators(
            entityTag: response.headerValue("ETag"),
            lastModified: response.headerValue("Last-Modified"),
            bodyHash: bodyHash
        )
    }

}
