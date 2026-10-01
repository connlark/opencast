import Foundation
import SwiftData

final class OpenCastSystemActionRouter {
    private unowned let appModel: OpenCastAppModel

    init(appModel: OpenCastAppModel) {
        self.appModel = appModel
    }

    /// All system adapters join the same app-owned hydration task. Resolution
    /// happens after the await so deletion during a cold launch cannot replay
    /// a stale entity, and cancellation cannot start playback afterward.
    func perform(_ action: OpenCastSystemAction, modelContext: ModelContext) async throws {
        try Task.checkCancellation()
        await appModel.ensurePlaybackSurfaceHydrated(modelContext: modelContext)
        try Task.checkCancellation()
        if case .failed = appModel.library.state, appModel.library.subscriptions.isEmpty {
            throw OpenCastSystemActionError.libraryUnavailable
        }
        switch action {
        case .search(let query):
            appModel.systemSearchRequest = OpenCastSearchRequest(query: String(query.prefix(256)))
        case .enqueue(let id), .enqueueNext(let id):
            let episode = try availableEpisode(id)
            // A retried intent must not move an already queued episode.
            guard !appModel.upNextQueue.items.contains(where: { $0.episodeID == id }) else { return }
            let saved = if case .enqueueNext = action {
                appModel.upNextQueue.enqueueNext(episode, modelContext: modelContext)
            } else {
                appModel.upNextQueue.enqueueLast(episode, modelContext: modelContext)
            }
            guard saved else {
                throw OpenCastSystemActionError.queueFailed
            }
        case .playEpisode(let id):
            try play(availableEpisode(id), modelContext: modelContext)
        case .playLatest(let id):
            guard appModel.library.isActivelySubscribed(to: id) else {
                throw OpenCastSystemActionError.unavailable
            }
            guard let episode = appModel.library.episodes(forPodcastID: id)
                .filter({ !appModel.library.progressSummary(for: $0).isCompleted })
                .sorted(by: OpenCastEntityCatalog.newestFirst).first
            else { throw OpenCastSystemActionError.noUnplayedEpisode }
            try play(episode, modelContext: modelContext)
        case .resume:
            guard let id = appModel.playback.currentEpisode?.id.rawValue else {
                throw OpenCastSystemActionError.unavailable
            }
            try play(availableEpisode(id), modelContext: modelContext)
        case .playPlaylist(let playlistID):
            guard appModel.playlist(playlistID) != nil else { throw OpenCastSystemActionError.unavailable }
            guard appModel.hasPlaylistPlaybackCandidates(playlistID) else {
                throw OpenCastSystemActionError.playlistHasNoUnplayedEpisodes
            }
            let before = playbackIdentity()
            let upNextErrorBefore = appModel.lastUpNextError
            guard appModel.playPlaylist(playlistID, mode: .replace, shuffle: false, presentsNowPlaying: false, modelContext: modelContext) else {
                // A false return after the first episode started means the queue
                // clear or pour failed; the listener hears the episode either way.
                // A start that happened moved the episode or the source, or, when
                // it reloaded the episode already playing from this playlist,
                // only the pour could have written the Up Next error.
                let after = playbackIdentity()
                let pourFailed = after != before || appModel.lastUpNextError != upNextErrorBefore
                if after.episodeID != nil, after.sourcePlaylistID == playlistID, pourFailed {
                    throw OpenCastSystemActionError.queueFailed
                }
                throw OpenCastSystemActionError.playbackFailed
            }
            try requirePlaybackStarted()
        case .addToPlaylist(let episodeID, let playlistID):
            let episode = try availableEpisode(episodeID)
            guard let playlist = appModel.playlist(playlistID) else { throw OpenCastSystemActionError.unavailable }
            guard playlist.kind == .manual else { throw OpenCastSystemActionError.smartPlaylistRejectsEpisodes }
            // The already-a-member zero neither sets nor clears the store's
            // message, so a stale one is dropped first; a zero with a fresh
            // message is a failure, a zero without one is idempotent success.
            _ = appModel.playlists.consumeLastErrorMessage()
            let added = appModel.playlists.add([episode], to: playlistID, modelContext: modelContext)
            if added == 0, appModel.playlists.consumeLastErrorMessage() != nil {
                throw OpenCastSystemActionError.playlistFailed
            }
        }
    }

    private func availableEpisode(_ id: String) throws -> EpisodeListItemSnapshot {
        guard let episode = appModel.episodeSnapshot(for: id),
              appModel.library.isActivelySubscribed(to: episode.podcastID)
        else { throw OpenCastSystemActionError.unavailable }
        return episode
    }

    private func play(_ episode: EpisodeListItemSnapshot, modelContext: ModelContext) throws {
        if appModel.playback.currentEpisode?.id.rawValue == episode.episodeID {
            appModel.playback.play()
        } else {
            do {
                try appModel.playEpisode(episode, presentsNowPlaying: false, modelContext: modelContext)
            } catch {
                throw OpenCastSystemActionError.playbackFailed
            }
        }
        try requirePlaybackStarted()
    }

    private func playbackIdentity() -> (episodeID: String?, sourcePlaylistID: String?) {
        (appModel.playback.currentEpisode?.id.rawValue, appModel.currentPlaylistSourceID)
    }

    private func requirePlaybackStarted() throws {
        guard appModel.playback.currentEpisode != nil else { throw OpenCastSystemActionError.playbackFailed }
        if case .failed = appModel.playback.state { throw OpenCastSystemActionError.playbackFailed }
    }
}
