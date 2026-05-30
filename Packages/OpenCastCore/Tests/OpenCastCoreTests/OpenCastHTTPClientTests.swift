import Foundation
import OpenCastCore
import Testing

@Suite("OpenCast HTTP client")
struct OpenCastHTTPClientTests {
    @Test("Feed service uses injected HTTP client")
    func feedServiceUsesInjectedHTTPClient() async throws {
        let feedURL = URL(string: "https://example.com/feed.xml")!
        let fixtureURL = try #require(Bundle.module.url(forResource: "americanprestige", withExtension: "xml"))
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

        #expect(snapshot.podcast.title == "American Prestige")
        #expect(await client.requestedURLs == [feedURL])
    }

    @Test("Feed service revalidates RSS cache entries")
    func feedServiceRevalidatesRSSCacheEntries() async throws {
        let feedURL = URL(string: "https://example.com/feed.xml")!
        let fixtureURL = try #require(Bundle.module.url(forResource: "americanprestige", withExtension: "xml"))
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
