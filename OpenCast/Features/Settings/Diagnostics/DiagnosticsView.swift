import SwiftData
import SwiftUI

struct DiagnosticsView: View {
    @Environment(OpenCastAppModel.self) private var appModel
    @Environment(\.modelContext) private var modelContext

    @State private var refreshLogs: [RefreshLogSnapshot]?
    @State private var verifiedDownloadSummary = "—"
    @State private var isRunningVoiceBoostDeviceProbe = false
    @State private var voiceBoostDeviceProbeTask: Task<Void, Never>?

    var body: some View {
        Form {
            PerformanceDiagnosticsSection()
            DiagnosticsRepairSection(verifiedDownloadSummary: verifiedDownloadSummary)

            DiagnosticsRefreshLogsSection(refreshLogs: refreshLogs)

            #if DEBUG
            DiagnosticsDeveloperSection()

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

            #if DEBUG || INTERNAL_NOTIFICATIONS_DIAGNOSTICS
            NotificationSecurityDiagnosticsSection()
            NotificationRegistrationDiagnosticsSection()
            NotificationSubscriptionDiagnosticsSection()
            NotificationRouteDiagnosticsSection()
            #endif
        }
        .settingsSubscreen(title: "Diagnostics")
        .task {
            await loadDiagnostics()
        }
        .onDisappear {
            cancelVoiceBoostDeviceProbe()
        }
    }

    private func loadDiagnostics() async {
        refreshLogs = await appModel.library.loadAllRefreshLogs()
        verifiedDownloadSummary = await computeVerifiedDownloadSummary()
    }

    // One synchronous file stat per completed download is body-hostile; the
    // count is computed off the main actor in the load path and cached.
    private func computeVerifiedDownloadSummary() async -> String {
        let candidates: [(fileURL: URL?, expectedByteCount: Int64)] = appModel.downloads.records
            .filter { $0.state == .completed }
            .map { record in
                (
                    record.sourceFileSHA256.isEmpty ? nil : appModel.downloads.localFileURL(for: record),
                    record.bytesReceived
                )
            }
        guard !candidates.isEmpty else {
            return "None"
        }
        let verifiedCount = await Self.verifiedDownloadCount(of: candidates)
        return "\(verifiedCount) of \(candidates.count)"
    }

    @concurrent
    private static func verifiedDownloadCount(
        of candidates: [(fileURL: URL?, expectedByteCount: Int64)]
    ) async -> Int {
        candidates.count { candidate in
            guard let fileURL = candidate.fileURL,
                  let byteCount = (try? FileManager.default.attributesOfItem(atPath: fileURL.path))?[.size] as? NSNumber
            else {
                return false
            }
            return byteCount.int64Value == candidate.expectedByteCount
        }
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
