import Foundation
import SwiftData

extension OpenCastAppModel {
    /// Returns nil once everything is saved, else the message of the step that failed; saving the
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
