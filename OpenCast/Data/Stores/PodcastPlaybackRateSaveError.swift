import Foundation

/// A show's speed that could not be saved, carrying the library's message
/// to the playback settings error.
nonisolated struct PodcastPlaybackRateSaveError: LocalizedError {
    let message: String

    var errorDescription: String? {
        message
    }
}
