import OpenCastPlayback
import SwiftUI

struct VoiceBoostDiagnosticsStatusView: View {
    let diagnostics: VoiceBoostAudioTapDiagnostics
    let playbackState: PlaybackState
    let playbackPosition: TimeInterval
    let hasEpisode: Bool

    @State private var snapshot = VoiceBoostAudioTapDiagnosticsSnapshot()

    var body: some View {
        Text("Voice Boost Diagnostics")
            .frame(width: 1, height: 1)
            .opacity(0.01)
            .accessibilityIdentifier("Voice Boost Diagnostics")
            .accessibilityLabel("Voice Boost Diagnostics")
            .accessibilityValue(status)
            .voiceBoostDiagnosticsSnapshotTask(diagnostics: diagnostics, snapshot: $snapshot)
    }

    private var status: String {
        [
            "processedFrames=\(snapshot.processedFrameCount)",
            "bypassedFrames=\(snapshot.bypassedFrameCount)",
            "processCount=\(snapshot.processCount)",
            "prepareCount=\(snapshot.prepareCount)",
            "unprepareCount=\(snapshot.unprepareCount)",
            "sourceErrors=\(snapshot.sourceErrorCount)",
            "unsupportedFormats=\(snapshot.unsupportedFormatCount)",
            "tapInstallAttempts=\(snapshot.tapInstallAttemptCount)",
            "tapInstallSuccesses=\(snapshot.tapInstallSuccessCount)",
            "tapInstallFailures=\(snapshot.tapInstallFailureCount)",
            "tapCreationFailures=\(snapshot.tapCreationFailureCount)",
            "lastTapCreationStatus=\(snapshot.lastTapCreationStatus)",
            "lastSampleRate=\(snapshot.lastSampleRate)",
            "lastChannelCount=\(snapshot.lastChannelCount)",
            "timedProcessCount=\(snapshot.timedProcessCount)",
            "lastProcessDurationNanoseconds=\(snapshot.lastProcessDurationNanoseconds)",
            "maxProcessDurationNanoseconds=\(snapshot.maxProcessDurationNanoseconds)",
            "averageProcessDurationNanoseconds=\(snapshot.averageProcessDurationNanoseconds)",
            "playbackState=\(playbackState.accessibilityDescription)",
            "playbackPosition=\(playbackPosition)",
            "hasEpisode=\(hasEpisode ? 1 : 0)"
        ].joined(separator: ";")
    }
}
