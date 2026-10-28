import Foundation
import SwiftData

/// A show's playback settings, saved first and applied after: when an
/// episode of that show is loaded it takes the new speed at once. Skips wait
/// for the next load.
extension OpenCastAppModel {
    /// A nil `rateOverride` returns the show to the global speed.
    @discardableResult
    func setPodcastPlaybackSettings(
        _ skipSettings: PodcastPlaybackSkipSettings,
        rateOverride: Float?,
        feedURL: String,
        modelContext: ModelContext
    ) -> Bool {
        guard library.setPodcastPlaybackSettings(
            skipSettings,
            rateOverride: rateOverride,
            feedURL: feedURL,
            modelContext: modelContext
        ) else {
            return false
        }
        refreshPlaybackSettingsIfPlaying(feedURL: feedURL, modelContext: modelContext)
        return true
    }

    /// A rate gives the show its own speed; nil returns it to the global
    /// speed.
    @discardableResult
    func setPodcastPlaybackRateOverride(
        _ rate: Float?,
        feedURL: String,
        modelContext: ModelContext
    ) -> Bool {
        guard library.setPodcastPlaybackRateOverride(rate, feedURL: feedURL, modelContext: modelContext) else {
            return false
        }
        refreshPlaybackSettingsIfPlaying(feedURL: feedURL, modelContext: modelContext)
        return true
    }

    private func refreshPlaybackSettingsIfPlaying(feedURL: String, modelContext: ModelContext) {
        guard playback.currentEpisode?.podcastID.rawValue == feedURL else {
            return
        }
        refreshCurrentPlaybackSettings(modelContext: modelContext)
    }
}
