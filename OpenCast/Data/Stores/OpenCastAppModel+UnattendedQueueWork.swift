import Foundation
import OpenCastPlayback
import SwiftData

extension OpenCastAppModel {
    /// Not `isSceneActive`, which is the last scene to report: a second window leaving can turn it
    /// false while the first is still in front.
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
