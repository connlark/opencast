import Foundation

public protocol OpenCastHTTPClient: Sendable {
    func data(for request: URLRequest) async throws -> OpenCastHTTPResult
    /// Fetches the body while enforcing `maximumBodyByteCount`, throwing
    /// `OpenCastHTTPBodyTooLargeError` for an oversized response. Streaming
    /// implementations fail fast on a declared oversized `Content-Length`
    /// and cancel the transfer the moment the running byte count exceeds
    /// the cap, so a chunked response never buffers unbounded data.
    func data(
        for request: URLRequest,
        maximumBodyByteCount: Int
    ) async throws -> OpenCastHTTPResult
}

public struct OpenCastHTTPBodyTooLargeError: Error, Equatable {
    public let byteLimit: Int

    public init(byteLimit: Int) {
        self.byteLimit = byteLimit
    }
}

public extension OpenCastHTTPClient {
    /// Fallback for conformers without streaming: buffers the whole body and
    /// enforces the cap after the fact.
    func data(
        for request: URLRequest,
        maximumBodyByteCount: Int
    ) async throws -> OpenCastHTTPResult {
        let result = try await data(for: request)
        guard result.response.expectedContentLength <= Int64(maximumBodyByteCount),
              result.data.count <= maximumBodyByteCount
        else {
            throw OpenCastHTTPBodyTooLargeError(byteLimit: maximumBodyByteCount)
        }
        return result
    }
}
