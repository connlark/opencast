import Foundation
import Observation
import OpenCastCore

/// The episode detail's feed-declared chapters, loaded on their own key so
/// they render whether or not anyone transcribed the episode, and served
/// only for the episode they were loaded for.
@Observable
final class EpisodePublisherChaptersSectionModel {
    private var loadedEpisodeID: String?
    private var loadedChapters: [EpisodeChapter] = []
    private var loadedSuppressesGeneration = false

    /// The `.task(id:)` key. A feed refresh that changes the episode row,
    /// its `chapters_url` included, moves `cachedAt`.
    func loadKey(episode: EpisodeListItemSnapshot?) -> String {
        guard let episode else {
            return "missing"
        }
        return "\(episode.episodeID)|\(episode.cachedAt.timeIntervalSinceReferenceDate)"
    }

    func chapters(for episodeID: String) -> [EpisodeChapter] {
        loadedEpisodeID == episodeID ? loadedChapters : []
    }

    /// Whether the feed's declaration keeps generated chapters and the
    /// Generate offer away; nil only until this episode's detail read lands.
    /// A declared document suppresses while it resolves, and after, when it
    /// has chapters or could not be read: only a document read fine with
    /// nothing usable in it does not.
    func suppressesGeneration(for episodeID: String) -> Bool? {
        loadedEpisodeID == episodeID ? loadedSuppressesGeneration : nil
    }

    func load(appModel: OpenCastAppModel, episode: EpisodeListItemSnapshot?) async {
        loadedEpisodeID = nil
        loadedChapters = []
        loadedSuppressesGeneration = false

        guard let episode else {
            return
        }
        let detail = await appModel.library.episodeDetail(for: episode.episodeID)
        guard !Task.isCancelled else {
            return
        }
        guard let documentURL = detail?.chaptersURL else {
            loadedEpisodeID = episode.episodeID
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
    }
}
