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
    @ObservationIgnored private let publisherChapters: PublisherChaptersStore
    @ObservationIgnored var uiTestOverride: PlaybackChapterList?
    @ObservationIgnored private var refreshTask: Task<Void, Never>?
    @ObservationIgnored private var itemObservationTask: Task<Void, Never>?
    @ObservationIgnored private var installedEpisodeID: String?
    @ObservationIgnored private var installedItemGeneration: Int?

    init(
        playback: AVFoundationPlaybackController,
        library: LibraryStore,
        transcriptions: EpisodeTranscriptionStore,
        transcriptAnalyses: EpisodeTranscriptAnalysisStore,
        publisherChapters: PublisherChaptersStore
    ) {
        self.playback = playback
        self.library = library
        self.transcriptions = transcriptions
        self.transcriptAnalyses = transcriptAnalyses
        self.publisherChapters = publisherChapters
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
        // A list belongs to one player item: a download switch or failed-item rebuild changes the
        // audio under the same episode, so the old list clears until the new item's read lands.
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

    func waitForRefresh() async {
        await refreshTask?.value
    }

    /// Not every item install goes through the app model: the controller rebuilds a failed item
    /// itself, and `unload()` triggers no refresh.
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

        let detail = await library.episodeDetail(for: episodeID)
        guard !Task.isCancelled else {
            return .empty
        }
        var allowsGeneratedChapters = true
        if let documentURL = detail?.chaptersURL {
            switch await publisherChapters.resolve(episodeID: episodeID, documentURL: documentURL) {
            case .chapters(let chapters):
                // A feed refresh moved the declaration mid-fetch; the next refresh reads the new.
                guard await library.episodeDetail(for: episodeID)?.chaptersURL == documentURL else {
                    return .empty
                }
                return PlaybackChapterList(chapters: chapters, source: .publisher)
            case .unavailable:
                allowsGeneratedChapters = false
            case .documentEmpty:
                break
            }
            guard !Task.isCancelled else {
                return .empty
            }
        }

        if allowsGeneratedChapters, let generated = await currentGeneratedChapters(episodeID: episodeID) {
            return generated
        }
        guard !Task.isCancelled else {
            return .empty
        }

        // Bound by the cached feed duration so the episode screen shows the same list; the player's
        // measured duration lands at no fixed point relative to this read.
        let playing = playback.currentEpisode?.id.rawValue == episodeID ? playback.currentEpisode : nil
        let showNotesChapters = await EpisodeShowNotesContent.resolvingChapters(
            summaryHTML: detail?.listItem.summary ?? playing?.summary,
            showNotesHTML: detail?.showNotesHTML ?? playing?.showNotesHTML,
            duration: detail?.listItem.duration ?? playing?.duration
        )
        guard !Task.isCancelled, !showNotesChapters.isEmpty else {
            return .empty
        }
        return PlaybackChapterList(chapters: showNotesChapters, source: .showNotes)
    }

    private func currentGeneratedChapters(episodeID: String) async -> PlaybackChapterList? {
        guard transcriptAnalyses.record(for: episodeID)?.state == .completed,
              let transcriptDocument = try? await transcriptions.loadDocument(for: episodeID),
              let analysisDocument = try? await transcriptAnalyses.loadDocument(for: episodeID),
              !analysisDocument.chapters.isEmpty,
              await transcriptAnalyses.isCurrentAnalysisDocumentOffCaller(analysisDocument, for: transcriptDocument)
        else {
            return nil
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
    init(_ chapter: EpisodeTranscriptAnalysisChapter) {
        self.init(
            id: chapter.id,
            title: chapter.title,
            startTime: chapter.startTime,
            endTime: chapter.endTime
        )
    }
}
