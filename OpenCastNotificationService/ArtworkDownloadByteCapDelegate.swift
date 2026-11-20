import Foundation

final class ArtworkDownloadByteCapDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let maxArtworkBytes: Int64
    private let lock = NSLock()
    private var completion: (@Sendable (URL?, URLResponse?, (any Error)?) -> Void)?

    init(
        maxArtworkBytes: Int,
        completion: @escaping @Sendable (URL?, URLResponse?, (any Error)?) -> Void
    ) {
        self.maxArtworkBytes = Int64(maxArtworkBytes)
        self.completion = completion
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        if totalBytesExpectedToWrite != NSURLSessionTransferSizeUnknown,
           totalBytesExpectedToWrite > maxArtworkBytes {
            downloadTask.cancel()
            return
        }
        if totalBytesWritten > maxArtworkBytes {
            downloadTask.cancel()
        }
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        // The temporary file is valid only during this callback, so the completion must move it
        // synchronously.
        takeCompletion()?(location, downloadTask.response, nil)
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: (any Error)?
    ) {
        guard let error else {
            // Success already resolved through didFinishDownloadingTo.
            return
        }
        takeCompletion()?(nil, task.response, error)
    }

    private func takeCompletion() -> (@Sendable (URL?, URLResponse?, (any Error)?) -> Void)? {
        lock.lock()
        defer { lock.unlock() }
        let taken = completion
        completion = nil
        return taken
    }
}
