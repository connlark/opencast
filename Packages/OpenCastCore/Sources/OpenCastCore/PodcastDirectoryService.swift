import Foundation

public protocol PodcastDirectoryService: Sendable {
    func search(query: String) async throws -> [DirectoryPodcastResult]
}

public struct ITunesPodcastDirectoryService: PodcastDirectoryService {
    let httpClient: any OpenCastHTTPClient
    static let jsonDecoder = JSONDecoder()

    public init(httpClient: any OpenCastHTTPClient = URLSessionOpenCastHTTPClient()) {
        self.httpClient = httpClient
    }

    public func search(query: String) async throws -> [DirectoryPodcastResult] {
        guard var components = URLComponents(string: "https://itunes.apple.com/search") else {
            throw OpenCastCoreError.invalidFeedURL
        }

        components.queryItems = [
            URLQueryItem(name: "term", value: query),
            URLQueryItem(name: "media", value: "podcast"),
            URLQueryItem(name: "entity", value: "podcast"),
            URLQueryItem(name: "limit", value: "25")
        ]

        guard let url = components.url else {
            throw OpenCastCoreError.invalidFeedURL
        }

        let result = try await httpClient.data(for: URLRequest(url: url))
        guard let statusCode = result.response.statusCode else {
            throw OpenCastCoreError.invalidHTTPResponse
        }
        guard (200..<300).contains(statusCode) else {
            throw OpenCastCoreError.unexpectedStatusCode(statusCode)
        }

        return try await Self.decodeSearchResults(from: result.data)
    }

    @concurrent
    private static func decodeSearchResults(from data: Data) async throws -> [DirectoryPodcastResult] {
        let decoded = try jsonDecoder.decode(ITunesPodcastLookupResponse.self, from: data)
        return decoded.results.map(\.directoryResult)
    }
}
