import Foundation

nonisolated struct PodcastPlaybackRateSaveError: LocalizedError {
    let message: String

    var errorDescription: String? {
        message
    }
}
