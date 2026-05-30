#if DEBUG
import Foundation
import OpenCastPlayback

struct VoiceBoostDeviceProbeDiagnosticsReport: Encodable {
    let processedFrameCount: Int
    let bypassedFrameCount: Int
    let processCount: Int
    let prepareCount: Int
    let unprepareCount: Int
    let sourceErrorCount: Int
    let unsupportedFormatCount: Int
    let tapInstallAttemptCount: Int
    let tapInstallSuccessCount: Int
    let tapInstallFailureCount: Int
    let lastTapInstallErrorDescription: String?
    let tapCreationFailureCount: Int
    let lastTapCreationStatus: Int
    let lastSampleRate: Double
    let lastChannelCount: Int
    let timedProcessCount: Int
    let lastProcessDurationNanoseconds: UInt64
    let maxProcessDurationNanoseconds: UInt64
    let totalProcessDurationNanoseconds: UInt64
    let averageProcessDurationNanoseconds: UInt64

    init(snapshot: VoiceBoostAudioTapDiagnosticsSnapshot) {
        processedFrameCount = snapshot.processedFrameCount
        bypassedFrameCount = snapshot.bypassedFrameCount
        processCount = snapshot.processCount
        prepareCount = snapshot.prepareCount
        unprepareCount = snapshot.unprepareCount
        sourceErrorCount = snapshot.sourceErrorCount
        unsupportedFormatCount = snapshot.unsupportedFormatCount
        tapInstallAttemptCount = snapshot.tapInstallAttemptCount
        tapInstallSuccessCount = snapshot.tapInstallSuccessCount
        tapInstallFailureCount = snapshot.tapInstallFailureCount
        lastTapInstallErrorDescription = snapshot.lastTapInstallErrorDescription
        tapCreationFailureCount = snapshot.tapCreationFailureCount
        lastTapCreationStatus = snapshot.lastTapCreationStatus
        lastSampleRate = snapshot.lastSampleRate
        lastChannelCount = snapshot.lastChannelCount
        timedProcessCount = snapshot.timedProcessCount
        lastProcessDurationNanoseconds = snapshot.lastProcessDurationNanoseconds
        maxProcessDurationNanoseconds = snapshot.maxProcessDurationNanoseconds
        totalProcessDurationNanoseconds = snapshot.totalProcessDurationNanoseconds
        averageProcessDurationNanoseconds = snapshot.averageProcessDurationNanoseconds
    }
}
#endif
