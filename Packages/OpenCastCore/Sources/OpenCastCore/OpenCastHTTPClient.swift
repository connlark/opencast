import Foundation

public protocol OpenCastHTTPClient: Sendable {
    func data(for request: URLRequest) async throws -> OpenCastHTTPResult
}
