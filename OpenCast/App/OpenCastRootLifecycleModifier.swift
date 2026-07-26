import SwiftData
import SwiftUI

struct OpenCastRootLifecycleModifier: ViewModifier {
    @Environment(OpenCastAppModel.self) private var appModel
    @Environment(\.modelContext) private var modelContext
    @Environment(\.scenePhase) private var scenePhase

    @Binding var hasFlushedProgressForLifecycleExit: Bool
    @State private var hasPendingForegroundMaintenance = false
    @State private var deferredForegroundMaintenanceTask: Task<Void, Never>?
    @State private var deferredTranscriptionInterruptionTask: Task<Void, Never>?
    @State private var foregroundMaintenanceTask: Task<Void, Never>?
    @State private var foregroundSyncedDataRefreshTask: Task<Void, Never>?

    private static let postNowPlayingDismissMaintenanceDelay: TimeInterval = 0.75
    private static let inactiveTranscriptionInterruptionDelay: Duration = .seconds(2)
    private static let foregroundSyncedDataRefreshInterval: Duration = .seconds(60)

    let performInitialSetup: () async -> Void
    let refreshImportedData: () async -> Void
    let refreshSyncedUserData: () async -> Void
    let runVoiceBoostDeviceProbeIfActive: () async -> Void

    func body(content: Content) -> some View {
        content
            .task {
                appModel.configureBackgroundSessionExpirations(modelContext: modelContext)
                await performInitialSetup()
            }
            .onChange(of: scenePhase) { _, newPhase in
                handleScenePhaseChange(newPhase)
            }
            .onChange(of: appModel.isNowPlayingPresented) { _, isPresented in
                handleNowPlayingPresentationChange(isPresented: isPresented)
            }
            .onChange(of: appModel.playback.state) { _, newState in
                if case .failed(let message) = newState {
                    appModel.lastPlaybackError = message
                }
            }
            .onChange(of: appModel.library.refreshCompletedToken) { _, _ in
                appModel.adFreePass.probeCapDeferredQueueIfAllowed(trigger: .refreshCompleted)
            }
    }

    private func handleScenePhaseChange(_ newPhase: ScenePhase) {
        appModel.isSceneActive = newPhase == .active
        let transcriptionInterruptionDecision = AdFreePassLifecycleInterruptionPolicy(
            scenePhase: newPhase,
            isProtectingBackgroundExecution: appModel.adFreePassBackgroundSession.isProtectingBackgroundExecution
                || appModel.transcriptGenerationBackgroundSession.isProtectingBackgroundExecution
        ).decision

        switch newPhase {
        case .inactive:
            cancelForegroundMaintenanceTasks()
            if transcriptionInterruptionDecision == .scheduleDelayedInterrupt {
                scheduleTranscriptionInterruptionIfInactivePersists()
            }
            flushProgressForLifecycleExitIfNeeded()
        case .background:
            cancelForegroundMaintenanceTasks()
            deferredTranscriptionInterruptionTask?.cancel()
            deferredTranscriptionInterruptionTask = nil
            if transcriptionInterruptionDecision == .interruptNow {
                interruptActiveTranscriptionForLifecycleExit()
            }
            flushProgressForLifecycleExitIfNeeded()
        case .active:
            deferredTranscriptionInterruptionTask?.cancel()
            deferredTranscriptionInterruptionTask = nil
            hasFlushedProgressForLifecycleExit = false
            appModel.resumeEnvironmentalAdFreePassIfNeeded(modelContext: modelContext)
            startForegroundSyncedDataRefresh()
            runOrDeferForegroundMaintenance()
        @unknown default:
            break
        }
    }

    private func scheduleTranscriptionInterruptionIfInactivePersists() {
        deferredTranscriptionInterruptionTask?.cancel()
        deferredTranscriptionInterruptionTask = Task {
            try? await Task.sleep(for: Self.inactiveTranscriptionInterruptionDelay)

            guard !Task.isCancelled else {
                return
            }

            interruptActiveTranscriptionForLifecycleExit()
        }
    }

    private func interruptActiveTranscriptionForLifecycleExit() {
        appModel.interruptActiveTranscriptionForLifecycleExit(modelContext: modelContext)
    }

    private func handleNowPlayingPresentationChange(isPresented: Bool) {
        guard !isPresented,
              hasPendingForegroundMaintenance,
              scenePhase == .active
        else {
            return
        }

        scheduleForegroundMaintenanceAfterNowPlayingDismiss()
    }

    private func runOrDeferForegroundMaintenance() {
        guard !appModel.isNowPlayingPresented else {
            nowPlayingProbeMark("foreground-maintenance-deferred")
            hasPendingForegroundMaintenance = true
            return
        }

        runForegroundMaintenance()
    }

    private func runForegroundMaintenance() {
        deferredForegroundMaintenanceTask?.cancel()
        deferredForegroundMaintenanceTask = nil
        performForegroundMaintenance()
    }

    private func scheduleForegroundMaintenanceAfterNowPlayingDismiss() {
        nowPlayingProbeMark("foreground-maintenance-after-dismiss-scheduled")
        deferredForegroundMaintenanceTask?.cancel()
        deferredForegroundMaintenanceTask = Task {
            try? await Task.sleep(for: .seconds(Self.postNowPlayingDismissMaintenanceDelay))

            guard !Task.isCancelled else {
                return
            }

            guard scenePhase == .active, !appModel.isNowPlayingPresented else {
                hasPendingForegroundMaintenance = true
                return
            }

            performForegroundMaintenance()
            deferredForegroundMaintenanceTask = nil
        }
    }

    private func performForegroundMaintenance() {
        nowPlayingProbeMark("foreground-maintenance-start")
        hasPendingForegroundMaintenance = false
        foregroundMaintenanceTask?.cancel()
        appModel.library.refreshProgressRecords(modelContext: modelContext)
        appModel.refreshCurrentVoiceBoostSetting(modelContext: modelContext)
        appModel.sweepPlayedDownloadsIfEnabled(modelContext: modelContext)
        foregroundMaintenanceTask = Task {
            await refreshImportedData()
            guard !Task.isCancelled else {
                return
            }
            await appModel.refreshLibraryIfStale(modelContext: modelContext)
            guard !Task.isCancelled else {
                return
            }
            appModel.cacheController.pruneIfNeeded()
            guard !Task.isCancelled else {
                return
            }
            await appModel.syncStatus.refreshAccountStatus()
            guard !Task.isCancelled else {
                return
            }
            await appModel.notificationSettings.refreshIfNeeded(
                activePodcastIDs: appModel.library.activePodcastIDs,
                modelContext: modelContext
            )
            guard !Task.isCancelled else {
                return
            }
            await runVoiceBoostDeviceProbeIfActive()
            guard !Task.isCancelled else {
                return
            }
            nowPlayingProbeMark("foreground-maintenance-finished")
            foregroundMaintenanceTask = nil
        }
    }

    private func startForegroundSyncedDataRefresh() {
        foregroundSyncedDataRefreshTask?.cancel()
        foregroundSyncedDataRefreshTask = Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.foregroundSyncedDataRefreshInterval)

                guard !Task.isCancelled else {
                    return
                }

                await refreshSyncedUserData()
            }
        }
    }

    private func cancelForegroundMaintenanceTasks() {
        deferredForegroundMaintenanceTask?.cancel()
        deferredForegroundMaintenanceTask = nil
        foregroundMaintenanceTask?.cancel()
        foregroundMaintenanceTask = nil
        foregroundSyncedDataRefreshTask?.cancel()
        foregroundSyncedDataRefreshTask = nil
        hasPendingForegroundMaintenance = false
    }

    private func flushProgressForLifecycleExitIfNeeded() {
        guard !hasFlushedProgressForLifecycleExit else {
            return
        }

        hasFlushedProgressForLifecycleExit = true
        appModel.flushPlaybackProgress(
            modelContext: modelContext,
            refreshObservableProgress: false
        )
    }
}
