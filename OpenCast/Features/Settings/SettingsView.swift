import SwiftUI

struct SettingsView: View {
    @Environment(OpenCastAppModel.self) private var appModel
    @Environment(\.modelContext) private var modelContext

    let onPresentDataNukeConfirmation: () -> Void

    @State private var isConfirmingClearCaches = false
    @State private var isConfirmingDeleteAllDownloads = false
    @State private var isRunningVoiceBoostDeviceProbe = false
    @State private var voiceBoostDeviceProbeTask: Task<Void, Never>?

    var body: some View {
        Form {
            SettingsSyncSection(
                accountStatus: appModel.syncStatus.accountStatus
            )

            SettingsAppearanceSection()

            SettingsPlaybackSection()

            #if DEBUG
            if let voiceBoostDiagnostics = appModel.voiceBoostDiagnostics {
                VoiceBoostDiagnosticsSection(
                    diagnostics: voiceBoostDiagnostics,
                    playbackState: appModel.playback.state,
                    playbackPosition: appModel.playback.position,
                    isDeviceProbeRunning: isRunningVoiceBoostDeviceProbe,
                    lastDeviceProbeResult: appModel.lastVoiceBoostDeviceProbeResult,
                    lastDeviceProbeReportStatus: appModel.lastVoiceBoostDeviceProbeReportStatus,
                    lastDeviceProbeApplicationState: appModel.lastVoiceBoostDeviceProbeApplicationState,
                    onRunDeviceProbe: runVoiceBoostDeviceProbe
                )
            }
            #endif

            SettingsLocalStorageSection(
                feedCacheSummary: appModel.cacheController.feedCacheSummary.storageDescription,
                artworkCacheSummary: appModel.cacheController.artworkCacheSummary.storageDescription,
                cacheErrorMessage: appModel.cacheController.lastErrorMessage,
                downloadStorageSummary: downloadStorageSummary,
                completedDownloadCount: appModel.downloads.completedDownloadCount,
                downloadErrorMessage: appModel.downloads.lastErrorMessage,
                onClearCaches: confirmClearCaches,
                onDeleteAllDownloads: confirmDeleteAllDownloads
            )

            OPMLSettingsSection()

            SettingsDangerZoneSection(
                onNukeData: onPresentDataNukeConfirmation
            )

            SettingsDebugSection()

            SettingsAboutSection()
        }
        .navigationTitle("Settings")
        .contentMargins(.bottom, 72, for: .scrollContent)
        .task {
            await refreshSyncStatus()
            appModel.cacheController.refreshSummaries()
        }
        .onDisappear {
            cancelVoiceBoostDeviceProbe()
        }
        .confirmationDialog(
            "Clear automatic caches?",
            isPresented: $isConfirmingClearCaches,
            titleVisibility: .visible
        ) {
            Button("Clear Automatic Caches", role: .destructive, action: clearCaches)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Feed and artwork cache files will be removed from this device. Downloaded episodes are unchanged.")
        }
        .confirmationDialog(
            "Delete all downloaded episodes?",
            isPresented: $isConfirmingDeleteAllDownloads,
            titleVisibility: .visible
        ) {
            Button("Delete Downloads", role: .destructive, action: deleteAllDownloads)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Downloaded files will be removed from this device. Subscriptions and listening progress are unchanged.")
        }
    }

    private var downloadStorageSummary: String {
        let count = appModel.downloads.completedDownloadCount
        guard count > 0 else {
            return "None"
        }

        let episodeLabel = count == 1 ? "episode" : "episodes"
        return "\(count) \(episodeLabel), \(appModel.downloads.completedDownloadByteCount.formatted(.byteCount(style: .file)))"
    }

    private func refreshSyncStatus() async {
        await appModel.syncStatus.refreshAccountStatus()
    }

    private func confirmClearCaches() {
        isConfirmingClearCaches = true
    }

    private func clearCaches() {
        appModel.cacheController.clearCaches()
    }

    private func confirmDeleteAllDownloads() {
        isConfirmingDeleteAllDownloads = true
    }

    private func deleteAllDownloads() {
        appModel.downloads.deleteAllDownloads(modelContext: modelContext)
    }

    #if DEBUG
    private func runVoiceBoostDeviceProbe() {
        guard !isRunningVoiceBoostDeviceProbe, voiceBoostDeviceProbeTask == nil else {
            return
        }

        isRunningVoiceBoostDeviceProbe = true
        voiceBoostDeviceProbeTask = Task {
            await appModel.runVoiceBoostDeviceProbe(
                trigger: "settings",
                modelContext: modelContext
            )
            guard !Task.isCancelled else {
                return
            }
            isRunningVoiceBoostDeviceProbe = false
            voiceBoostDeviceProbeTask = nil
        }
    }
    #endif

    private func cancelVoiceBoostDeviceProbe() {
        voiceBoostDeviceProbeTask?.cancel()
        voiceBoostDeviceProbeTask = nil
        isRunningVoiceBoostDeviceProbe = false
    }
}
