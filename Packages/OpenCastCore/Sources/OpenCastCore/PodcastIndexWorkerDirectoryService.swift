import Foundation

/// Client for OpenCast's Podcast Index directory Worker. The app never
/// contacts Podcast Index directly; the Worker normalizes and bounds
/// everything upstream.
public struct PodcastIndexWorkerDirectoryService: PodcastDirectoryService {
    /// Worker-side and client-side request budget; the Worker aborts
    /// upstream calls at five seconds, so this bounds the round trip.
    static let requestTimeout: TimeInterval = 10

    let baseURL: URL
    let httpClient: any OpenCastHTTPClient
    static let jsonDecoder = JSONDecoder()
    static let jsonEncoder = JSONEncoder()

    public init(baseURL: URL, httpClient: any OpenCastHTTPClient = URLSessionOpenCastHTTPClient()) {
        self.baseURL = baseURL
        self.httpClient = httpClient
    }

    public func search(query: String) async throws -> [DirectoryPodcastResult] {
        var request = URLRequest(url: baseURL.appending(path: "v1/search"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try Self.jsonEncoder.encode(WorkerSearchRequest(query: query))
        request.timeoutInterval = Self.requestTimeout

        let result = try await httpClient.data(for: request)
        guard let statusCode = result.response.statusCode else {
            throw OpenCastCoreError.invalidHTTPResponse
        }
        guard statusCode == 200 else {
            throw OpenCastCoreError.unexpectedStatusCode(statusCode)
        }

        let decoded = try Self.jsonDecoder.decode(WorkerSearchResponse.self, from: result.data)
        return decoded.results.map(\.directoryResult)
    }

    public func lookup(appleID: Int) async throws -> DirectoryPodcastResult? {
        guard appleID > 0 else {
            return nil
        }
        var request = URLRequest(url: baseURL.appending(path: "v1/podcasts/by-apple-id/\(appleID)"))
        request.timeoutInterval = Self.requestTimeout

        let result = try await httpClient.data(for: request)
        guard let statusCode = result.response.statusCode else {
            throw OpenCastCoreError.invalidHTTPResponse
        }
        if statusCode == 404 {
            return nil
        }
        guard statusCode == 200 else {
            throw OpenCastCoreError.unexpectedStatusCode(statusCode)
        }

        let decoded = try Self.jsonDecoder.decode(WorkerLookupResponse.self, from: result.data)
        return decoded.result.directoryResult
    }
}

private struct WorkerSearchRequest: Encodable {
    var query: String
}

private struct WorkerSearchResponse: Decodable {
    var version: Int
    var results: [WorkerDirectoryEntry]
}

private struct WorkerLookupResponse: Decodable {
    var version: Int
    var result: WorkerDirectoryEntry
}

struct WorkerDirectoryEntry: Decodable {
    var podcastIndexId: Int
    var podcastGuid: String?
    var appleId: Int?
    var title: String
    var author: String?
    var feedUrl: URL
    var artworkUrl: URL?
    var websiteUrl: URL?
    var reportedEpisodeCount: Int?
    var reportedUpdatedAt: Int?

    var directoryResult: DirectoryPodcastResult {
        DirectoryPodcastResult(
            id: "podcastindex:\(podcastIndexId)",
            title: title,
            artistName: author,
            feedURL: feedUrl,
            artworkURL: artworkUrl,
            collectionViewURL: websiteUrl,
            appleID: appleId,
            podcastIndexID: podcastIndexId,
            podcastGUID: podcastGuid,
            sources: [.podcastIndex],
            feedCandidates: [
                DirectoryFeedCandidate(
                    source: .podcastIndex,
                    feedURL: feedUrl,
                    reportedEpisodeCount: reportedEpisodeCount,
                    reportedUpdatedAt: reportedUpdatedAt.map {
                        Date(timeIntervalSince1970: TimeInterval($0))
                    }
                )
            ]
        )
    }
}
