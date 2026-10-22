import Foundation
import Observation
import OpenCastCore
import OpenCastPlayback

@Observable
final class PlaybackChaptersCoordinator {
    private(set) var current: PlaybackChapterList = .empty

    @ObservationIgnored private let playback: AVFoundationPlaybackController
    @ObservationIgnored private let library: LibraryStore
    @ObservationIgnored private let transcriptions: EpisodeTranscriptionStore
    @ObservationIgnored private let transcriptAnalyses: EpisodeTranscriptAnalysisStore
    /// UI-test seam: served for every episode in place of any real lookup.
    @ObservationIgnored var uiTestOverride: PlaybackChapterList?
    @ObservationIgnored private var refreshTask: Task<Void, Never>?
    @ObservationIgnored private var itemObservationTask: Task<Void, Never>?
    @ObservationIgnored private var installedEpisodeID: String?
    @ObservationIgnored private var installedItemGeneration: Int?

    init(
        playback: AVFoundationPlaybackController,
        library: LibraryStore,
        transcriptions: EpisodeTranscriptionStore,
        transcriptAnalyses: EpisodeTranscriptAnalysisStore
    ) {
        self.playback = playback
        self.library = library
        self.transcriptions = transcriptions
        self.transcriptAnalyses = transcriptAnalyses
        startItemObservation()
    }

    deinit {
        itemObservationTask?.cancel()
    }

    func refreshForCurrentEpisode() {
        refreshTask?.cancel()
        guard let episode = playback.currentEpisode else {
            refreshTask = nil
            install(.empty, forEpisodeID: nil, itemGeneration: nil)
            return
        }

        let episodeID = episode.id.rawValue
        let itemGeneration = playback.currentItemGeneration
        // A list belongs to one player item. A download switch or a
        // failed-item rebuild changes the audio under the same episode, so
        // the old list clears until the new item's read lands.
        if installedEpisodeID != episodeID || installedItemGeneration != itemGeneration {
            install(.empty, forEpisodeID: episodeID, itemGeneration: itemGeneration)
        }
        refreshTask = Task { [weak self] in
            guard let self else {
                return
            }
            let list = await load(episodeID: episodeID)
            guard !Task.isCancelled,
                  playback.currentEpisode?.id.rawValue == episodeID,
                  playback.currentItemGeneration == itemGeneration
            else {
                return
            }
            install(list, forEpisodeID: episodeID, itemGeneration: itemGeneration)
        }
    }

    func refreshIfCurrentEpisode(episodeID: String) {
        guard playback.currentEpisode?.id.rawValue == episodeID else {
            return
        }
        refreshForCurrentEpisode()
    }

    /// Awaits the in-flight refresh, if any. Test hook.
    func waitForRefresh() async {
        await refreshTask?.value
    }

    /// Follows the player item itself, because not every install goes
    /// through the app model: a failed item is rebuilt inside the
    /// controller, and `unload()` has no refresh call of its own.
    private func startItemObservation() {
        let playback = playback
        itemObservationTask = Task { [weak self] in
            var lastGeneration = playback.currentItemGeneration
            for await generation in Observations({ playback.currentItemGeneration }) {
                guard !Task.isCancelled, let self else {
                    return
                }
                guard generation != lastGeneration else {
                    continue
                }
                lastGeneration = generation
                refreshForCurrentEpisode()
            }
        }
    }

    private func load(episodeID: String) async -> PlaybackChapterList {
        if let uiTestOverride {
            return uiTestOverride
        }
        if let embedded = try? await playback.loadCurrentItemChapters(), !embedded.isEmpty {
            return PlaybackChapterList(chapters: embedded, source: .embedded)
        }
        guard !Task.isCancelled else {
            return .empty
        }

        // Creator-declared chapters win over generated ones even though the
        // document isn't fetched yet; same rule the detail cards follow.
        if await library.episodeDetail(for: episodeID)?.chaptersURL != nil {
            return .empty
        }

        guard transcriptAnalyses.record(for: episodeID)?.state == .completed,
              let transcriptDocument = try? await transcriptions.loadDocument(for: episodeID),
              let analysisDocument = try? await transcriptAnalyses.loadDocument(for: episodeID),
              !analysisDocument.chapters.isEmpty,
              await transcriptAnalyses.isCurrentAnalysisDocumentOffCaller(analysisDocument, for: transcriptDocument)
        else {
            return .empty
        }

        return PlaybackChapterList(
            chapters: analysisDocument.chapters.map(EpisodeChapter.init),
            source: .generated(transcriptSourceSHA256: transcriptDocument.sourceFileSHA256)
        )
    }

    private func install(_ list: PlaybackChapterList, forEpisodeID episodeID: String?, itemGeneration: Int?) {
        guard playback.currentEpisode?.id.rawValue == episodeID else {
            return
        }
        current = list
        installedEpisodeID = episodeID
        installedItemGeneration = itemGeneration
    }
}

extension EpisodeChapter {
    /// Generated chapters carry transcript segment bounds the player doesn't
    /// need; only the display fields and times cross over.
    init(_ chapter: EpisodeTranscriptAnalysisChapter) {
        self.init(
            id: chapter.id,
            title: chapter.title,
            startTime: chapter.startTime,
            endTime: chapter.endTime
        )
    }
}
