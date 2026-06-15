import SwiftData
import SwiftUI

struct OpenCastRootLifecycleModifier: ViewModifier {
    @Environment(OpenCastAppModel.self) private var appModel
    @Environment(\.modelContext) private var modelContext
    @Environment(\.scenePhase) private var scenePhase

    @Binding var hasFlushedProgressForLifecycleExit: Bool
    @State private var hasPendingForegroundMaintenance = false
    @State private var deferredForegroundMaintenanceTask: Task<Void, Never>?
    @State private var foregroundMaintenanceTask: Task<Void, Never>?

    private static let postNowPlayingDismissMaintenanceDelay: TimeInterval = 0.75

    let performInitialSetup: () async -> Void
    let persistPlaybackProgress: () async -> Void
    let runVoiceBoostDeviceProbeIfActive: () async -> Void

    func body(content: Content) -> some View {
        content
            .task {
                await performInitialSetup()
            }
            .task(id: appModel.playback.currentEpisode?.id.rawValue) {
                await persistPlaybackProgress()
            }
            .onChange(of: scenePhase) { _, newPhase in
                handleScenePhaseChange(newPhase)
            }
            .onChange(of: appModel.isNowPlayingPresented) { _, isPresented in
                handleNowPlayingPresentationChange(isPresented: isPresented)
            }
            .onChange(of: appModel.playback.progressBoundaryID) { _, _ in
                appModel.flushPlaybackProgress(
                    modelContext: modelContext,
                    refreshObservableProgress: scenePhase == .active && !appModel.isNowPlayingPresented
                )
            }
            .onChange(of: appModel.playback.state) { _, newState in
                if case .failed(let message) = newState {
                    appModel.lastPlaybackError = message
                }
            }
    }

    private func handleScenePhaseChange(_ newPhase: ScenePhase) {
        switch newPhase {
        case .inactive, .background:
            deferredForegroundMaintenanceTask?.cancel()
            deferredForegroundMaintenanceTask = nil
            foregroundMaintenanceTask?.cancel()
            foregroundMaintenanceTask = nil
            hasPendingForegroundMaintenance = false
            flushProgressForLifecycleExitIfNeeded()
        case .active:
            hasFlushedProgressForLifecycleExit = false
            runOrDeferForegroundMaintenance()
        @unknown default:
            break
        }
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
            do {
                try await Task.sleep(for: .seconds(Self.postNowPlayingDismissMaintenanceDelay))
            } catch is CancellationError {
                return
            } catch {
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
        foregroundMaintenanceTask = Task {
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
            await runVoiceBoostDeviceProbeIfActive()
            guard !Task.isCancelled else {
                return
            }
            nowPlayingProbeMark("foreground-maintenance-finished")
            foregroundMaintenanceTask = nil
        }
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
