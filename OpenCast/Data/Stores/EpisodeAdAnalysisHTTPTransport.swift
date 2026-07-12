import Foundation

nonisolated protocol EpisodeAdAnalysisHTTPTransport: Sendable {
    func data(for request: URLRequest) async throws -> (Data, URLResponse)
}

extension URLSession: EpisodeAdAnalysisHTTPTransport {}
