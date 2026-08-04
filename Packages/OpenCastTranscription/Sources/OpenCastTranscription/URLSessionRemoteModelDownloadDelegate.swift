import Foundation

nonisolated final class URLSessionRemoteModelDownloadDelegate: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let url: URL
    private let destinationURL: URL
    private let expectedByteCount: Int64
    private let maximumByteCount: Int64
    private let progressInterval: Duration
    private let progress: OpenCastRemoteModelDownloadProgressHandler?

    private let lock = NSLock()
    private var completion: CheckedContinuation<OpenCastRemoteModelResponse, any Error>?
    private var modelResponse: OpenCastRemoteModelResponse?
    private var responseError: (any Error)?
    private var fileHandle: FileHandle?
    private var bytesReceived: Int64 = 0
    private var lastProgressAt: ContinuousClock.Instant?
    private var lastPublishedBytes: Int64?

    init(
        url: URL,
        destinationURL: URL,
        expectedByteCount: Int64,
        maximumByteCount: Int64,
        progressInterval: Duration,
        progress: OpenCastRemoteModelDownloadProgressHandler?
    ) {
        self.url = url
        self.destinationURL = destinationURL
        self.expectedByteCount = expectedByteCount
        self.maximumByteCount = maximumByteCount
        self.progressInterval = progressInterval
        self.progress = progress
    }

    func awaitCompletion(of task: URLSessionDataTask) async throws -> OpenCastRemoteModelResponse {
        try Task.checkCancellation()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                register(continuation)
                task.resume()
            }
        } onCancel: {
            task.cancel()
        }
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        let received = OpenCastRemoteModelResponse(
            statusCode: (response as? HTTPURLResponse)?.statusCode
        )
        guard received.isSuccessfulHTTPResponse else {
            recordResponseError(OpenCastTranscriptionError.remoteModelDownloadFailed(url))
            completionHandler(.cancel)
            return
        }
        guard response.expectedContentLength <= maximumByteCount else {
            recordResponseError(OpenCastTranscriptionError.invalidRemoteManifest(
                "declared content length for \(url.absoluteString) exceeds configured limits"
            ))
            completionHandler(.cancel)
            return
        }

        do {
            FileManager.default.createFile(atPath: destinationURL.path, contents: nil)
            let handle = try FileHandle(forWritingTo: destinationURL)
            lock.withLock {
                modelResponse = received
                fileHandle = handle
            }
            completionHandler(.allow)
        } catch {
            recordResponseError(error)
            completionHandler(.cancel)
        }
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive data: Data
    ) {
        guard responseErrorSnapshot() == nil else {
            return
        }

        do {
            guard let fileHandle = lock.withLock({ fileHandle }) else {
                throw OpenCastTranscriptionError.remoteModelDownloadFailed(url)
            }
            let receivedAfterChunk = lock.withLock { bytesReceived } + Int64(data.count)
            guard receivedAfterChunk <= expectedByteCount,
                  receivedAfterChunk <= maximumByteCount else {
                throw OpenCastTranscriptionError.invalidRemoteManifest(
                    "downloaded byte count for \(url.absoluteString) exceeded configured limits"
                )
            }
            try fileHandle.write(contentsOf: data)
            lock.withLock {
                bytesReceived = receivedAfterChunk
            }
            publishProgressIfNeeded()
        } catch {
            recordResponseError(error)
            dataTask.cancel()
        }
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: (any Error)?
    ) {
        let handle = lock.withLock {
            let claimed = fileHandle
            fileHandle = nil
            return claimed
        }
        try? handle?.close()

        let received = lock.withLock { bytesReceived }
        var resolvedError = responseErrorSnapshot() ?? error
        if resolvedError == nil, received != expectedByteCount {
            resolvedError = OpenCastTranscriptionError.invalidRemoteManifest(
                "downloaded byte count for \(url.absoluteString) was \(received), expected \(expectedByteCount)"
            )
        }

        if let resolvedError {
            resolve(throwing: resolvedError)
        } else if let modelResponse = lock.withLock({ modelResponse }) {
            publishProgressIfNeeded(force: true)
            resolve(returning: modelResponse)
        } else {
            resolve(throwing: OpenCastTranscriptionError.remoteModelDownloadFailed(url))
        }
    }

    private func register(_ continuation: CheckedContinuation<OpenCastRemoteModelResponse, any Error>) {
        lock.withLock {
            completion = continuation
        }
    }

    private func resolve(returning value: OpenCastRemoteModelResponse) {
        let continuation = lock.withLock {
            let claimed = completion
            completion = nil
            return claimed
        }
        continuation?.resume(returning: value)
    }

    private func resolve(throwing error: any Error) {
        let continuation = lock.withLock {
            let claimed = completion
            completion = nil
            return claimed
        }
        continuation?.resume(throwing: error)
    }

    private func recordResponseError(_ error: any Error) {
        lock.withLock {
            responseError = responseError ?? error
        }
    }

    private func responseErrorSnapshot() -> (any Error)? {
        lock.withLock { responseError }
    }

    private func publishProgressIfNeeded(force: Bool = false) {
        guard let progress else {
            return
        }

        let published: Int64? = lock.withLock {
            guard lastPublishedBytes != bytesReceived else {
                return nil
            }
            let now = ContinuousClock.now
            if !force,
               let lastProgressAt,
               lastProgressAt.duration(to: now) < progressInterval {
                return nil
            }
            lastProgressAt = now
            lastPublishedBytes = bytesReceived
            return bytesReceived
        }

        if let published {
            progress(published)
        }
    }
}
