import Foundation
@preconcurrency import MediaPlayer

nonisolated struct RemoteCommandPositionHandler {
    func handle(
        positionTime: TimeInterval,
        state: RemoteCommandState,
        seek: (TimeInterval) -> Void
    ) -> MPRemoteCommandHandlerStatus {
        guard state.hasLoadedContent else {
            return .noSuchContent
        }

        guard positionTime.isFinite else {
            return .commandFailed
        }

        guard state.isSeekable, let duration = finitePositive(state.duration) else {
            return .noSuchContent
        }

        seek(clampPlaybackPosition(positionTime, to: duration))
        return .success
    }
}
