import SwiftUI

struct NowPlayingSoundLabPanelHost: View {
    @Environment(OpenCastAppModel.self) private var appModel

    let revealProgress: CGFloat
    @Binding var voiceBoostEnabled: Bool
    let voiceBoostControlEnabled: Bool
    let onAdFreePassAction: () -> Void
    let onTranscribeRemotely: () -> Void
    let onTranscriptAction: () -> Void
    let onAdFreePassBackgroundProbe: () -> Void

    var body: some View {
        NowPlayingSoundLabPanel(
            revealProgress: revealProgress,
            voiceBoostEnabled: $voiceBoostEnabled,
            voiceBoostControlEnabled: voiceBoostControlEnabled,
            adFreePassRow: NowPlayingSoundLabAdFreePassRowModel(
                presentation: appModel.currentAdFreePassPresentation
            ),
            transcriptionRow: transcriptionRow,
            onAdFreePassAction: onAdFreePassAction,
            onTranscribeRemotely: onTranscribeRemotely,
            onTranscriptAction: onTranscriptAction,
            onAdFreePassBackgroundProbe: onAdFreePassBackgroundProbe
        )
    }

    private var transcriptionRow: NowPlayingSoundLabTranscriptionRowModel? {
        guard let episodeID = appModel.playback.currentEpisode?.id.rawValue else {
            return nil
        }

        let remoteStore = appModel.remoteTranscription.store
        let localRequest = appModel.transcriptionRequests.request
        let localRequestEpisodeID: String? = if let localRequest, !localRequest.phase.isTerminal {
            localRequest.episodeID
        } else {
            nil
        }
        let remoteEpisodeID = remoteStore.hasActiveRequest ? remoteStore.activeEpisodeID : nil
        let isRemoteAvailabilityUnknown = appModel.remoteTranscriptionPurchases.availability == .unknown
        return NowPlayingSoundLabTranscriptionRowModel(
            hasCompletedTranscript: appModel.transcriptions.hasCompletedTranscript(for: episodeID),
            mode: NowPlayingSoundLabTranscriptionStateResolver.mode(
                preference: appModel.adDetectionSettings.mode,
                isRemoteSurfaceVisible: appModel.remoteTranscriptionPurchases.isSurfaceVisible,
                isRemoteAvailabilityUnknown: isRemoteAvailabilityUnknown
            ),
            remoteActivity: NowPlayingSoundLabTranscriptionStateResolver.activity(
                currentEpisodeID: episodeID,
                requestEpisodeID: remoteEpisodeID,
                storeEpisodeID: nil
            ),
            localActivity: NowPlayingSoundLabTranscriptionStateResolver.activity(
                currentEpisodeID: episodeID,
                requestEpisodeID: localRequestEpisodeID,
                storeEpisodeID: appModel.transcriptions.activeEpisodeID
            )
        )
    }
}
