import Foundation
import OpenCastCore
import Synchronization

/// Scripted `OpenCastHTTPClient`. Every request is logged with the body cap
/// it was sent under, readable without an `await` so `waitUntil` can watch
/// it, then answered with the next scripted response (the last one repeats).
/// While held, requests park until `release()`.
actor StubOpenCastHTTPClient: OpenCastHTTPClient {
    enum Response: Sendable {
        case body(Data, statusCode: Int = 200)
        /// What the streaming client throws once a body passes the cap.
        case oversized
        case transportFailure(URLError.Code)
    }

    private nonisolated let log = Mutex<[(request: URLRequest, maximumBodyByteCount: Int?)]>([])
    private var responses: [Response]
    private var isHolding = false
    private var parkedRequests: [CheckedContinuation<Void, Never>] = []

    init(responses: [Response] = []) {
        self.responses = responses
    }

    nonisolated var requests: [URLRequest] {
        log.withLock { $0.map(\.request) }
    }

    nonisolated var requestCount: Int {
        log.withLock { $0.count }
    }

    /// nil for a request sent through the uncapped `data(for:)`.
    nonisolated var maximumBodyByteCounts: [Int?] {
        log.withLock { $0.map(\.maximumBodyByteCount) }
    }

    func script(_ responses: [Response]) {
        self.responses = responses
    }

    func hold() {
        isHolding = true
    }

    func release() {
        isHolding = false
        let parked = parkedRequests
        parkedRequests.removeAll()
        for continuation in parked {
            continuation.resume()
        }
    }

    func data(for request: URLRequest) async throws -> OpenCastHTTPResult {
        try await respond(to: request, maximumBodyByteCount: nil)
    }

    func data(for request: URLRequest, maximumBodyByteCount: Int) async throws -> OpenCastHTTPResult {
        try await respond(to: request, maximumBodyByteCount: maximumBodyByteCount)
    }

    private func respond(to request: URLRequest, maximumBodyByteCount: Int?) async throws -> OpenCastHTTPResult {
        log.withLock { $0.append((request, maximumBodyByteCount)) }
        let response = responses.count > 1 ? responses.removeFirst() : responses.first
        if isHolding {
            await withCheckedContinuation { parkedRequests.append($0) }
        }

        switch response {
        case .body(let data, let statusCode):
            if let maximumBodyByteCount, data.count > maximumBodyByteCount {
                throw OpenCastHTTPBodyTooLargeError(byteLimit: maximumBodyByteCount)
            }
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
        case .oversized:
            throw OpenCastHTTPBodyTooLargeError(byteLimit: maximumBodyByteCount ?? 0)
        case .transportFailure(let code):
            throw URLError(code)
        case nil:
            throw URLError(.resourceUnavailable)
        }
    }
}
