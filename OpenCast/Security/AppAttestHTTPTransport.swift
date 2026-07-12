import Foundation

nonisolated protocol AppAttestHTTPTransport: Sendable {
    func data(for request: URLRequest) async throws -> (Data, URLResponse)
}

extension URLSession: AppAttestHTTPTransport {}
