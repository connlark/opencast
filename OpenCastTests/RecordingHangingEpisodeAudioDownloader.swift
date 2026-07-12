import Foundation
@testable import OpenCast

final class RecordingHangingEpisodeAudioDownloader: EpisodeAudioDownloading, @unchecked Sendable {
    private let lock = NSLock()
    private var recordedRequestCount = 0

    nonisolated func download(
        from sourceURL: URL,
        to temporaryURL: URL,
        resume: EpisodeDownloadResumeContext?,
        onResponseMetadata: @escaping @MainActor @Sendable (EpisodeDownloadResponseMetadata) -> Void,
        progress: @escaping @MainActor @Sendable (_ bytesReceived: Int64, _ bytesExpected: Int64?) -> Void
    ) async throws {
        lock.withLock {
            recordedRequestCount += 1
        }
        await onResponseMetadata(EpisodeDownloadResponseMetadata(entityTag: "request-test", lastModified: nil))
        while true {
            try Task.checkCancellation()
            try await Task.sleep(for: .seconds(1))
        }
    }

    nonisolated var requestCount: Int {
        lock.withLock { recordedRequestCount }
    }
}
