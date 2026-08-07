import Foundation
@preconcurrency import MediaPlayer

/// Seam over a command's enable flag so the availability matrix is testable
/// without `MPRemoteCommandCenter.shared()` (process-global system state).
protocol RemoteCommandToggling: AnyObject {
    var isEnabled: Bool { get set }
}

extension MPRemoteCommand: RemoteCommandToggling {}

/// The nine commands whose availability `updateAvailability` manages.
struct RemoteCommandAvailabilitySurface {
    let play: any RemoteCommandToggling
    let pause: any RemoteCommandToggling
    let togglePlayPause: any RemoteCommandToggling
    let skipForward: any RemoteCommandToggling
    let skipBackward: any RemoteCommandToggling
    let nextTrack: any RemoteCommandToggling
    let previousTrack: any RemoteCommandToggling
    let changePlaybackRate: any RemoteCommandToggling
    let changePlaybackPosition: any RemoteCommandToggling

    static func live(_ commandCenter: MPRemoteCommandCenter) -> Self {
        RemoteCommandAvailabilitySurface(
            play: commandCenter.playCommand,
            pause: commandCenter.pauseCommand,
            togglePlayPause: commandCenter.togglePlayPauseCommand,
            skipForward: commandCenter.skipForwardCommand,
            skipBackward: commandCenter.skipBackwardCommand,
            nextTrack: commandCenter.nextTrackCommand,
            previousTrack: commandCenter.previousTrackCommand,
            changePlaybackRate: commandCenter.changePlaybackRateCommand,
            changePlaybackPosition: commandCenter.changePlaybackPositionCommand
        )
    }
}

final class RemoteCommandController {
    private let commandCenter: MPRemoteCommandCenter
    private let availability: RemoteCommandAvailabilitySurface
    private let stateStore = RemoteCommandStateStore()
    private let positionHandler = RemoteCommandPositionHandler()
    private var targets: [RemoteCommandTarget] = []
    private var latestState: RemoteCommandState?
    private var latestIsPlaying: Bool?
    private var skipForwardInterval = PlaybackSkipInterval.forward
    private var skipBackwardInterval = PlaybackSkipInterval.backward

    init(
        commandCenter: MPRemoteCommandCenter = .shared(),
        availabilitySurface: RemoteCommandAvailabilitySurface? = nil
    ) {
        self.commandCenter = commandCenter
        self.availability = availabilitySurface ?? .live(commandCenter)
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
        commandCenter.changePlaybackRateCommand.supportedPlaybackRates =
            PlaybackRateSteps.steps.map { NSNumber(value: $0) }

        register(command: commandCenter.playCommand, handler: handlers.play)
        register(command: commandCenter.pauseCommand, handler: handlers.pause)
        register(command: commandCenter.togglePlayPauseCommand, handler: handlers.togglePlayPause)
        register(command: commandCenter.skipForwardCommand, handler: handlers.skipForward)
        register(command: commandCenter.skipBackwardCommand, handler: handlers.skipBackward)
        // Some steering-wheel controls emit track commands for their previous/next buttons.
        // Next can navigate the queue; previous remains a podcast skip alias.
        register(command: commandCenter.nextTrackCommand, handler: handlers.nextTrack)
        register(command: commandCenter.previousTrackCommand, handler: handlers.skipBackward)

        targets.append(RemoteCommandTarget(
            command: commandCenter.changePlaybackRateCommand,
            target: commandCenter.changePlaybackRateCommand.addTarget { [stateStore] event in
                guard let event = event as? MPChangePlaybackRateCommandEvent else {
                    return .commandFailed
                }
                guard stateStore.read().hasLoadedContent else {
                    return .noSuchContent
                }

                let rate = event.playbackRate
                Task { @MainActor in
                    handlers.changeRate(rate)
                }
                return .success
            }
        ))

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

        availability.play.isEnabled = hasLoadedContent && !isPlaybackRequested
        availability.pause.isEnabled = hasLoadedContent && isPlaybackRequested
        availability.togglePlayPause.isEnabled = hasLoadedContent
        availability.skipForward.isEnabled = hasLoadedContent
        availability.skipBackward.isEnabled = hasLoadedContent
        availability.nextTrack.isEnabled = hasLoadedContent
        availability.previousTrack.isEnabled = hasLoadedContent
        availability.changePlaybackRate.isEnabled = hasLoadedContent
        availability.changePlaybackPosition.isEnabled = isSeekable

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
