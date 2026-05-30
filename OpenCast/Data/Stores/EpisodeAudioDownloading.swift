import Foundation

protocol EpisodeAudioDownloading: Sendable {
    nonisolated func download(
        from sourceURL: URL,
        to temporaryURL: URL,
        progress: @escaping @MainActor @Sendable (_ bytesReceived: Int64, _ bytesExpected: Int64?) -> Void
    ) async throws
}
