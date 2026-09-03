import Foundation

// @unchecked: the sole stored state is an immutable, thread-safe URLSession.
public final class URLSessionOpenCastHTTPClient: OpenCastHTTPClient, @unchecked Sendable {
    private let session: URLSession

    public convenience init(
        configuration: URLSessionConfiguration = OpenCastURLSessionFactory.sharedConfiguration()
    ) {
        self.init(session: URLSession(configuration: configuration))
    }

    public init(session: URLSession) {
        self.session = session
    }

    public func data(for request: URLRequest) async throws -> OpenCastHTTPResult {
        let (data, response) = try await session.data(for: request)
        return OpenCastHTTPResult(data: data, response: OpenCastHTTPResponse(response))
    }

    public func data(
        for request: URLRequest,
        maximumBodyByteCount: Int
    ) async throws -> OpenCastHTTPResult {
        let (bytes, response) = try await session.bytes(for: request)
        func failTooLarge() -> OpenCastHTTPBodyTooLargeError {
            bytes.task.cancel()
            return OpenCastHTTPBodyTooLargeError(byteLimit: maximumBodyByteCount)
        }
        guard response.expectedContentLength <= Int64(maximumBodyByteCount) else {
            throw failTooLarge()
        }

        var data = Data()
        data.reserveCapacity(min(max(Int(response.expectedContentLength), 0), maximumBodyByteCount))
        // Accumulate through a fixed-size buffer: per-byte Data.append costs
        // a retain/resize dance per call, and feeds run to megabytes.
        var chunk: [UInt8] = []
        let chunkCapacity = 64 * 1_024
        chunk.reserveCapacity(chunkCapacity)
        for try await byte in bytes {
            chunk.append(byte)
            if chunk.count == chunkCapacity {
                data.append(contentsOf: chunk)
                chunk.removeAll(keepingCapacity: true)
                guard data.count <= maximumBodyByteCount else {
                    throw failTooLarge()
                }
            }
        }
        data.append(contentsOf: chunk)
        guard data.count <= maximumBodyByteCount else {
            throw failTooLarge()
        }
        return OpenCastHTTPResult(data: data, response: OpenCastHTTPResponse(response))
    }
}
