import Foundation
import Observation
import OpenCastPlayback

/// Installs the current episode's ad-analysis skip zones on the player:
/// the auto-skip tier goes to `PlaybackAdSkipPolicy`, the sub-floor tier is
/// published for the timeline only.
@Observable
final class PlaybackSkipZoneCoordinator {
    /// Sub-floor confidence zones for the current episode: rendered dimmed on
    /// the timeline, never handed to `PlaybackAdSkipPolicy`.
    private(set) var displayOnlySkipZones: [PlaybackSkipZone] = []

    @ObservationIgnored private let playback: AVFoundationPlaybackController
    @ObservationIgnored private let transcriptions: EpisodeTranscriptionStore
    @ObservationIgnored private let adAnalyses: EpisodeAdAnalysisStore
    @ObservationIgnored private var refreshTask: Task<Void, Never>?
    /// Which episode the installed zone tiers describe, so a slow document
    /// load can never install zones for a switched-away episode.
    @ObservationIgnored private var installedEpisodeID: String?

    init(
        playback: AVFoundationPlaybackController,
        transcriptions: EpisodeTranscriptionStore,
        adAnalyses: EpisodeAdAnalysisStore
    ) {
        self.playback = playback
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
        if installedEpisodeID != episodeID {
            // `playback.load` already reset the auto-skip policy for a
            // switched episode; reset the display tier with it so both tiers
            // stay coherent while the new episode's documents load.
            install(.empty, forEpisodeID: episodeID)
        }
        let duration = playback.duration ?? episode.duration
        refreshTask = Task { [weak self] in
            guard let self else {
                return
            }

            let tiers = await loadCurrentZoneTiers(episodeID: episodeID, duration: duration)
            guard !Task.isCancelled, playback.currentEpisode?.id.rawValue == episodeID else {
                return
            }
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

    /// The auto-skip zone count a finished pass reports: refreshed live for
    /// the playing episode, otherwise derived from the stored documents.
    func zoneCountAfterPass(for episode: EpisodeListItemSnapshot) async -> Int {
        if playback.currentEpisode?.id.rawValue == episode.episodeID {
            refreshForCurrentEpisode()
            await refreshTask?.value
            return playback.skipZones.count
        }

        return await loadCurrentZoneTiers(
            episodeID: episode.episodeID,
            duration: episode.duration
        ).autoSkip.count
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
        episodeID: String,
        duration: TimeInterval?
    ) async -> EpisodeAdAnalysisZoneTiers {
        guard adAnalyses.record(for: episodeID)?.state == .completed else {
            return .empty
        }
        guard let transcriptDocument = try? await transcriptions.loadDocument(for: episodeID),
              let analysisDocument = try? await adAnalyses.loadDocument(for: episodeID),
              await adAnalyses.isCurrentAnalysisDocumentOffCaller(analysisDocument, for: transcriptDocument)
        else {
            return .empty
        }

        return EpisodeAdAnalysisZoneMapper.zoneTiers(for: analysisDocument, duration: duration)
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
