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
    @ObservationIgnored private var installedEpisodeID: String?

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
    }

    func refreshForCurrentEpisode() {
        refreshTask?.cancel()
        guard let episode = playback.currentEpisode else {
            refreshTask = nil
            install(.empty, forEpisodeID: nil)
            return
        }

        let episodeID = episode.id.rawValue
        if installedEpisodeID != episodeID {
            install(.empty, forEpisodeID: episodeID)
        }
        refreshTask = Task { [weak self] in
            guard let self else {
                return
            }
            let list = await load(episodeID: episodeID)
            guard !Task.isCancelled, playback.currentEpisode?.id.rawValue == episodeID else {
                return
            }
            install(list, forEpisodeID: episodeID)
        }
    }

    func refreshIfCurrentEpisode(episodeID: String) {
        guard playback.currentEpisode?.id.rawValue == episodeID else {
            return
        }
        refreshForCurrentEpisode()
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

    private func install(_ list: PlaybackChapterList, forEpisodeID episodeID: String?) {
        guard playback.currentEpisode?.id.rawValue == episodeID else {
            return
        }
        current = list
        installedEpisodeID = episodeID
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
