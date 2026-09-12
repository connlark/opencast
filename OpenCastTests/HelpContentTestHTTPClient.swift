import Foundation
import OpenCastCore

/// Scripted `OpenCastHTTPClient` for help-content tests: hands out one queued
/// response per request, throws once the queue is empty, and counts requests.
actor HelpContentTestHTTPClient: OpenCastHTTPClient {
    enum Response {
        case success(Data, statusCode: Int = 200)
        case failure(any Error & Sendable)
    }

    private var responses: [Response]
    private(set) var requestCount = 0

    init(responses: [Response]) {
        self.responses = responses
    }

    func data(for request: URLRequest) async throws -> OpenCastHTTPResult {
        requestCount += 1
        guard !responses.isEmpty else {
            throw URLError(.badServerResponse)
        }
        switch responses.removeFirst() {
        case .success(let data, let statusCode):
            return OpenCastHTTPResult(
                data: data,
                response: OpenCastHTTPResponse(
                    url: request.url,
                    mimeType: "application/json",
                    expectedContentLength: Int64(data.count),
                    statusCode: statusCode,
                    headers: [:]
                )
            )
        case .failure(let error):
            throw error
        }
    }
}
