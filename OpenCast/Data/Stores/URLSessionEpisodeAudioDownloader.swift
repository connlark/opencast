import Foundation
import OpenCastCore

struct URLSessionEpisodeAudioDownloader: EpisodeAudioDownloading, @unchecked Sendable {
    nonisolated private static let localCopyChunkByteCount = 1 * 1_024 * 1_024
    nonisolated private static let progressInterval: Duration = .milliseconds(250)

    private let configuration: URLSessionConfiguration

    init(configuration: URLSessionConfiguration = OpenCastURLSessionFactory.downloadConfiguration()) {
        self.configuration = configuration
    }

    init(session: URLSession) {
        configuration = session.configuration
    }

    @concurrent
    func download(
        from sourceURL: URL,
        to temporaryURL: URL,
        resume: EpisodeDownloadResumeContext?,
        onResponseMetadata: @escaping @MainActor @Sendable (EpisodeDownloadResponseMetadata) -> Void,
        progress: @escaping @MainActor @Sendable (_ bytesReceived: Int64, _ bytesExpected: Int64?) -> Void
    ) async throws {
        if sourceURL.isFileURL {
            await onResponseMetadata(EpisodeDownloadResponseMetadata(entityTag: nil, lastModified: nil))
            try await copyLocalFile(from: sourceURL, to: temporaryURL, progress: progress)
            return
        }

        do {
            try await downloadRemoteFile(
                from: sourceURL,
                to: temporaryURL,
                resume: resume,
                onResponseMetadata: onResponseMetadata,
                progress: progress
            )
        } catch let error as URLError where error.code == .cancelled && Task.isCancelled {
            throw CancellationError()
        }
    }

    @concurrent
    private func downloadRemoteFile(
        from sourceURL: URL,
        to temporaryURL: URL,
        resume: EpisodeDownloadResumeContext?,
        onResponseMetadata: @escaping @MainActor @Sendable (EpisodeDownloadResponseMetadata) -> Void,
        progress: @escaping @MainActor @Sendable (_ bytesReceived: Int64, _ bytesExpected: Int64?) -> Void
    ) async throws {
        let requestedResumeOffset = max(0, resume?.offset ?? 0)
        let ifRangeValidator: String?
        if let entityTag = resume?.entityTag?.trimmingCharacters(in: .whitespacesAndNewlines),
           entityTag.isEmpty == false,
           entityTag.lowercased().hasPrefix("w/") == false {
            ifRangeValidator = entityTag
        } else if let lastModified = resume?.lastModified?.trimmingCharacters(in: .whitespacesAndNewlines),
                  lastModified.isEmpty == false {
            ifRangeValidator = lastModified
        } else {
            ifRangeValidator = nil
        }
        let resumeOffset = ifRangeValidator == nil ? 0 : requestedResumeOffset
        var request = URLRequest(url: sourceURL)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue(OpenCastMediaRequestProfile.acceptEncoding, forHTTPHeaderField: "Accept-Encoding")
        request.setValue(OpenCastMediaRequestProfile.userAgent, forHTTPHeaderField: "User-Agent")
        if resumeOffset > 0 {
            request.setValue("bytes=\(resumeOffset)-", forHTTPHeaderField: "Range")
            request.setValue(ifRangeValidator, forHTTPHeaderField: "If-Range")
        }

        do {
            try await performRemoteRequest(
                request,
                to: temporaryURL,
                resumeOffset: resumeOffset,
                resume: resume,
                onResponseMetadata: onResponseMetadata,
                progress: progress
            )
        } catch is URLSessionEpisodeAudioDownloadDelegate.RestartRequired {
            try await downloadRemoteFile(
                from: sourceURL,
                to: temporaryURL,
                resume: nil,
                onResponseMetadata: onResponseMetadata,
                progress: progress
            )
        }
    }

    @concurrent
    private func performRemoteRequest(
        _ request: URLRequest,
        to temporaryURL: URL,
        resumeOffset: Int64,
        resume: EpisodeDownloadResumeContext?,
        onResponseMetadata: @escaping @MainActor @Sendable (EpisodeDownloadResponseMetadata) -> Void,
        progress: @escaping @MainActor @Sendable (_ bytesReceived: Int64, _ bytesExpected: Int64?) -> Void
    ) async throws {
        let progressStream = AsyncStream<URLSessionEpisodeAudioDownloadDelegate.ProgressUpdate>.makeStream(
            bufferingPolicy: .bufferingNewest(1)
        )
        let delegate = URLSessionEpisodeAudioDownloadDelegate(
            temporaryURL: temporaryURL,
            resumeOffset: resumeOffset,
            resume: resume,
            progressInterval: Self.progressInterval,
            progressContinuation: progressStream.continuation,
            onResponseMetadata: onResponseMetadata
        )
        let delegateQueue = OperationQueue()
        delegateQueue.maxConcurrentOperationCount = 1
        delegateQueue.qualityOfService = .utility
        let requestSession = URLSession(
            configuration: configuration,
            delegate: delegate,
            delegateQueue: delegateQueue
        )
        let dataTask = requestSession.dataTask(with: request)

        defer {
            requestSession.invalidateAndCancel()
        }

        do {
            try await withThrowingTaskGroup(of: Void.self) { group in
                group.addTask {
                    for await update in progressStream.stream {
                        try Task.checkCancellation()
                        await progress(update.bytesReceived, update.bytesExpected)
                    }
                }
                group.addTask {
                    try await delegate.awaitCompletion(of: dataTask)
                }

                do {
                    try await group.waitForAll()
                } catch {
                    group.cancelAll()
                    throw error
                }
            }
        } catch let error as URLError where error.code == .cancelled && Task.isCancelled {
            throw CancellationError()
        }
    }

    @concurrent
    private func copyLocalFile(
        from sourceURL: URL,
        to temporaryURL: URL,
        progress: @escaping @MainActor @Sendable (_ bytesReceived: Int64, _ bytesExpected: Int64?) -> Void
    ) async throws {
        let expectedBytes = try sourceURL.resourceValues(forKeys: [.fileSizeKey]).fileSize.map(Int64.init)
        FileManager.default.createFile(atPath: temporaryURL.path, contents: nil)
        let sourceHandle = try FileHandle(forReadingFrom: sourceURL)
        let destinationHandle = try FileHandle(forWritingTo: temporaryURL)
        defer {
            try? sourceHandle.close()
            try? destinationHandle.close()
        }

        var receivedBytes: Int64 = 0
        var lastProgressAt: ContinuousClock.Instant?
        while let chunk = try sourceHandle.read(upToCount: Self.localCopyChunkByteCount), !chunk.isEmpty {
            try Task.checkCancellation()
            try destinationHandle.write(contentsOf: chunk)
            receivedBytes += Int64(chunk.count)

            let now = ContinuousClock.now
            if lastProgressAt.map({ $0.duration(to: now) >= Self.progressInterval }) ?? true {
                await progress(receivedBytes, expectedBytes)
                lastProgressAt = now
            }
        }
        await progress(receivedBytes, expectedBytes)
    }
}
