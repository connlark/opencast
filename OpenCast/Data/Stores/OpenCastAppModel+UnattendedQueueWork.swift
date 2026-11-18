import Foundation
import OpenCastPlayback
import SwiftData

extension OpenCastAppModel {
    /// Whether any root scene is active. `isSceneActive` is the last scene
    /// to report, which a second window leaving can turn false while the
    /// first is still in front.
    var isAnySceneActive: Bool {
        autoDownloads.isForeground
    }

    var unattendedQueueWorkPolicy: AdFreePassUnattendedWorkPolicy {
        AdFreePassUnattendedWorkPolicy(
            isAnySceneActive: isAnySceneActive,
            isCardArmed: adFreePassBackgroundSession.isArmed,
            playbackState: unattendedQueueWorkPlaybackStateOverride ?? playback.state,
            isLowPowerModeEnabled: isLowPowerModeEnabled()
        )
    }

    /// Follows playback for the queue's unattended work, once for the app
    /// however many scenes ask.
    func startUnattendedQueueWorkObservation(modelContext: ModelContext) {
        guard unattendedQueueWorkObservationTask == nil else {
            return
        }

        unattendedQueueWorkObservationTask = Task { [weak self] in
            for await _ in Observations({ self?.playback.state }) {
                guard let self, !Task.isCancelled else {
                    return
                }
                await reactToPlaybackChangeForUnattendedQueueWork(modelContext: modelContext)
            }
        }
    }

    /// `sleep` waits out the inactive grace; tests pass their own.
    func reactToPlaybackChangeForUnattendedQueueWork(
        modelContext: ModelContext,
        sleep: (Duration) async -> Void = { try? await Task.sleep(for: $0) }
    ) async {
        switch unattendedQueueWorkPolicy.playbackChangeAction {
        case .none:
            return
        case .resumeLifecycleHold:
            adFreePass.resumeLifecycleHoldIfAllowed()
        case .holdIfStillIneligible:
            await sleep(AdFreePassLifecycleInterruptionPolicy.inactiveInterruptionDelay)
            guard !Task.isCancelled,
                  unattendedQueueWorkPolicy.playbackChangeAction == .holdIfStillIneligible
            else {
                return
            }
            adFreePass.holdActiveItemForLifecycle(modelContext: modelContext)
        }
    }
}
