import SwiftData
import SwiftUI

struct OpenCastRootLifecycleModifier: ViewModifier {
    @Environment(OpenCastAppModel.self) private var appModel
    @Environment(\.modelContext) private var modelContext
    @Environment(\.scenePhase) private var scenePhase

    @Binding var hasFlushedProgressForLifecycleExit: Bool

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
            .onChange(of: appModel.playback.progressBoundaryID) { _, _ in
                appModel.flushPlaybackProgress(
                    modelContext: modelContext,
                    refreshObservableProgress: scenePhase == .active
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
            flushProgressForLifecycleExitIfNeeded()
        case .active:
            hasFlushedProgressForLifecycleExit = false
            appModel.library.refreshProgressRecords(modelContext: modelContext)
            appModel.refreshCurrentVoiceBoostSetting(modelContext: modelContext)
            Task {
                await appModel.refreshLibraryIfStale(modelContext: modelContext)
                appModel.cacheController.pruneIfNeeded()
                await appModel.syncStatus.refreshAccountStatus()
                await runVoiceBoostDeviceProbeIfActive()
            }
        @unknown default:
            break
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
