import Foundation
import OpenCastCore
import Testing

@Suite("Podcast Index worker directory service")
struct PodcastIndexWorkerDirectoryServiceTests {
    private let baseURL = URL(string: "https://directory.example.com")!

    @Test("Search posts the query and decodes normalized entries")
    func searchPostsQueryAndDecodesEntries() async throws {
        let body = """
        {
          "version": 1,
          "results": [
            {
              "podcastIndexId": 745392,
              "podcastGuid": "2d7400e3-bacb-52fd-aabc-0da55e39f98b",
              "appleId": 917918570,
              "title": "Serial",
              "author": "Serial Productions",
              "feedUrl": "https://feeds.example.com/full",
              "artworkUrl": "https://images.example.com/serial.jpg",
              "websiteUrl": "https://serial.example.com",
              "reportedEpisodeCount": 124,
              "reportedUpdatedAt": 1750230000
            }
          ]
        }
        """
        let client = StubWorkerHTTPClient(statusCode: 200, body: body)
        let service = PodcastIndexWorkerDirectoryService(baseURL: baseURL, httpClient: client)

        let results = try await service.search(query: "serial")

        let request = try #require(await client.lastRequest)
        #expect(request.url?.absoluteString == "https://directory.example.com/v1/search")
        #expect(request.httpMethod == "POST")
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")
        let requestBody = try #require(request.httpBody)
        #expect(String(decoding: requestBody, as: UTF8.self) == #"{"query":"serial"}"#)

        #expect(results.count == 1)
        let result = try #require(results.first)
        #expect(result.id == "podcastindex:745392")
        #expect(result.sources == [.podcastIndex])
        #expect(result.appleID == 917_918_570)
        #expect(result.podcastIndexID == 745_392)
        #expect(result.podcastGUID == "2d7400e3-bacb-52fd-aabc-0da55e39f98b")
        #expect(result.title == "Serial")
        #expect(result.artistName == "Serial Productions")
        #expect(result.feedURL?.absoluteString == "https://feeds.example.com/full")
        let candidate = try #require(result.feedCandidates.first)
        #expect(candidate.source == .podcastIndex)
        #expect(candidate.reportedEpisodeCount == 124)
        #expect(candidate.reportedUpdatedAt == Date(timeIntervalSince1970: 1_750_230_000))
    }

    @Test("Search decodes entries with absent optional hints")
    func searchDecodesAbsentHints() async throws {
        let body = """
        {
          "version": 1,
          "results": [
            {
              "podcastIndexId": 7,
              "title": "Hints Absent",
              "feedUrl": "https://feeds.example.com/absent"
            }
          ]
        }
        """
        let client = StubWorkerHTTPClient(statusCode: 200, body: body)
        let service = PodcastIndexWorkerDirectoryService(baseURL: baseURL, httpClient: client)

        let result = try #require(try await service.search(query: "absent").first)

        #expect(result.appleID == nil)
        #expect(result.podcastGUID == nil)
        #expect(result.feedCandidates.first?.reportedEpisodeCount == nil)
        #expect(result.feedCandidates.first?.reportedUpdatedAt == nil)
    }

    @Test("Search surfaces non-200 statuses as errors")
    func searchSurfacesFailureStatuses() async {
        let client = StubWorkerHTTPClient(statusCode: 503, body: #"{"error":"podcast_directory_disabled"}"#)
        let service = PodcastIndexWorkerDirectoryService(baseURL: baseURL, httpClient: client)

        await #expect(throws: OpenCastCoreError.unexpectedStatusCode(503)) {
            try await service.search(query: "serial")
        }
    }

    @Test("Lookup decodes a hit")
    func lookupDecodesHit() async throws {
        let body = """
        {"version": 1, "result": {"podcastIndexId": 745392, "appleId": 917918570, "title": "Serial", "feedUrl": "https://feeds.example.com/full"}}
        """
        let client = StubWorkerHTTPClient(statusCode: 200, body: body)
        let service = PodcastIndexWorkerDirectoryService(baseURL: baseURL, httpClient: client)

        let result = try await service.lookup(appleID: 917_918_570)

        let request = try #require(await client.lastRequest)
        #expect(request.url?.absoluteString == "https://directory.example.com/v1/podcasts/by-apple-id/917918570")
        #expect(result?.podcastIndexID == 745_392)
    }

    @Test("Lookup maps 404 to nil")
    func lookupMapsNotFoundToNil() async throws {
        let client = StubWorkerHTTPClient(statusCode: 404, body: #"{"error":"not_found"}"#)
        let service = PodcastIndexWorkerDirectoryService(baseURL: baseURL, httpClient: client)

        let result = try await service.lookup(appleID: 1)

        #expect(result == nil)
    }

    @Test("Lookup rejects non-positive Apple IDs without a request")
    func lookupRejectsNonPositiveIDs() async throws {
        let client = StubWorkerHTTPClient(statusCode: 200, body: "{}")
        let service = PodcastIndexWorkerDirectoryService(baseURL: baseURL, httpClient: client)

        #expect(try await service.lookup(appleID: 0) == nil)
        #expect(await client.lastRequest == nil)
    }
}

private actor StubWorkerHTTPClient: OpenCastHTTPClient {
    let statusCode: Int
    let body: String
    private(set) var lastRequest: URLRequest?

    init(statusCode: Int, body: String) {
        self.statusCode = statusCode
        self.body = body
    }

    func data(for request: URLRequest) async throws -> OpenCastHTTPResult {
        lastRequest = request
        let data = Data(body.utf8)
        return OpenCastHTTPResult(
            data: data,
            response: OpenCastHTTPResponse(
                url: request.url,
                mimeType: "application/json",
                expectedContentLength: Int64(data.count),
                statusCode: statusCode,
                headers: [:]
            )
        )
    }
}
