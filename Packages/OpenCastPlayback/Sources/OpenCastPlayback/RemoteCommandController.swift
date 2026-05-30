import Foundation
@preconcurrency import MediaPlayer

final class RemoteCommandController {
    private let commandCenter: MPRemoteCommandCenter
    private let stateStore = RemoteCommandStateStore()
    private let positionHandler = RemoteCommandPositionHandler()
    private var targets: [RemoteCommandTarget] = []
    private var latestState: RemoteCommandState?
    private var latestIsPlaying: Bool?
    private var skipForwardInterval = PlaybackSkipInterval.forward
    private var skipBackwardInterval = PlaybackSkipInterval.backward

    init(commandCenter: MPRemoteCommandCenter = .shared()) {
        self.commandCenter = commandCenter
    }

    isolated deinit {
        removeTargets()
        updateAvailability(for: PlaybackSnapshot(), resolvedDuration: nil)
    }

    func install(_ handlers: RemoteCommandHandlers) {
        guard targets.isEmpty else {
            assertionFailure("RemoteCommandController.install called twice")
            return
        }

        applySkipIntervals()

        register(command: commandCenter.playCommand, handler: handlers.play)
        register(command: commandCenter.pauseCommand, handler: handlers.pause)
        register(command: commandCenter.togglePlayPauseCommand, handler: handlers.togglePlayPause)
        register(command: commandCenter.skipForwardCommand, handler: handlers.skipForward)
        register(command: commandCenter.skipBackwardCommand, handler: handlers.skipBackward)

        targets.append(RemoteCommandTarget(
            command: commandCenter.changePlaybackPositionCommand,
            target: commandCenter.changePlaybackPositionCommand.addTarget { [positionHandler, stateStore] event in
                guard let event = event as? MPChangePlaybackPositionCommandEvent else {
                    return .commandFailed
                }

                return positionHandler.handle(
                    positionTime: event.positionTime,
                    state: stateStore.read()
                ) { clampedPosition in
                    Task { @MainActor in
                        handlers.seek(clampedPosition)
                    }
                }
            }
        ))

        updateAvailability(for: PlaybackSnapshot(), resolvedDuration: nil)
    }

    func setSkipIntervals(backward: TimeInterval, forward: TimeInterval) {
        guard backward.isFinite, backward > 0, forward.isFinite, forward > 0 else {
            return
        }

        skipBackwardInterval = backward
        skipForwardInterval = forward
        applySkipIntervals()
    }

    func updateAvailability(for snapshot: PlaybackSnapshot, resolvedDuration: TimeInterval?) {
        let hasLoadedContent = snapshot.currentEpisode != nil
        let seekableDuration = snapshot.bestFiniteDuration(preferring: resolvedDuration)
        let isSeekable = hasLoadedContent && seekableDuration != nil
        let isPlaybackRequested = snapshot.state == .playing || snapshot.state == .buffering
        let state = RemoteCommandState(
            hasLoadedContent: hasLoadedContent,
            isSeekable: isSeekable,
            duration: seekableDuration
        )

        guard latestState != state || latestIsPlaying != isPlaybackRequested else {
            return
        }

        commandCenter.playCommand.isEnabled = hasLoadedContent && !isPlaybackRequested
        commandCenter.pauseCommand.isEnabled = hasLoadedContent && isPlaybackRequested
        commandCenter.togglePlayPauseCommand.isEnabled = hasLoadedContent
        commandCenter.skipForwardCommand.isEnabled = hasLoadedContent
        commandCenter.skipBackwardCommand.isEnabled = hasLoadedContent
        commandCenter.changePlaybackPositionCommand.isEnabled = isSeekable

        stateStore.update(state)
        latestState = state
        latestIsPlaying = isPlaybackRequested
    }

    private func register(
        command: MPRemoteCommand,
        handler: @escaping @MainActor () -> Void
    ) {
        targets.append(RemoteCommandTarget(
            command: command,
            target: command.addTarget { [stateStore] _ in
                guard stateStore.read().hasLoadedContent else {
                    return .noSuchContent
                }

                Task { @MainActor in
                    handler()
                }
                return .success
            }
        ))
    }

    private func removeTargets() {
        for target in targets {
            target.command.removeTarget(target.target)
        }
        targets = []
    }

    private func applySkipIntervals() {
        commandCenter.skipForwardCommand.preferredIntervals = [NSNumber(value: skipForwardInterval)]
        commandCenter.skipBackwardCommand.preferredIntervals = [NSNumber(value: skipBackwardInterval)]
    }
}
