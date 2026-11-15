import Foundation
@testable import OpenCast

/// Completes each download at once with the current `contents`, or fails it
/// when they are nil, and counts the downloads it was asked for. The
/// contents can change between downloads, so a re-download can bring other
/// bytes than the first.
nonisolated final class ScriptedEpisodeAudioDownloader: EpisodeAudioDownloading, @unchecked Sendable {
    struct Failure: LocalizedError {
        var errorDescription: String? {
            "Scripted download failure"
        }
    }

    private let lock = NSLock()
    private var storedContents: Data?
    private var storedRequestCount = 0

    init(contents: Data?) {
        storedContents = contents
    }

    var contents: Data? {
        get { lock.withLock { storedContents } }
        set { lock.withLock { storedContents = newValue } }
    }

    var requestCount: Int {
        lock.withLock { storedRequestCount }
    }

    func download(
        from sourceURL: URL,
        to temporaryURL: URL,
        resume: EpisodeDownloadResumeContext?,
        onResponseMetadata: @escaping @MainActor @Sendable (EpisodeDownloadResponseMetadata) -> Void,
        progress: @escaping @MainActor @Sendable (_ bytesReceived: Int64, _ bytesExpected: Int64?) -> Void
    ) async throws {
        let contents = lock.withLock {
            storedRequestCount += 1
            return storedContents
        }
        guard let contents else {
            throw Failure()
        }
        await onResponseMetadata(EpisodeDownloadResponseMetadata(entityTag: nil, lastModified: nil))
        try contents.write(to: temporaryURL, options: .atomic)
        await progress(Int64(contents.count), Int64(contents.count))
    }
}
