import Foundation
import OpenCastCore

nonisolated final class URLSessionEpisodeAudioDownloadDelegate: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    struct ProgressUpdate: Sendable {
        let bytesReceived: Int64
        let bytesExpected: Int64?
    }

    struct RestartRequired: Error, Sendable {}

    private let lock = NSLock()
    private let temporaryURL: URL
    private let resumeOffset: Int64
    private let resume: EpisodeDownloadResumeContext?
    private let progressInterval: Duration
    private let progressContinuation: AsyncStream<ProgressUpdate>.Continuation
    private let onResponseMetadata: @MainActor @Sendable (EpisodeDownloadResponseMetadata) -> Void

    private var completion: CheckedContinuation<Void, any Error>?
    private var responseError: (any Error)?
    private var fileHandle: FileHandle?
    private var bytesReceived: Int64
    private var bytesExpected: Int64?
    private var validatesExpectedByteCount = false
    private var lastProgressAt: ContinuousClock.Instant?
    private var lastPublishedBytes: Int64?

    init(
        temporaryURL: URL,
        resumeOffset: Int64,
        resume: EpisodeDownloadResumeContext?,
        progressInterval: Duration,
        progressContinuation: AsyncStream<ProgressUpdate>.Continuation,
        onResponseMetadata: @escaping @MainActor @Sendable (EpisodeDownloadResponseMetadata) -> Void
    ) {
        self.temporaryURL = temporaryURL
        self.resumeOffset = resumeOffset
        self.resume = resume
        self.progressInterval = progressInterval
        self.progressContinuation = progressContinuation
        self.onResponseMetadata = onResponseMetadata
        bytesReceived = resumeOffset
    }

    func awaitCompletion(of task: URLSessionDataTask) async throws {
        try Task.checkCancellation()
        try await withTaskCancellationHandler {
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
        let responseDisposition = URLSessionResponseDispositionHandler(completionHandler)
        do {
            let normalizedResponse = OpenCastHTTPResponse(response)
            let policy = EpisodeDownloadResumeResponsePolicy.evaluate(
                statusCode: normalizedResponse.statusCode ?? -1,
                resumeOffset: resumeOffset,
                headers: normalizedResponse.headers
            )
            let metadata: EpisodeDownloadResponseMetadata

            switch policy {
            case .append(let expectedBytes):
                try validateContentEncoding(in: normalizedResponse)
                try openFileForAppend()
                self.bytesExpected = expectedBytes
                validatesExpectedByteCount = true
                let responseMetadata = responseMetadata(from: normalizedResponse)
                metadata = EpisodeDownloadResponseMetadata(
                    entityTag: responseMetadata.entityTag ?? resume?.entityTag,
                    lastModified: responseMetadata.lastModified ?? resume?.lastModified
                )
            case .restart(let expectedBytes, false):
                try validateContentEncoding(in: normalizedResponse)
                try openFileForRestart()
                bytesReceived = 0
                let responseExpectedBytes = normalizedResponse.expectedContentLength
                self.bytesExpected = expectedBytes
                    ?? (responseExpectedBytes >= 0 ? responseExpectedBytes : nil)
                validatesExpectedByteCount = normalizedResponse.statusCode == 206
                metadata = responseMetadata(from: normalizedResponse)
            case .restart(_, true):
                recordResponseError(RestartRequired())
                responseDisposition.resolve(.cancel)
                return
            case .fail(let statusCode):
                recordResponseError(EpisodeDownloadError.invalidHTTPStatus(statusCode))
                responseDisposition.resolve(.cancel)
                return
            }

            // Not dead code: onResponseMetadata runs on this task, and the
            // store's restart handling may cancel the current task from
            // inside that callback (pinned by the metadata-race leg of the
            // append/restart downloader test). The check must come after the
            // callback so that cancellation resolves .cancel before any body
            // bytes append to the truncated partial.
            Task { @MainActor [self] in
                onResponseMetadata(metadata)
                if Task.isCancelled {
                    recordResponseError(CancellationError())
                    responseDisposition.resolve(.cancel)
                } else {
                    responseDisposition.resolve(.allow)
                }
            }
        } catch {
            recordResponseError(error)
            responseDisposition.resolve(.cancel)
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
            guard let fileHandle else {
                throw EpisodeDownloadError.interrupted
            }
            try fileHandle.write(contentsOf: data)
            bytesReceived += Int64(data.count)
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
        try? fileHandle?.close()
        fileHandle = nil
        publishProgressIfNeeded(force: true)
        progressContinuation.finish()

        let resolvedError = responseErrorSnapshot() ?? error
        if resolvedError == nil,
           validatesExpectedByteCount,
           let bytesExpected,
           bytesReceived != bytesExpected {
            resolve(throwing: EpisodeDownloadError.interrupted)
        } else if let resolvedError {
            resolve(throwing: resolvedError)
        } else {
            resolve(returning: ())
        }
    }

    private func register(_ continuation: CheckedContinuation<Void, any Error>) {
        lock.withLock {
            completion = continuation
        }
    }

    private func resolve(returning value: Void) {
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

    private func openFileForAppend() throws {
        let handle = try FileHandle(forWritingTo: temporaryURL)
        let offset = try handle.seekToEnd()
        guard offset == UInt64(resumeOffset) else {
            try? handle.close()
            throw EpisodeDownloadError.invalidDownloadedRecord
        }
        fileHandle = handle
    }

    private func openFileForRestart() throws {
        FileManager.default.createFile(atPath: temporaryURL.path, contents: nil)
        let handle = try FileHandle(forWritingTo: temporaryURL)
        try handle.truncate(atOffset: 0)
        fileHandle = handle
    }

    private func publishProgressIfNeeded(force: Bool = false) {
        guard lastPublishedBytes != bytesReceived else {
            return
        }

        let now = ContinuousClock.now
        if !force,
           let lastProgressAt,
           lastProgressAt.duration(to: now) < progressInterval {
            return
        }

        lastProgressAt = now
        lastPublishedBytes = bytesReceived
        progressContinuation.yield(ProgressUpdate(
            bytesReceived: bytesReceived,
            bytesExpected: bytesExpected
        ))
    }

    private func responseMetadata(
        from response: OpenCastHTTPResponse
    ) -> EpisodeDownloadResponseMetadata {
        EpisodeDownloadResponseMetadata(
            entityTag: response.headerValue("etag"),
            lastModified: response.headerValue("last-modified")
        )
    }

    private func validateContentEncoding(
        in response: OpenCastHTTPResponse
    ) throws {
        guard let contentEncoding = response.headerValue("content-encoding")?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              contentEncoding.isEmpty == false,
              contentEncoding.caseInsensitiveCompare("identity") != .orderedSame
        else {
            return
        }
        throw EpisodeDownloadError.unsupportedContentEncoding
    }
}

nonisolated private final class URLSessionResponseDispositionHandler: @unchecked Sendable {
    private let lock = NSLock()
    private var handler: ((URLSession.ResponseDisposition) -> Void)?

    init(_ handler: @escaping (URLSession.ResponseDisposition) -> Void) {
        self.handler = handler
    }

    func resolve(_ disposition: URLSession.ResponseDisposition) {
        let claimedHandler = lock.withLock {
            let claimedHandler = handler
            handler = nil
            return claimedHandler
        }
        claimedHandler?(disposition)
    }
}
