import Foundation
import Observation
import OpenCastPlayback

@Observable
final class PlaybackSkipZoneCoordinator {
    /// Below the auto-skip confidence floor; never handed to `PlaybackAdSkipPolicy`.
    private(set) var displayOnlySkipZones: [PlaybackSkipZone] = []

    @ObservationIgnored private let playback: AVFoundationPlaybackController
    @ObservationIgnored private let downloads: DownloadStore
    @ObservationIgnored private let transcriptions: EpisodeTranscriptionStore
    @ObservationIgnored private let adAnalyses: EpisodeAdAnalysisStore
    @ObservationIgnored private var refreshTask: Task<Void, Never>?
    @ObservationIgnored private var installedEpisodeID: String?

    init(
        playback: AVFoundationPlaybackController,
        downloads: DownloadStore,
        transcriptions: EpisodeTranscriptionStore,
        adAnalyses: EpisodeAdAnalysisStore
    ) {
        self.playback = playback
        self.downloads = downloads
        self.transcriptions = transcriptions
        self.adAnalyses = adAnalyses
    }

    /// Zones attach a beat after playback starts: the documents load and fingerprint off the main
    /// actor so `play()` never blocks on the decode.
    func refreshForCurrentEpisode() {
        refreshTask?.cancel()
        guard let episode = playback.currentEpisode else {
            refreshTask = nil
            install(.empty, forEpisodeID: nil)
            return
        }

        let episodeID = episode.id.rawValue
        var didSwitchSource = false
        if let download = downloads.record(for: episodeID),
           download.podcastID == episode.podcastID.rawValue,
           let fileURL = downloads.localFileURL(for: download),
           downloads.downloadedFileExists(for: download) {
            didSwitchSource = playback.useDownloadedAudio(at: fileURL, for: episode.id)
        }
        if installedEpisodeID != episodeID || didSwitchSource || !isPlaybackAligned(
            episodeID: episodeID,
            sourceSHA256: transcriptions.record(for: episodeID)?.sourceFileSHA256 ?? ""
        ) {
            // `playback.load` already reset the auto-skip tier; clearing the display tier with it
            // keeps both tiers coherent while the new documents load.
            install(.empty, forEpisodeID: episodeID)
        }
        refreshTask = Task { [weak self] in
            guard let self else {
                return
            }

            let loaded = await loadCurrentZoneTiers(episodeID: episodeID)
            guard !Task.isCancelled, playback.currentEpisode?.id.rawValue == episodeID else {
                return
            }
            // Validate after every suspension: a stream, replacement download,
            // or deleted file must never inherit another audio assembly's times.
            let tiers = isPlaybackAligned(episodeID: episodeID, sourceSHA256: loaded.sourceSHA256)
                ? loaded.tiers : .empty
            install(tiers, forEpisodeID: episodeID)
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

    /// Counts detected zones even when source alignment keeps playback from using them.
    func zoneCountAfterPass(for episode: EpisodeListItemSnapshot) async -> Int {
        if playback.currentEpisode?.id.rawValue == episode.episodeID {
            refreshForCurrentEpisode()
            await refreshTask?.value
        }

        let loaded = await loadCurrentZoneTiers(episodeID: episode.episodeID)
        return loaded.tiers.autoSkip.count
    }

    func undoLastAutoSkip() {
        guard let target = NowPlayingAutoSkipUndo.seekTarget(
            for: playback.lastAutoSkipEvent,
            zones: playback.skipZones
        ) else {
            return
        }

        playback.seek(to: target, intent: NowPlayingAutoSkipUndo.seekIntent)
    }

    private func loadCurrentZoneTiers(
        episodeID: String
    ) async -> (tiers: EpisodeAdAnalysisZoneTiers, sourceSHA256: String) {
        guard adAnalyses.record(for: episodeID)?.state == .completed else {
            return (.empty, "")
        }
        guard let transcriptDocument = try? await transcriptions.loadDocument(for: episodeID),
              let analysisDocument = try? await adAnalyses.loadDocument(for: episodeID, transcript: transcriptDocument),
              await adAnalyses.isCurrentAnalysisDocumentOffCaller(analysisDocument, for: transcriptDocument)
        else {
            return (.empty, "")
        }

        return (
            // Not the RSS duration, which can exclude dynamic ads: the zones describe the
            // transcribed file.
            EpisodeAdAnalysisZoneMapper.zoneTiers(for: analysisDocument, duration: transcriptDocument.audioDuration),
            transcriptDocument.sourceFileSHA256
        )
    }

    private func isPlaybackAligned(episodeID: String, sourceSHA256: String) -> Bool {
        TranscriptSourceAlignment.resolve(
            documentSHA256: sourceSHA256,
            trustedDownloadSHA256: downloads.completedSourceIdentity(for: episodeID)?.sha256,
            downloadFileURL: downloads.record(for: episodeID).flatMap(downloads.localFileURL(for:)),
            playerItemURL: playback.currentItemSourceIdentity?.assetURL
        ) == .verified
    }

    private func install(_ tiers: EpisodeAdAnalysisZoneTiers, forEpisodeID episodeID: String?) {
        let installingEpisodeID = episodeID
        playback.setSkipZones(tiers.autoSkip)
        guard playback.currentEpisode?.id.rawValue == installingEpisodeID else {
            return
        }

        displayOnlySkipZones = tiers.displayOnly
        installedEpisodeID = installingEpisodeID
    }
}
