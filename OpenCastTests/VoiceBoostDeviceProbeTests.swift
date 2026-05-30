#if DEBUG
import Foundation
import OpenCastPlayback
import SwiftData
import Testing
@testable import OpenCast

@MainActor
@Suite("Voice Boost device probe")
struct VoiceBoostDeviceProbeTests {
    @Test("Waiting report records inactive launch without starting playback")
    func waitingReportRecordsInactiveLaunchWithoutStartingPlayback() throws {
        removeReport()
        defer { removeReport() }

        let appModel = OpenCastAppModel(
            voiceBoostDiagnostics: VoiceBoostAudioTapDiagnostics(),
            runsVoiceBoostDeviceProbe: true
        )

        appModel.writeVoiceBoostDeviceProbeWaitingForActiveReportIfNeeded()

        let report = try decodedReport(at: VoiceBoostDeviceProbe.reportURL)
        #expect(report["schemaVersion"] as? Int == 2)
        #expect(appModel.lastVoiceBoostDeviceProbeResult == "launchWaitingForActive: waitingForActive")
        #expect(appModel.lastVoiceBoostDeviceProbeReportStatus == "Report Written")
        #expect(report["trigger"] as? String == "launchWaitingForActive")
        #expect(report["result"] as? String == "waitingForActive")
        let startedApplicationState = try #require(report["startedApplicationState"] as? String)
        let finishedApplicationState = try #require(report["finishedApplicationState"] as? String)
        #expect(appModel.lastVoiceBoostDeviceProbeApplicationState == "\(startedApplicationState) to \(finishedApplicationState)")
        #expect(report["processedFramesAdvanced"] as? Bool == false)
        #expect(report["timedProcessCallbacksAdvanced"] as? Bool == false)
        #expect(report["audioSessionPreflight"] == nil)
        #expect(report["audioSessionFinal"] == nil)

        let finalDiagnostics = try #require(report["finalDiagnostics"] as? [String: Any])
        #expect(finalDiagnostics["tapInstallAttemptCount"] as? Int == 0)
        #expect(finalDiagnostics["processCount"] as? Int == 0)
        #expect(finalDiagnostics["processedFrameCount"] as? Int == 0)

        let finalPlayback = try #require(report["finalPlayback"] as? [String: Any])
        #expect(finalPlayback["state"] as? String == "Idle")
        #expect(finalPlayback["hasEpisode"] as? Bool == false)
    }

    @Test("Waiting report does not consume launch probe retry")
    func waitingReportDoesNotConsumeLaunchProbeRetry() async throws {
        removeReport()
        defer { removeReport() }
        let container = try OpenCastModelContainerFactory.make(inMemory: true)
        let context = ModelContext(container)
        let appModel = OpenCastAppModel(runsVoiceBoostDeviceProbe: true)

        appModel.writeVoiceBoostDeviceProbeWaitingForActiveReportIfNeeded()
        let waitingReport = try decodedReport(at: VoiceBoostDeviceProbe.reportURL)
        #expect(waitingReport["schemaVersion"] as? Int == 2)
        #expect(waitingReport["trigger"] as? String == "launchWaitingForActive")

        await appModel.runVoiceBoostDeviceProbeIfNeeded(modelContext: context)

        let launchReport = try decodedReport(at: VoiceBoostDeviceProbe.reportURL)
        #expect(launchReport["schemaVersion"] as? Int == 2)
        #expect(appModel.lastVoiceBoostDeviceProbeResult == "launch: failed")
        #expect(appModel.lastVoiceBoostDeviceProbeReportStatus == "Report Written")
        #expect(appModel.lastVoiceBoostDeviceProbeApplicationState != nil)
        #expect(launchReport["trigger"] as? String == "launch")
        #expect(launchReport["result"] as? String == "failed")
        #expect(launchReport["errorMessage"] as? String == "Voice Boost diagnostics were not enabled for the device probe.")
    }

    private func removeReport() {
        try? FileManager.default.removeItem(at: VoiceBoostDeviceProbe.reportURL)
    }

    private func decodedReport(at url: URL) throws -> [String: Any] {
        let data = try Data(contentsOf: url)
        return try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }
}
#endif
