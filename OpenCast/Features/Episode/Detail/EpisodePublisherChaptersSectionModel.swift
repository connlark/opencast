import Foundation
import Observation
import OpenCastCore

@Observable
final class EpisodePublisherChaptersSectionModel {
    private var loadedEpisodeID: String?
    private var loadedChapters: [EpisodeChapter] = []
    private var loadedSuppressesGeneration = false
    private var finishedKey: String?

    /// A feed refresh that changes the episode row, `chapters_url` included, moves `cachedAt`.
    func loadKey(episode: EpisodeListItemSnapshot?) -> String {
        guard let episode else {
            return "missing"
        }
        return "\(episode.episodeID)|\(episode.cachedAt.timeIntervalSinceReferenceDate)"
    }

    func chapters(for episodeID: String) -> [EpisodeChapter] {
        loadedEpisodeID == episodeID ? loadedChapters : []
    }

    /// Nil until this episode's detail read lands.
    func suppressesGeneration(for episodeID: String) -> Bool? {
        loadedEpisodeID == episodeID ? loadedSuppressesGeneration : nil
    }

    /// Keyed like the load, not by episode: after a feed refresh moves the key, the new key
    /// stays unfinished until its own load settles, even before that load starts.
    func isFinished(forKey key: String) -> Bool {
        finishedKey == key
    }

    func load(appModel: OpenCastAppModel, episode: EpisodeListItemSnapshot?, key: String) async {
        loadedEpisodeID = nil
        loadedChapters = []
        loadedSuppressesGeneration = false
        finishedKey = nil

        guard let episode else {
            return
        }
        let detail = await appModel.library.episodeDetail(for: episode.episodeID)
        guard !Task.isCancelled else {
            return
        }
        guard let documentURL = detail?.chaptersURL else {
            loadedEpisodeID = episode.episodeID
            finishedKey = key
            return
        }
        loadedEpisodeID = episode.episodeID
        loadedSuppressesGeneration = true

        let resolution = await appModel.publisherChapters.resolve(
            episodeID: episode.episodeID,
            documentURL: documentURL
        )
        guard !Task.isCancelled else {
            return
        }
        switch resolution {
        case .chapters(let chapters):
            loadedChapters = chapters
            loadedSuppressesGeneration = true
        case .unavailable:
            loadedSuppressesGeneration = true
        case .documentEmpty:
            loadedSuppressesGeneration = false
        }
        loadedEpisodeID = episode.episodeID
        finishedKey = key
    }
}
