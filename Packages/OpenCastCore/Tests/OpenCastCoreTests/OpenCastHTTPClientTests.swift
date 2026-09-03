import CryptoKit
import Foundation
import OpenCastCore
import Testing

@Suite("OpenCast HTTP client")
struct OpenCastHTTPClientTests {
    @MainActor
    @Test("Default feed service does not inherit a MainActor caller")
    func defaultFeedServiceDoesNotInheritMainActorCaller() async throws {
        let feedURL = URL(string: "https://example.com/feed.xml")!
        let fixtureURL = try #require(Bundle.module.url(forResource: "examplecurrentaffairs", withExtension: "xml"))
        let data = try Data(contentsOf: fixtureURL)
        let client = IsolationRecordingHTTPClient(
            result: OpenCastHTTPResult(
                data: data,
                response: OpenCastHTTPResponse(
                    url: feedURL,
                    mimeType: "application/rss+xml",
                    expectedContentLength: Int64(data.count),
                    statusCode: 200,
                    headers: [:]
                )
            )
        )
        let service: any FeedService = DefaultFeedService(httpClient: client)

        let outcome = try await service.fetchFeedOutcome(at: feedURL, validators: nil)

        #expect(outcome.snapshot?.podcast.title == "Example Current Affairs")
        #expect(client.inheritedCallerActorDescription == "nil")
    }

    @Test("Feed service uses injected HTTP client")
    func feedServiceUsesInjectedHTTPClient() async throws {
        let feedURL = URL(string: "https://example.com/feed.xml")!
        let fixtureURL = try #require(Bundle.module.url(forResource: "examplecurrentaffairs", withExtension: "xml"))
        let data = try Data(contentsOf: fixtureURL)
        let client = RecordingHTTPClient(results: [
            OpenCastHTTPResult(
                data: data,
                response: OpenCastHTTPResponse(
                    url: feedURL,
                    mimeType: "application/rss+xml",
                    expectedContentLength: Int64(data.count),
                    statusCode: 200,
                    headers: [:]
                )
            )
        ])
        let service = DefaultFeedService(httpClient: client)

        let snapshot = try await service.fetchFeed(at: feedURL)

        #expect(snapshot.podcast.title == "Example Current Affairs")
        #expect(await client.requestedURLs == [feedURL])
    }

    @Test("Feed service revalidates RSS cache entries")
    func feedServiceRevalidatesRSSCacheEntries() async throws {
        let feedURL = URL(string: "https://example.com/feed.xml")!
        let fixtureURL = try #require(Bundle.module.url(forResource: "examplecurrentaffairs", withExtension: "xml"))
        let data = try Data(contentsOf: fixtureURL)
        let client = RecordingHTTPClient(results: [
            OpenCastHTTPResult(
                data: data,
                response: OpenCastHTTPResponse(
                    url: feedURL,
                    mimeType: "application/rss+xml",
                    expectedContentLength: Int64(data.count),
                    statusCode: 200,
                    headers: [:]
                )
            )
        ])
        let service = DefaultFeedService(httpClient: client)

        _ = try await service.fetchFeed(at: feedURL)

        let request = try #require(await client.requestedRequests.first)
        #expect(request.cachePolicy == .reloadRevalidatingCacheData)
    }

    @Test("Feed requests send the RSS Accept header")
    func feedRequestsSendRSSAcceptHeader() async throws {
        let feedURL = URL(string: "https://example.com/feed.xml")!
        let fixtureURL = try #require(Bundle.module.url(forResource: "examplecurrentaffairs", withExtension: "xml"))
        let data = try Data(contentsOf: fixtureURL)
        let client = RecordingHTTPClient(results: [
            OpenCastHTTPResult(
                data: data,
                response: OpenCastHTTPResponse(
                    url: feedURL,
                    mimeType: "application/rss+xml",
                    expectedContentLength: Int64(data.count),
                    statusCode: 200,
                    headers: [:]
                )
            )
        ])

        _ = try await DefaultFeedService(httpClient: client).fetchFeed(at: feedURL)

        let request = try #require(await client.requestedRequests.first)
        #expect(
            request.value(forHTTPHeaderField: "Accept")
                == "application/rss+xml, application/xml;q=0.9, */*;q=0.8"
        )
    }

    @Test("Oversized feed bodies are rejected before the parse")
    func oversizedFeedBodiesAreRejected() async throws {
        let feedURL = URL(string: "https://example.com/feed.xml")!
        let oversized = Data(count: DefaultFeedService.maximumFeedBodyByteCount + 1)
        let client = RecordingHTTPClient(results: [
            OpenCastHTTPResult(
                data: oversized,
                response: OpenCastHTTPResponse(
                    url: feedURL,
                    mimeType: "application/rss+xml",
                    expectedContentLength: Int64(oversized.count),
                    statusCode: 200,
                    headers: [:]
                )
            )
        ])

        await #expect(throws: OpenCastCoreError.feedTooLarge(byteLimit: DefaultFeedService.maximumFeedBodyByteCount)) {
            try await DefaultFeedService(httpClient: client).fetchFeed(at: feedURL)
        }
    }

    @Test("Feed service sends owned validators and bypasses URLCache")
    func feedServiceSendsOwnedValidators() async throws {
        let feedURL = URL(string: "https://example.com/feed.xml")!
        let client = RecordingHTTPClient(results: [
            OpenCastHTTPResult(
                data: Data(),
                response: OpenCastHTTPResponse(
                    url: feedURL,
                    mimeType: nil,
                    expectedContentLength: 0,
                    statusCode: 304,
                    headers: [:]
                )
            )
        ])
        let service = DefaultFeedService(httpClient: client)

        let outcome = try await service.fetchFeedOutcome(
            at: feedURL,
            validators: FeedValidators(entityTag: "\"tag-1\"", lastModified: "Wed, 08 Apr 2026 12:00:00 GMT", bodyHash: "abc")
        )

        let request = try #require(await client.requestedRequests.first)
        #expect(request.cachePolicy == .reloadIgnoringLocalCacheData)
        #expect(request.value(forHTTPHeaderField: "If-None-Match") == "\"tag-1\"")
        #expect(request.value(forHTTPHeaderField: "If-Modified-Since") == "Wed, 08 Apr 2026 12:00:00 GMT")
        #expect(outcome.snapshot == nil)
        #expect(outcome.validators?.entityTag == "\"tag-1\"")
        #expect(outcome.validators?.bodyHash == "abc")
    }

    @Test("A matching body hash short-circuits before the parse")
    func matchingBodyHashShortCircuitsBeforeParse() async throws {
        let feedURL = URL(string: "https://example.com/feed.xml")!
        // Deliberately unparseable: reaching the parser would throw, so a
        // nil-snapshot outcome proves the short-circuit happened first.
        let body = Data("not xml at all".utf8)
        let bodyHash = sha256Hex(body)
        let client = RecordingHTTPClient(results: [
            OpenCastHTTPResult(
                data: body,
                response: OpenCastHTTPResponse(
                    url: feedURL,
                    mimeType: "application/rss+xml",
                    expectedContentLength: Int64(body.count),
                    statusCode: 200,
                    headers: ["etag": "\"tag-2\""]
                )
            )
        ])
        let service = DefaultFeedService(httpClient: client)

        let outcome = try await service.fetchFeedOutcome(
            at: feedURL,
            validators: FeedValidators(lastModified: "Wed, 08 Apr 2026 12:00:00 GMT", bodyHash: bodyHash)
        )

        #expect(outcome.snapshot == nil)
        #expect(outcome.validators?.entityTag == "\"tag-2\"")
        #expect(outcome.validators?.bodyHash == bodyHash)
    }

    @Test("A changed body parses and returns fresh validators")
    func changedBodyParsesAndReturnsFreshValidators() async throws {
        let feedURL = URL(string: "https://example.com/feed.xml")!
        let fixtureURL = try #require(Bundle.module.url(forResource: "examplecurrentaffairs", withExtension: "xml"))
        let data = try Data(contentsOf: fixtureURL)
        let client = RecordingHTTPClient(results: [
            OpenCastHTTPResult(
                data: data,
                response: OpenCastHTTPResponse(
                    url: feedURL,
                    mimeType: "application/rss+xml",
                    expectedContentLength: Int64(data.count),
                    statusCode: 200,
                    headers: ["etag": "\"tag-3\"", "last-modified": "Thu, 09 Apr 2026 12:00:00 GMT"]
                )
            )
        ])
        let service = DefaultFeedService(httpClient: client)

        let outcome = try await service.fetchFeedOutcome(
            at: feedURL,
            validators: FeedValidators(entityTag: "\"stale\"", bodyHash: "stale-hash")
        )

        #expect(outcome.snapshot?.podcast.title == "Example Current Affairs")
        #expect(outcome.validators?.entityTag == "\"tag-3\"")
        #expect(outcome.validators?.lastModified == "Thu, 09 Apr 2026 12:00:00 GMT")
        #expect(outcome.validators?.bodyHash?.isEmpty == false)
        #expect(outcome.validators?.bodyHash != "stale-hash")
    }

    /// Mirrors the service's body hashing.
    private func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { byte in
            let hex = String(byte, radix: 16)
            return hex.count == 1 ? "0\(hex)" : hex
        }.joined()
    }

    @Test("Directory service uses injected HTTP client")
    func directoryServiceUsesInjectedHTTPClient() async throws {
        let data = Data(
            """
            {
              "results": [
                {
                  "collectionId": 42,
                  "collectionName": "Example Podcast",
                  "artistName": "Example",
                  "feedUrl": "https://example.com/feed.xml",
                  "artworkUrl600": "https://example.com/art.jpg",
                  "collectionViewUrl": "https://podcasts.apple.com/example"
                }
              ]
            }
            """.utf8
        )
        let client = RecordingHTTPClient(results: [
            OpenCastHTTPResult(
                data: data,
                response: OpenCastHTTPResponse(
                    url: URL(string: "https://itunes.apple.com/search")!,
                    mimeType: "application/json",
                    expectedContentLength: Int64(data.count),
                    statusCode: 200,
                    headers: [:]
                )
            )
        ])
        let service = ITunesPodcastDirectoryService(httpClient: client)

        let results = try await service.search(query: "example")

        #expect(results.map(\.title) == ["Example Podcast"])
        #expect(await client.requestedURLs.first?.host == "itunes.apple.com")
    }

    @Test("Directory search includes the storefront country only when known")
    func directorySearchIncludesStorefrontCountryOnlyWhenKnown() async throws {
        let emptyResults = Data(#"{ "results": [] }"#.utf8)
        func makeClient() -> RecordingHTTPClient {
            RecordingHTTPClient(results: [
                OpenCastHTTPResult(
                    data: emptyResults,
                    response: OpenCastHTTPResponse(
                        url: URL(string: "https://itunes.apple.com/search")!,
                        mimeType: "application/json",
                        expectedContentLength: Int64(emptyResults.count),
                        statusCode: 200,
                        headers: [:]
                    )
                )
            ])
        }

        let regionalClient = makeClient()
        _ = try await ITunesPodcastDirectoryService(httpClient: regionalClient, countryCode: "DE")
            .search(query: "beispiel")
        let regionalURL = try #require(await regionalClient.requestedURLs.first)
        let regionalItems = URLComponents(url: regionalURL, resolvingAgainstBaseURL: false)?.queryItems
        #expect(regionalItems?.contains(URLQueryItem(name: "country", value: "DE")) == true)

        let unknownRegionClient = makeClient()
        _ = try await ITunesPodcastDirectoryService(httpClient: unknownRegionClient, countryCode: nil)
            .search(query: "example")
        let unknownRegionURL = try #require(await unknownRegionClient.requestedURLs.first)
        let unknownRegionItems = URLComponents(url: unknownRegionURL, resolvingAgainstBaseURL: false)?.queryItems
        #expect(unknownRegionItems?.contains { $0.name == "country" } == false)
    }

    @Test("Shared and download session policies are distinct")
    func sharedAndDownloadSessionPoliciesAreDistinct() throws {
        let cacheDirectory = FileManager.default.temporaryDirectory
            .appending(path: "OpenCastHTTPClientTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        let sharedConfiguration = OpenCastURLSessionFactory.sharedConfiguration(cacheDirectory: cacheDirectory)
        let downloadConfiguration = OpenCastURLSessionFactory.downloadConfiguration()
        let streamingRangeConfiguration = OpenCastURLSessionFactory.streamingRangeConfiguration()

        #expect(sharedConfiguration.requestCachePolicy == .useProtocolCachePolicy)
        #expect(sharedConfiguration.timeoutIntervalForRequest == OpenCastURLSessionFactory.requestTimeout)
        #expect(sharedConfiguration.urlCache != nil)
        #expect(sharedConfiguration.httpAdditionalHeaders?["User-Agent"] as? String == OpenCastURLSessionFactory.userAgent)
        #expect(downloadConfiguration.requestCachePolicy == .reloadIgnoringLocalCacheData)
        #expect(downloadConfiguration.urlCache == nil)
        #expect(downloadConfiguration.httpAdditionalHeaders?["User-Agent"] as? String == OpenCastURLSessionFactory.userAgent)
        #expect(streamingRangeConfiguration.requestCachePolicy == .reloadIgnoringLocalCacheData)
        #expect(streamingRangeConfiguration.timeoutIntervalForResource == OpenCastURLSessionFactory.streamingRangeResourceTimeout)
        #expect(streamingRangeConfiguration.urlCache == nil)
        #expect(streamingRangeConfiguration.httpAdditionalHeaders?["User-Agent"] as? String == OpenCastURLSessionFactory.userAgent)
    }

    @Test("Shared configurations for one cache directory share one URLCache")
    func sharedConfigurationsForOneCacheDirectoryShareOneURLCache() throws {
        let cacheDirectory = FileManager.default.temporaryDirectory
            .appending(path: "OpenCastHTTPClientTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        let otherDirectory = FileManager.default.temporaryDirectory
            .appending(path: "OpenCastHTTPClientTests-\(UUID().uuidString)", directoryHint: .isDirectory)

        let first = try #require(OpenCastURLSessionFactory.sharedConfiguration(cacheDirectory: cacheDirectory).urlCache)
        let second = try #require(OpenCastURLSessionFactory.sharedConfiguration(cacheDirectory: cacheDirectory).urlCache)
        let other = try #require(OpenCastURLSessionFactory.sharedConfiguration(cacheDirectory: otherDirectory).urlCache)

        #expect(first === second)
        #expect(first !== other)
    }

    @Test("Capped fetch fails fast on an oversized declared Content-Length")
    func cappedFetchFailsFastOnOversizedContentLength() async throws {
        let url = URL(string: "https://example.com/declared-oversized.xml")!
        let client = streamingStubClient(
            plan: StreamingBodyPlan(chunks: [], contentLength: 1_000_000),
            url: url
        )

        await #expect(throws: OpenCastHTTPBodyTooLargeError(byteLimit: 1_000)) {
            _ = try await client.data(
                for: URLRequest(url: url),
                maximumBodyByteCount: 1_000
            )
        }
    }

    @Test("Capped fetch stops a chunked body that exceeds the cap mid-stream")
    func cappedFetchStopsOversizedChunkedBodyMidStream() async throws {
        // No Content-Length: expectedContentLength is -1, so only the running
        // count can enforce the cap. Four 64 KiB chunks against a 100 KiB cap
        // trip the check at the second chunk flush.
        let url = URL(string: "https://example.com/chunked-oversized.xml")!
        let chunk = Data(repeating: 0x41, count: 64 * 1_024)
        let client = streamingStubClient(
            plan: StreamingBodyPlan(chunks: Array(repeating: chunk, count: 4), contentLength: nil),
            url: url
        )

        await #expect(throws: OpenCastHTTPBodyTooLargeError(byteLimit: 100 * 1_024)) {
            _ = try await client.data(
                for: URLRequest(url: url),
                maximumBodyByteCount: 100 * 1_024
            )
        }
    }

    @Test("Capped fetch returns an under-cap chunked body intact")
    func cappedFetchReturnsUnderCapChunkedBodyIntact() async throws {
        let url = URL(string: "https://example.com/chunked-under-cap.xml")!
        let chunks = [
            Data(repeating: 0x41, count: 70 * 1_024),
            Data(repeating: 0x42, count: 5),
        ]
        let client = streamingStubClient(
            plan: StreamingBodyPlan(chunks: chunks, contentLength: nil),
            url: url
        )

        let result = try await client.data(
            for: URLRequest(url: url),
            maximumBodyByteCount: 100 * 1_024
        )

        #expect(result.data == chunks[0] + chunks[1])
        #expect(result.response.statusCode == 200)
    }

    private func streamingStubClient(
        plan: StreamingBodyPlan,
        url: URL
    ) -> URLSessionOpenCastHTTPClient {
        StreamingBodyURLProtocol.planStore.set(plan, for: url)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StreamingBodyURLProtocol.self]
        return URLSessionOpenCastHTTPClient(configuration: configuration)
    }

    @Test("URLSession HTTP client sends shared user agent")
    func urlSessionHTTPClientSendsSharedUserAgent() async throws {
        RecordingURLProtocol.requestStore.reset()
        let configuration = OpenCastURLSessionFactory.sharedConfiguration()
        configuration.protocolClasses = [RecordingURLProtocol.self]
        configuration.urlCache = nil
        let client = URLSessionOpenCastHTTPClient(configuration: configuration)

        _ = try await client.data(for: URLRequest(url: URL(string: "https://example.com/feed.xml")!))

        let request = try #require(RecordingURLProtocol.requestStore.requests.first)
        #expect(request.value(forHTTPHeaderField: "User-Agent") == OpenCastURLSessionFactory.userAgent)
    }

}

private final class RecordedURLRequestStore: @unchecked Sendable {
    private let lock = NSLock()
    private var recordedRequests: [URLRequest] = []

    var requests: [URLRequest] {
        lock.withLock {
            recordedRequests
        }
    }

    func record(_ request: URLRequest) {
        lock.withLock {
            recordedRequests.append(request)
        }
    }

    func reset() {
        lock.withLock {
            recordedRequests.removeAll()
        }
    }
}

private final class RecordingURLProtocol: URLProtocol, @unchecked Sendable {
    static let requestStore = RecordedURLRequestStore()

    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        Self.requestStore.record(request)
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: 200,
            httpVersion: nil,
            headerFields: ["Content-Type": "text/plain"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data("ok".utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {
    }
}

private struct StreamingBodyPlan: Sendable {
    let chunks: [Data]
    let contentLength: Int?
}

/// Keyed by request URL so concurrently running tests never read each
/// other's plan.
private final class StreamingBodyPlanStore: @unchecked Sendable {
    private let lock = NSLock()
    private var plansByURL: [URL: StreamingBodyPlan] = [:]

    func set(_ plan: StreamingBodyPlan, for url: URL) {
        lock.withLock {
            plansByURL[url] = plan
        }
    }

    func plan(for url: URL?) -> StreamingBodyPlan {
        lock.withLock {
            url.flatMap { plansByURL[$0] } ?? StreamingBodyPlan(chunks: [], contentLength: nil)
        }
    }
}

private final class StreamingBodyURLProtocol: URLProtocol, @unchecked Sendable {
    static let planStore = StreamingBodyPlanStore()

    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        let plan = Self.planStore.plan(for: request.url)
        var headers = ["Content-Type": "application/rss+xml"]
        if let contentLength = plan.contentLength {
            headers["Content-Length"] = String(contentLength)
        }
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: headers
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        for chunk in plan.chunks {
            client?.urlProtocol(self, didLoad: chunk)
        }
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {
    }
}

private actor RecordingHTTPClient: OpenCastHTTPClient {
    private var results: [OpenCastHTTPResult]
    private(set) var requestedURLs: [URL] = []
    private(set) var requestedRequests: [URLRequest] = []

    init(results: [OpenCastHTTPResult]) {
        self.results = results
    }

    func data(for request: URLRequest) async throws -> OpenCastHTTPResult {
        requestedRequests.append(request)
        if let url = request.url {
            requestedURLs.append(url)
        }

        guard !results.isEmpty else {
            throw URLError(.badServerResponse)
        }

        return results.removeFirst()
    }
}

private final class IsolationRecordingHTTPClient: OpenCastHTTPClient, @unchecked Sendable {
    private let lock = NSLock()
    private let result: OpenCastHTTPResult
    private var inheritedCallerActorDescriptionValue: String?

    var inheritedCallerActorDescription: String? {
        lock.withLock {
            inheritedCallerActorDescriptionValue
        }
    }

    init(result: OpenCastHTTPResult) {
        self.result = result
    }

    func data(for request: URLRequest) async throws -> OpenCastHTTPResult {
        let inheritedCallerActorDescription = String(describing: #isolation)
        lock.withLock {
            inheritedCallerActorDescriptionValue = inheritedCallerActorDescription
        }
        return result
    }
}
