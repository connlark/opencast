import Foundation
import SwiftData

/// A show's playback settings, saved first and applied after: when an
/// episode of that show is loaded it takes the new speed at once. Skips wait
/// for the next load. The show's device-local Up Next watermark moves with
/// its Auto Add to Up Next value around that save.
extension OpenCastAppModel {
    /// A nil `rateOverride` returns the show to the global speed; a nil
    /// `upNextAutoAdd` turns Auto Add to Up Next off. Turning it on writes
    /// the show's fresh watermark before the synced save, so when that write
    /// fails nothing is saved. Returns nil once everything is saved, else
    /// the message of the step that failed (the library's for the synced
    /// save, the Up Next settings store's for the watermark); saving the
    /// same values again retries that step.
    @discardableResult
    func setPodcastPlaybackSettings(
        _ skipSettings: PodcastPlaybackSkipSettings,
        rateOverride: Float?,
        upNextAutoAdd: UpNextAutoAddPosition?,
        feedURL: String,
        modelContext: ModelContext
    ) -> String? {
        self.upNextAutoAdd.savePosition(upNextAutoAdd, forPodcastID: feedURL, modelContext: modelContext) {
            guard library.setPodcastPlaybackSettings(
                skipSettings,
                rateOverride: rateOverride,
                upNextAutoAdd: upNextAutoAdd,
                feedURL: feedURL,
                modelContext: modelContext
            ) else {
                return false
            }
            refreshPlaybackSettingsIfPlaying(feedURL: feedURL, modelContext: modelContext)
            return true
        }
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
