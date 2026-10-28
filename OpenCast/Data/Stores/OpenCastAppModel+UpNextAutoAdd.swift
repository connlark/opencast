import Foundation
import SwiftData

/// The per-show position is synced; the watermark, the limit and the rule
/// stay on this device.
extension OpenCastAppModel {
    /// A position turns the show on (queuing nothing until its next
    /// release) or moves it; nil turns it off. A false leaves the message in
    /// `library.lastErrorMessage` when the synced save failed, else in
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

    /// Waits for hydration, a loaded library and playback restoration.
    /// Before the settings store has loaded, every show that is on would
    /// look watermark-less and be reset to its newest release, losing the
    /// releases since the last pass; with the library unloaded every show
    /// would look off and lose its watermark the same way; before
    /// restoration, the episode about to be restored is not current yet and
    /// would also be queued. A failed queue save surfaces through the Up
    /// Next alert.
    func runUpNextAutoAddPass(modelContext: ModelContext) {
        guard coreStoresHydrated, hasLoadedLibrary, hasRestoredPlaybackSurface else {
            return
        }
        if let message = upNextAutoAdd.runPass(modelContext: modelContext) {
            lastUpNextError = message
        }
    }
}
