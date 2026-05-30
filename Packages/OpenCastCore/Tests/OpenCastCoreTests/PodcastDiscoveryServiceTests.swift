import Foundation
import OpenCastCore
import Testing

@Suite("Podcast discovery service")
struct PodcastDiscoveryServiceTests {
    @Test("Chart results merge lookup feed URLs")
    func chartResultsMergeLookupFeedURLs() async throws {
        let chartData = Data(
            """
            {
              "feed": {
                "results": [
                  {
                    "id": "101",
                    "name": "Chart Show",
                    "artistName": "Chart Host",
                    "artworkUrl100": "https://example.com/chart-100.jpg",
                    "url": "https://podcasts.apple.com/us/podcast/chart-show/id101"
                  }
                ]
              }
            }
            """.utf8
        )
        let lookupData = Data(
            """
            {
              "resultCount": 1,
              "results": [
                {
                  "collectionId": 101,
                  "collectionName": "Lookup Show",
                  "artistName": "Lookup Host",
                  "feedUrl": "https://example.com/feed.xml",
                  "artworkUrl600": "https://example.com/lookup-600.jpg",
                  "collectionViewUrl": "https://podcasts.apple.com/us/podcast/lookup-show/id101"
                }
              ]
            }
            """.utf8
        )
        let client = PodcastDiscoveryRecordingHTTPClient(results: [
            makeHTTPResult(data: chartData, url: URL(string: "https://rss.itunes.apple.com/chart.json")!),
            makeHTTPResult(data: lookupData, url: URL(string: "https://itunes.apple.com/lookup")!)
        ])
        let service = ITunesPodcastDirectoryService(httpClient: client)

        let results = try await service.popular(limit: 1, country: "US", allowExplicit: false)

        #expect(results == [
            DirectoryPodcastResult(
                id: 101,
                title: "Lookup Show",
                artistName: "Lookup Host",
                feedURL: URL(string: "https://example.com/feed.xml"),
                artworkURL: URL(string: "https://example.com/lookup-600.jpg"),
                collectionViewURL: URL(string: "https://podcasts.apple.com/us/podcast/lookup-show/id101")
            )
        ])

        let requests = await client.requestedRequests
        #expect(requests.first?.url?.path == "/api/v1/us/podcasts/top-podcasts/all/1/non-explicit.json")
        #expect(requests.last?.url?.host == "itunes.apple.com")
        #expect(requests.last?.url?.query?.contains("id=101") == true)
    }

    @Test("Missing lookup feed URLs keep disabled result rows")
    func missingLookupFeedURLsKeepDisabledResultRows() async throws {
        let chartData = Data(
            """
            {
              "feed": {
                "results": [
                  {
                    "id": "202",
                    "name": "Directory Only",
                    "artistName": "Chart Host",
                    "artworkUrl100": "https://example.com/chart-100.jpg",
                    "url": "https://podcasts.apple.com/us/podcast/directory-only/id202"
                  }
                ]
              }
            }
            """.utf8
        )
        let lookupData = Data(
            """
            {
              "resultCount": 1,
              "results": [
                {
                  "collectionId": 202,
                  "collectionName": "Directory Only",
                  "artistName": "Lookup Host",
                  "artworkUrl600": "https://example.com/lookup-600.jpg",
                  "collectionViewUrl": "https://podcasts.apple.com/us/podcast/directory-only/id202"
                }
              ]
            }
            """.utf8
        )
        let client = PodcastDiscoveryRecordingHTTPClient(results: [
            makeHTTPResult(data: chartData, url: URL(string: "https://rss.itunes.apple.com/chart.json")!),
            makeHTTPResult(data: lookupData, url: URL(string: "https://itunes.apple.com/lookup")!)
        ])
        let service = ITunesPodcastDirectoryService(httpClient: client)

        let results = try await service.popular(limit: 1, country: "us", allowExplicit: true)

        #expect(results.count == 1)
        #expect(results.first?.title == "Directory Only")
        #expect(results.first?.feedURL == nil)
    }

    @Test("Chart failure falls back to configured lookup IDs")
    func chartFailureFallsBackToConfiguredLookupIDs() async throws {
        let failedChartData = Data("{}".utf8)
        let fallbackLookupData = Data(
            """
            {
              "resultCount": 1,
              "results": [
                {
                  "collectionId": 303,
                  "collectionName": "Fallback Show",
                  "artistName": "Fallback Host",
                  "feedUrl": "https://example.com/fallback.xml",
                  "artworkUrl600": "https://example.com/fallback.jpg",
                  "collectionViewUrl": "https://podcasts.apple.com/us/podcast/fallback-show/id303"
                }
              ]
            }
            """.utf8
        )
        let client = PodcastDiscoveryRecordingHTTPClient(results: [
            makeHTTPResult(
                data: failedChartData,
                url: URL(string: "https://rss.itunes.apple.com/chart.json")!,
                statusCode: 503
            ),
            makeHTTPResult(data: fallbackLookupData, url: URL(string: "https://itunes.apple.com/lookup")!)
        ])
        let service = ITunesPodcastDirectoryService(
            httpClient: client,
            popularFallbackIDs: [303]
        )

        let results = try await service.popular(limit: 5, country: "us", allowExplicit: true)

        #expect(results.map(\.id) == [303])
        #expect(results.first?.feedURL == URL(string: "https://example.com/fallback.xml"))
        #expect(await client.requestedRequests.last?.url?.query?.contains("id=303") == true)
    }
}

private func makeHTTPResult(
    data: Data,
    url: URL,
    statusCode: Int = 200
) -> OpenCastHTTPResult {
    OpenCastHTTPResult(
        data: data,
        response: OpenCastHTTPResponse(
            url: url,
            mimeType: "application/json",
            expectedContentLength: Int64(data.count),
            statusCode: statusCode,
            headers: [:]
        )
    )
}

private actor PodcastDiscoveryRecordingHTTPClient: OpenCastHTTPClient {
    private var results: [OpenCastHTTPResult]
    private(set) var requestedRequests: [URLRequest] = []

    init(results: [OpenCastHTTPResult]) {
        self.results = results
    }

    func data(for request: URLRequest) async throws -> OpenCastHTTPResult {
        requestedRequests.append(request)
        guard !results.isEmpty else {
            throw URLError(.badServerResponse)
        }

        return results.removeFirst()
    }
}
