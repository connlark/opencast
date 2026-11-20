import Foundation
import SwiftData

extension OpenCastAppModel {
    /// On false, the message is in `library.lastErrorMessage` when the synced save failed, else in
    /// `upNextAutoAddSettings.lastErrorMessage`.
    @discardableResult
    func setUpNextAutoAddPosition(
        _ position: UpNextAutoAddPosition?,
        forPodcastID podcastID: String,
        modelContext: ModelContext
    ) -> Bool {
        upNextAutoAdd.setPosition(position, forPodcastID: podcastID, modelContext: modelContext)
    }

    @discardableResult
    func setUpNextAutoAddLimit(_ limit: UpNextAutoAddLimit, modelContext: ModelContext) -> Bool {
        upNextAutoAddSettings.setLimit(limit, modelContext: modelContext)
    }

    @discardableResult
    func setUpNextAutoAddLimitReachedAction(
        _ action: UpNextAutoAddLimitReachedAction,
        modelContext: ModelContext
    ) -> Bool {
        upNextAutoAddSettings.setLimitReachedAction(action, modelContext: modelContext)
    }

    /// Before hydration every show that is on looks watermark-less, and before the library loads
    /// every show looks off; either would reset watermarks. Before playback restoration, the
    /// episode about to be restored would be queued too.
    func runUpNextAutoAddPass(modelContext: ModelContext) {
        guard coreStoresHydrated, hasLoadedLibrary, hasRestoredPlaybackSurface else {
            return
        }
        if let message = upNextAutoAdd.runPass(modelContext: modelContext) {
            lastUpNextError = message
        }
    }
}
