import SwiftUI

struct NowPlayingSoundLabPanelHost: View {
    @Environment(OpenCastAppModel.self) private var appModel

    let revealProgress: CGFloat
    @Binding var voiceBoostEnabled: Bool
    let voiceBoostControlEnabled: Bool
    let onAdFreePassAction: () -> Void
    let onTranscribeRemotely: () -> Void
    let onShowTranscript: () -> Void
    let onAdFreePassBackgroundProbe: () -> Void

    var body: some View {
        NowPlayingSoundLabPanel(
            revealProgress: revealProgress,
            voiceBoostEnabled: $voiceBoostEnabled,
            voiceBoostControlEnabled: voiceBoostControlEnabled,
            adFreePassRow: NowPlayingSoundLabAdFreePassRowModel(
                presentation: appModel.currentAdFreePassPresentation
            ),
            remoteTranscriptionRow: remoteTranscriptionRow,
            onAdFreePassAction: onAdFreePassAction,
            onTranscribeRemotely: onTranscribeRemotely,
            onShowTranscript: onShowTranscript,
            onAdFreePassBackgroundProbe: onAdFreePassBackgroundProbe
        )
    }

    private var remoteTranscriptionRow: NowPlayingSoundLabRemoteTranscriptionRowModel? {
        guard appModel.remoteTranscriptionPurchases.isSurfaceVisible,
              let episodeID = appModel.playback.currentEpisode?.id.rawValue
        else {
            return nil
        }

        let remoteStore = appModel.remoteTranscription.store
        return NowPlayingSoundLabRemoteTranscriptionRowModel(
            hasCompletedTranscript: appModel.transcriptions.hasCompletedTranscript(
                for: episodeID
            ),
            hasActiveRequest: remoteStore.hasActiveRequest,
            isCurrentEpisodeRequest: remoteStore.activeEpisodeID == episodeID
        )
    }
}
