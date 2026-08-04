import Foundation

/// Per-task delegate that drives an artwork download without a completion
/// handler (progress callbacks do not fire for convenience tasks) and
/// cancels the moment its size proves oversized: a declared Content-Length
/// over the cap dies on the first progress callback, and an unknown-length
/// stream is cut mid-flight once written bytes pass the cap. Previously the
/// only guard ran in the attachment factory after the full transfer had
/// already been paid for.
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
        // The temporary file is only valid during this callback; the
        // completion must consume (move) it synchronously, exactly like the
        // completion-handler contract it replaces.
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
