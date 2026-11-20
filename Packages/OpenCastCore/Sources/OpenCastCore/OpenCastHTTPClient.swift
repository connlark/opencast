import Foundation

public protocol OpenCastHTTPClient: Sendable {
    func feedFile(for request: URLRequest, maximumBodyByteCount: Int) async throws -> OpenCastHTTPFileResult
    func data(for request: URLRequest) async throws -> OpenCastHTTPResult
    /// Throws `OpenCastHTTPBodyTooLargeError` past `maximumBodyByteCount`. A streaming
    /// conformer stops reading as soon as the running count passes the cap, so a chunked
    /// body never buffers unbounded data.
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
