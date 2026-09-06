import Foundation
import Observation
import OpenCastPlayback

/// Keeps the loaded episode on its completed download and installs matching
/// ad-analysis zones: the auto-skip tier goes to `PlaybackAdSkipPolicy`, while
/// the sub-floor tier is published for the timeline only.
@Observable
final class PlaybackSkipZoneCoordinator {
    /// Sub-floor confidence zones for the current episode: rendered dimmed on
    /// the timeline, never handed to `PlaybackAdSkipPolicy`.
    private(set) var displayOnlySkipZones: [PlaybackSkipZone] = []

    @ObservationIgnored private let playback: AVFoundationPlaybackController
    @ObservationIgnored private let downloads: DownloadStore
    @ObservationIgnored private let transcriptions: EpisodeTranscriptionStore
    @ObservationIgnored private let adAnalyses: EpisodeAdAnalysisStore
    @ObservationIgnored private var refreshTask: Task<Void, Never>?
    /// Which episode the installed zone tiers describe, so a slow document
    /// load can never install zones for a switched-away episode.
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

    /// Zone installation is asynchronous: the transcript and analysis
    /// documents load and fingerprint off the main actor, so `play()` never
    /// blocks on the decode and zones attach a beat after playback starts.
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
            // `playback.load` already reset the auto-skip policy for a
            // switched episode; reset the display tier with it so both tiers
            // stay coherent while the new episode's documents load.
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

    /// Awaits the in-flight refresh, if any. Test hook.
    func waitForRefresh() async {
        await refreshTask?.value
    }

    /// Report detected zones even when source alignment prevents playback
    /// from using them; refresh the playing episode before notifying.
    func zoneCountAfterPass(for episode: EpisodeListItemSnapshot) async -> Int {
        if playback.currentEpisode?.id.rawValue == episode.episodeID {
            refreshForCurrentEpisode()
            await refreshTask?.value
        }

        let loaded = await loadCurrentZoneTiers(episodeID: episode.episodeID)
        return loaded.tiers.autoSkip.count
    }

    /// Pill undo: jump back to the start of the last auto-skipped zone with a
    /// `.scrub`-landing seek so the zone plays through once and re-arms after
    /// exit (existing `PlaybackAdSkipPolicy` disarm semantics).
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
              let analysisDocument = try? await adAnalyses.loadDocument(for: episodeID),
              await adAnalyses.isCurrentAnalysisDocumentOffCaller(analysisDocument, for: transcriptDocument)
        else {
            return (.empty, "")
        }

        return (
            // RSS duration can exclude dynamic ads. These timestamps describe
            // the transcribed file, including its full measured duration.
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
