import Foundation

public protocol PodcastDirectoryService: Sendable {
    func search(query: String) async throws -> [DirectoryPodcastResult]
}

public struct ITunesPodcastDirectoryService: PodcastDirectoryService {
    let httpClient: any OpenCastHTTPClient
    let countryCode: String?
    static let jsonDecoder = JSONDecoder()

    /// The device region, for the storefront default. The macOS 12 branch
    /// only exists for the package's older macOS floor.
    public static var deviceRegionCode: String? {
        if #available(macOS 13, *) {
            Locale.current.region?.identifier
        } else {
            Locale.current.regionCode
        }
    }

    /// - Parameter countryCode: iTunes storefront country. Defaults to the
    ///   device region so non-US users get their storefront's results; nil
    ///   omits the parameter and iTunes falls back to the US storefront.
    public init(
        httpClient: any OpenCastHTTPClient = URLSessionOpenCastHTTPClient(),
        countryCode: String? = ITunesPodcastDirectoryService.deviceRegionCode
    ) {
        self.httpClient = httpClient
        self.countryCode = countryCode
    }

    public func search(query: String) async throws -> [DirectoryPodcastResult] {
        guard var components = URLComponents(string: "https://itunes.apple.com/search") else {
            throw OpenCastCoreError.invalidFeedURL
        }

        var queryItems = [
            URLQueryItem(name: "term", value: query),
            URLQueryItem(name: "media", value: "podcast"),
            URLQueryItem(name: "entity", value: "podcast"),
            URLQueryItem(name: "limit", value: "25")
        ]
        if let countryCode {
            queryItems.append(URLQueryItem(name: "country", value: countryCode))
        }
        components.queryItems = queryItems

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
