import Foundation

public protocol FeedService: Sendable {
    func fetchFeed(at url: URL) async throws -> FeedSnapshot
}

public struct DefaultFeedService: FeedService {
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
        // Feed refresh should revalidate with the server instead of honoring a still-fresh local max-age response.
        let request = URLRequest(url: url, cachePolicy: .reloadRevalidatingCacheData)
        let result = try await httpClient.data(for: request)
        guard let statusCode = result.response.statusCode else {
            throw OpenCastCoreError.invalidHTTPResponse
        }
        guard (200..<300).contains(statusCode) else {
            throw OpenCastCoreError.unexpectedStatusCode(statusCode)
        }

        return try parser.parse(data: result.data, feedURL: url)
    }
}
