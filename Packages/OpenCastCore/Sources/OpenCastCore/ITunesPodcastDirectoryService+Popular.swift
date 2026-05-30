import Foundation

extension ITunesPodcastDirectoryService {
    public func popular(
        limit: Int = 10,
        country: String = "us",
        allowExplicit: Bool = true
    ) async throws -> [DirectoryPodcastResult] {
        let sanitizedLimit = sanitizedPopularLimit(limit)

        do {
            let chartResults = try await popularChartResults(
                limit: sanitizedLimit,
                country: country,
                allowExplicit: allowExplicit
            )
            return try await mergedPopularResults(
                chartResults: chartResults,
                limit: sanitizedLimit
            )
        } catch {
            if error is CancellationError {
                throw error
            }

            return try await fallbackPopularResults(limit: sanitizedLimit)
        }
    }

    private func popularChartResults(
        limit: Int,
        country: String,
        allowExplicit: Bool
    ) async throws -> [ITunesPopularPodcastChartResult] {
        let url = try popularChartURL(limit: limit, country: country, allowExplicit: allowExplicit)
        let data = try await validatedData(for: URLRequest(url: url))
        let decoded = try await Self.decodePopularChartResponse(from: data)
        return Array(decoded.feed.results.prefix(limit))
    }

    private func mergedPopularResults(
        chartResults: [ITunesPopularPodcastChartResult],
        limit: Int
    ) async throws -> [DirectoryPodcastResult] {
        let lookupResults = try await lookupPodcastResults(ids: chartResults.map(\.id))
        return chartResults.prefix(limit).map { chartResult in
            let lookupResult = lookupResults[chartResult.id]
            return DirectoryPodcastResult(
                id: chartResult.id,
                title: lookupResult?.collectionName ?? chartResult.name,
                artistName: lookupResult?.artistName ?? chartResult.artistName,
                feedURL: lookupResult?.feedUrl,
                artworkURL: lookupResult?.artworkUrl600 ?? chartResult.artworkUrl100,
                collectionViewURL: lookupResult?.collectionViewUrl ?? chartResult.url
            )
        }
    }

    private func fallbackPopularResults(limit: Int) async throws -> [DirectoryPodcastResult] {
        let fallbackIDs = Array(popularFallbackIDs.prefix(limit))
        let lookupResults = try await lookupPodcastResults(ids: fallbackIDs)
        return fallbackIDs.compactMap { lookupResults[$0]?.directoryResult }
    }

    private func lookupPodcastResults(ids: [Int]) async throws -> [Int: ITunesPodcastLookupResult] {
        guard !ids.isEmpty else {
            return [:]
        }

        let data = try await validatedData(for: URLRequest(url: try lookupURL(ids: ids)))
        let decoded = try await Self.decodeLookupResponse(from: data)
        return Dictionary(uniqueKeysWithValues: decoded.results.map { ($0.collectionId, $0) })
    }

    @concurrent
    private static func decodePopularChartResponse(
        from data: Data
    ) async throws -> ITunesPopularPodcastChartResponse {
        try jsonDecoder.decode(ITunesPopularPodcastChartResponse.self, from: data)
    }

    @concurrent
    private static func decodeLookupResponse(from data: Data) async throws -> ITunesPodcastLookupResponse {
        try jsonDecoder.decode(ITunesPodcastLookupResponse.self, from: data)
    }

    private func popularChartURL(
        limit: Int,
        country: String,
        allowExplicit: Bool
    ) throws -> URL {
        let normalizedCountry = country.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard normalizedCountry.count == 2,
              normalizedCountry.allSatisfy(\.isLetter)
        else {
            throw OpenCastCoreError.invalidFeedURL
        }

        let explicitness = allowExplicit ? "explicit" : "non-explicit"
        guard let url = URL(
            string: "https://rss.itunes.apple.com/api/v1/\(normalizedCountry)/podcasts/top-podcasts/all/\(limit)/\(explicitness).json"
        ) else {
            throw OpenCastCoreError.invalidFeedURL
        }

        return url
    }

    private func lookupURL(ids: [Int]) throws -> URL {
        guard var components = URLComponents(string: "https://itunes.apple.com/lookup") else {
            throw OpenCastCoreError.invalidFeedURL
        }

        components.queryItems = [
            URLQueryItem(name: "id", value: ids.map(String.init).joined(separator: ",")),
            URLQueryItem(name: "entity", value: "podcast")
        ]

        guard let url = components.url else {
            throw OpenCastCoreError.invalidFeedURL
        }

        return url
    }

    private func validatedData(for request: URLRequest) async throws -> Data {
        let result = try await httpClient.data(for: request)
        guard let statusCode = result.response.statusCode else {
            throw OpenCastCoreError.invalidHTTPResponse
        }
        guard (200..<300).contains(statusCode) else {
            throw OpenCastCoreError.unexpectedStatusCode(statusCode)
        }

        return result.data
    }

    private func sanitizedPopularLimit(_ limit: Int) -> Int {
        min(max(limit, 1), 100)
    }
}
