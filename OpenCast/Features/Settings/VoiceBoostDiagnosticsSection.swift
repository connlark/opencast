import OpenCastPlayback
import SwiftUI

struct VoiceBoostDiagnosticsSection: View {
    let diagnostics: VoiceBoostAudioTapDiagnostics
    let playbackState: PlaybackState
    let playbackPosition: TimeInterval
    let isDeviceProbeRunning: Bool
    let lastDeviceProbeResult: String?
    let lastDeviceProbeReportStatus: String?
    let lastDeviceProbeApplicationState: String?
    let onRunDeviceProbe: () -> Void

    @State private var snapshot = VoiceBoostAudioTapDiagnosticsSnapshot()

    var body: some View {
        Section("Voice Boost Diagnostics") {
            Button(
                "Run Device Probe",
                systemImage: "waveform.path.ecg",
                action: onRunDeviceProbe
            )
            .disabled(isDeviceProbeRunning)

            if isDeviceProbeRunning {
                ProgressView("Running Device Probe")
            }

            LabeledContent("Last Device Probe", value: lastDeviceProbeResult ?? "Not Run")
                .accessibilityIdentifier("Last Device Probe Value")
                .accessibilityValue(lastDeviceProbeResult ?? "Not Run")
            LabeledContent("Device Probe Report", value: lastDeviceProbeReportStatus ?? "Not Written")
                .accessibilityIdentifier("Device Probe Report Value")
                .accessibilityValue(lastDeviceProbeReportStatus ?? "Not Written")
            LabeledContent("Device Probe App State", value: lastDeviceProbeApplicationState ?? "Not Run")
                .accessibilityIdentifier("Device Probe App State Value")
                .accessibilityValue(lastDeviceProbeApplicationState ?? "Not Run")
            LabeledContent("Processed Frames", value: "\(snapshot.processedFrameCount)")
            LabeledContent("Bypassed Frames", value: "\(snapshot.bypassedFrameCount)")
            LabeledContent("Process Callbacks", value: "\(snapshot.processCount)")
            LabeledContent("Timed Callbacks", value: "\(snapshot.timedProcessCount)")
            LabeledContent("Max Callback ns", value: "\(snapshot.maxProcessDurationNanoseconds)")
            LabeledContent("Average Callback ns", value: "\(snapshot.averageProcessDurationNanoseconds)")
            LabeledContent("Source Errors", value: "\(snapshot.sourceErrorCount)")
            LabeledContent("Unsupported Formats", value: "\(snapshot.unsupportedFormatCount)")
            LabeledContent("Tap Installs", value: "\(snapshot.tapInstallSuccessCount)/\(snapshot.tapInstallAttemptCount)")
            LabeledContent("Tap Install Failures", value: "\(snapshot.tapInstallFailureCount)")
            LabeledContent("Tap Creation Failures", value: "\(snapshot.tapCreationFailureCount)")
            LabeledContent("Sample Rate", value: "\(snapshot.lastSampleRate)")
            LabeledContent("Channels", value: "\(snapshot.lastChannelCount)")
            LabeledContent("Playback State", value: playbackState.accessibilityDescription)
            LabeledContent("Playback Position", value: "\(playbackPosition)")
        }
        .voiceBoostDiagnosticsSnapshotTask(diagnostics: diagnostics, snapshot: $snapshot)
    }
}
