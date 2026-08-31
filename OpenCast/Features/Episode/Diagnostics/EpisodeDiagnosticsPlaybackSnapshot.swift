import Foundation
import OpenCastPlayback

/// Point-in-time capture of the live player taken when diagnostics load; the
/// installed zones here are the post-policy zones actually driving skips.
nonisolated struct EpisodeDiagnosticsPlaybackSnapshot: Sendable, Equatable {
    var loadedEpisodeID: String?
    var stateDescription: String
    var rate: Float
    var position: TimeInterval
    var duration: TimeInterval?
    var assetURL: String?
    var sourceKindDescription: String?
    var itemDuration: TimeInterval?
    var installedAutoSkipZones: [PlaybackSkipZone]
    var displayOnlyZones: [PlaybackSkipZone]
    var lastAutoSkipZoneID: Int?
    var lastAutoSkipSequence: Int?
    var isAutoSkipEnabled: Bool

    func isCurrentEpisode(_ episodeID: String) -> Bool {
        loadedEpisodeID == episodeID
    }
}

extension EpisodeDiagnosticsPlaybackSnapshot {
    static func capturing(from appModel: OpenCastAppModel) -> EpisodeDiagnosticsPlaybackSnapshot {
        let playback = appModel.playback
        let itemIdentity = playback.currentItemSourceIdentity
        return EpisodeDiagnosticsPlaybackSnapshot(
            loadedEpisodeID: playback.currentEpisode?.id.rawValue,
            stateDescription: stateDescription(playback.state),
            rate: playback.rate,
            position: playback.position,
            duration: playback.duration,
            assetURL: itemIdentity?.assetURL.absoluteString,
            sourceKindDescription: itemIdentity.map { kindDescription($0.kind) },
            itemDuration: itemIdentity?.itemDuration,
            installedAutoSkipZones: playback.skipZones,
            displayOnlyZones: appModel.displayOnlySkipZones,
            lastAutoSkipZoneID: playback.lastAutoSkipEvent?.zoneID,
            lastAutoSkipSequence: playback.lastAutoSkipEvent?.sequence,
            isAutoSkipEnabled: appModel.playbackSettings.isAutoSkipPromosAndAdsEnabled
        )
    }

    private static func stateDescription(_ state: PlaybackState) -> String {
        switch state {
        case .idle:
            "idle"
        case .loading:
            "loading"
        case .buffering:
            "buffering"
        case .paused:
            "paused"
        case .playing:
            "playing"
        case .failed(let message):
            "failed (\(message))"
        }
    }

    private static func kindDescription(_ kind: PlaybackItemSourceIdentity.Kind) -> String {
        switch kind {
        case .localFile:
            "local file"
        case .networkStream:
            "network stream"
        }
    }
}
