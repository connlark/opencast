import CryptoKit
import Foundation

public protocol FeedService: Sendable {
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
    func fetchFeedOutcome(at url: URL, validators: FeedValidators?) async throws -> FeedFetchOutcome {
        FeedFetchOutcome(snapshot: try await fetchFeed(at: url))
    }

    func fetchFeedOutcome(at url: URL) async throws -> FeedFetchOutcome {
        try await fetchFeedOutcome(at: url, validators: nil)
    }
}

public struct DefaultFeedService: FeedService {
    /// Server parity: the deployed NotificationsWorker caps feed bodies at
    /// the same size.
    public static let maximumFeedBodyByteCount = 8 * 1_024 * 1_024
    static let acceptHeaderValue = "application/rss+xml, application/xml;q=0.9, */*;q=0.8"

    private let parser: RSSFeedParser
    private let httpClient: any OpenCastHTTPClient

    public init(
        parser: RSSFeedParser = RSSFeedParser(),
        httpClient: any OpenCastHTTPClient = URLSessionOpenCastHTTPClient()
    ) {
        self.parser = parser
        self.httpClient = httpClient
    }

    public func fetchFeed(at url: URL) async throws -> FeedSnapshot {
        guard let snapshot = try await fetchFeedOutcome(at: url, validators: nil).snapshot else {
            throw OpenCastCoreError.invalidHTTPResponse
        }
        return snapshot
    }

    public func fetchFeedOutcome(at url: URL, validators: FeedValidators?) async throws -> FeedFetchOutcome {
        // Owned validators and URLCache revalidation are mutually exclusive on
        // one request: URLSession transparently replays a cached 200 for a
        // server 304 under URLCache, so conditional headers ride an
        // ignore-local-cache request. Without validators, feed refresh still
        // revalidates with the server instead of honoring a still-fresh local
        // max-age response.
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
            request = URLRequest(url: url, cachePolicy: .reloadRevalidatingCacheData)
        }
        request.setValue(Self.acceptHeaderValue, forHTTPHeaderField: "Accept")

        let result = try await httpClient.data(for: request)
        guard let statusCode = result.response.statusCode else {
            throw OpenCastCoreError.invalidHTTPResponse
        }
        if statusCode == 304 {
            // A 304 need not repeat validator headers; absent ones keep their
            // stored values instead of erasing them.
            return FeedFetchOutcome(
                snapshot: nil,
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
        if result.response.expectedContentLength > Int64(Self.maximumFeedBodyByteCount)
            || result.data.count > Self.maximumFeedBodyByteCount {
            throw OpenCastCoreError.feedTooLarge(byteLimit: Self.maximumFeedBodyByteCount)
        }

        let bodyHash = Self.sha256Hex(result.data)
        let responseValidators = refreshedValidators(from: result.response, bodyHash: bodyHash)
        if let knownBodyHash = validators?.bodyHash, knownBodyHash == bodyHash {
            return FeedFetchOutcome(
                snapshot: nil,
                finalURL: result.response.url,
                validators: responseValidators
            )
        }

        let snapshot = try parser.parse(data: result.data, feedURL: url)
        return FeedFetchOutcome(
            snapshot: snapshot,
            finalURL: result.response.url,
            newFeedURL: snapshot.newFeedURL,
            validators: responseValidators
        )
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

    private static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { byte in
            let hex = String(byte, radix: 16)
            return hex.count == 1 ? "0\(hex)" : hex
        }.joined()
    }
}
