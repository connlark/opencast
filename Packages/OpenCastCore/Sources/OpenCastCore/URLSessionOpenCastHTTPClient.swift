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
}
