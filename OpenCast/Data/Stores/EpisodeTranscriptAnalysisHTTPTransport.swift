import Foundation

nonisolated protocol EpisodeTranscriptAnalysisHTTPTransport: Sendable {
    func data(for request: URLRequest) async throws -> (Data, URLResponse)
}

extension URLSession: EpisodeTranscriptAnalysisHTTPTransport {}
