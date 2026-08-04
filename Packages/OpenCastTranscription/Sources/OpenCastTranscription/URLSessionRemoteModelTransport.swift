import Foundation

struct URLSessionRemoteModelTransport: OpenCastRemoteModelTransport {
    nonisolated private static let progressInterval: Duration = .milliseconds(250)

    var session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    func data(from url: URL) async throws -> OpenCastRemoteModelDataResponse {
        let (data, response) = try await session.data(from: url)
        return OpenCastRemoteModelDataResponse(
            data: data,
            response: OpenCastRemoteModelResponse(statusCode: (response as? HTTPURLResponse)?.statusCode)
        )
    }

    func download(
        from url: URL,
        to destinationURL: URL,
        expectedByteCount: Int64,
        maximumByteCount: Int64,
        progress: OpenCastRemoteModelDownloadProgressHandler?
    ) async throws -> OpenCastRemoteModelResponse {
        try await Self.performDownload(
            session: session,
            url: url,
            destinationURL: destinationURL,
            expectedByteCount: expectedByteCount,
            maximumByteCount: maximumByteCount,
            progress: progress
        )
    }

    @concurrent
    private static func performDownload(
        session: URLSession,
        url: URL,
        destinationURL: URL,
        expectedByteCount: Int64,
        maximumByteCount: Int64,
        progress: OpenCastRemoteModelDownloadProgressHandler?
    ) async throws -> OpenCastRemoteModelResponse {
        try Task.checkCancellation()
        let delegate = URLSessionRemoteModelDownloadDelegate(
            url: url,
            destinationURL: destinationURL,
            expectedByteCount: expectedByteCount,
            maximumByteCount: maximumByteCount,
            progressInterval: progressInterval,
            progress: progress
        )
        let task = session.dataTask(with: URLRequest(url: url))
        task.delegate = delegate

        do {
            return try await delegate.awaitCompletion(of: task)
        } catch let error as URLError where error.code == .cancelled && Task.isCancelled {
            try? FileManager.default.removeItem(at: destinationURL)
            throw CancellationError()
        } catch {
            try? FileManager.default.removeItem(at: destinationURL)
            throw error
        }
    }
}
