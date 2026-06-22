import Foundation
import OpenCastCore
@testable import OpenCast

actor ArtworkDataLoaderProbe {
    private var responses: [(Data, URLResponse?)]
    private var waitsForRelease: Bool
    private var releaseContinuations: [CheckedContinuation<Void, Never>] = []
    private var requestContinuations: [UUID: (
        count: Int,
        continuation: CheckedContinuation<Bool, Never>,
        timeoutTask: Task<Void, Never>
    )] = [:]
    private(set) var requests: [URLRequest] = []
    private(set) var requestCount = 0

    init(
        responses: [(Data, URLResponse?)],
        waitsForRelease: Bool = false
    ) {
        self.responses = responses
        self.waitsForRelease = waitsForRelease
    }

    func load(_ request: URLRequest) async throws -> ArtworkDataResponse {
        requestCount += 1
        requests.append(request)
        resumeRequestContinuations()

        if waitsForRelease {
            await withCheckedContinuation { continuation in
                releaseContinuations.append(continuation)
            }
        }

        guard !responses.isEmpty else {
            throw URLError(.badServerResponse)
        }

        if responses.count == 1 {
            return try artworkDataResponse(from: responses[0], request: request)
        }

        return try artworkDataResponse(from: responses.removeFirst(), request: request)
    }

    func release() {
        let continuations = releaseContinuations
        releaseContinuations.removeAll()
        for continuation in continuations {
            continuation.resume()
        }
    }

    func waitForRequestCount(_ count: Int, timeout: Duration = .seconds(1)) async -> Bool {
        if requestCount >= count {
            return true
        }

        let id = UUID()
        return await withCheckedContinuation { continuation in
            let timeoutTask = Task {
                do {
                    try await Task.sleep(for: timeout)
                } catch is CancellationError {
                    return
                } catch {
                    return
                }

                self.resumeRequestContinuation(id, returning: false)
            }
            requestContinuations[id] = (count, continuation, timeoutTask)
        }
    }

    func cancelAll() {
        release()
        let continuations = requestContinuations
        requestContinuations.removeAll()
        for requestContinuation in continuations.values {
            requestContinuation.timeoutTask.cancel()
            let continuation = requestContinuation.continuation
            continuation.resume(returning: false)
        }
    }

    private func resumeRequestContinuations() {
        let readyContinuations = requestContinuations.filter { requestCount >= $0.value.count }
        for id in readyContinuations.keys {
            requestContinuations.removeValue(forKey: id)?.timeoutTask.cancel()
        }
        for requestContinuation in readyContinuations.values {
            let continuation = requestContinuation.continuation
            continuation.resume(returning: true)
        }
    }

    private func resumeRequestContinuation(_ id: UUID, returning value: Bool) {
        guard let requestContinuation = requestContinuations.removeValue(forKey: id) else {
            return
        }

        requestContinuation.timeoutTask.cancel()
        let continuation = requestContinuation.continuation
        continuation.resume(returning: value)
    }

    private func artworkDataResponse(
        from response: (Data, URLResponse?),
        request: URLRequest
    ) throws -> ArtworkDataResponse {
        guard let url = request.url else {
            throw URLError(.badURL)
        }

        let metadata = response.1.map(OpenCastHTTPResponse.init) ?? OpenCastHTTPResponse(
            url: url,
            mimeType: nil,
            expectedContentLength: Int64(response.0.count),
            statusCode: nil,
            headers: [:]
        )
        return ArtworkDataResponse(data: response.0, response: metadata)
    }
}
