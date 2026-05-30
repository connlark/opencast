@preconcurrency import AVFoundation
import AudioToolbox
import Dispatch
import Foundation
@preconcurrency import MediaToolbox
import OSLog
import OpenCastVoiceBoost

nonisolated final class VoiceBoostAudioTap {
    private let context: VoiceBoostAudioTapContext
    let audioTapProcessor: MTAudioProcessingTap

    init(
        configuration: VoiceBoostConfiguration,
        diagnostics: VoiceBoostAudioTapDiagnostics? = nil
    ) throws {
        context = VoiceBoostAudioTapContext(configuration: configuration, diagnostics: diagnostics)
        var callbacks = MTAudioProcessingTapCallbacks(
            version: kMTAudioProcessingTapCallbacksVersion_0,
            clientInfo: Unmanaged.passUnretained(context).toOpaque(),
            init: VoiceBoostAudioTapCallbacks.initCallback,
            finalize: VoiceBoostAudioTapCallbacks.finalizeCallback,
            prepare: VoiceBoostAudioTapCallbacks.prepareCallback,
            unprepare: VoiceBoostAudioTapCallbacks.unprepareCallback,
            process: VoiceBoostAudioTapCallbacks.processCallback
        )
        var createdTap: MTAudioProcessingTap?
        let status = MTAudioProcessingTapCreate(
            kCFAllocatorDefault,
            &callbacks,
            kMTAudioProcessingTapCreationFlag_PostEffects,
            &createdTap
        )
        guard status == noErr, let createdTap else {
            throw VoiceBoostAudioTapError.creationFailed(status)
        }
        audioTapProcessor = createdTap
    }

    func update(configuration: VoiceBoostConfiguration) {
        context.update(configuration: configuration)
    }

    func reset() {
        context.reset()
    }
}

enum VoiceBoostAudioTapError: Error {
    case creationFailed(OSStatus)
}

public nonisolated struct VoiceBoostAudioTapDiagnosticsSnapshot: Equatable, Sendable {
    public var prepareCount = 0
    public var unprepareCount = 0
    public var processCount = 0
    public var processedFrameCount = 0
    public var bypassedFrameCount = 0
    public var sourceErrorCount = 0
    public var unsupportedFormatCount = 0
    public var tapInstallAttemptCount = 0
    public var tapInstallSuccessCount = 0
    public var tapInstallFailureCount = 0
    public var lastTapInstallErrorDescription: String?
    public var tapCreationFailureCount = 0
    public var lastTapCreationStatus = 0
    public var lastSampleRate = 0.0
    public var lastChannelCount = 0
    public var timedProcessCount = 0
    public var lastProcessDurationNanoseconds: UInt64 = 0
    public var maxProcessDurationNanoseconds: UInt64 = 0
    public var totalProcessDurationNanoseconds: UInt64 = 0

    public init() {}

    public var averageProcessDurationNanoseconds: UInt64 {
        guard timedProcessCount > 0 else {
            return 0
        }

        return totalProcessDurationNanoseconds / UInt64(timedProcessCount)
    }
}

public nonisolated final class VoiceBoostAudioTapDiagnostics {
    private let lock = VoiceBoostAudioTapStateLock()
    private var state = VoiceBoostAudioTapDiagnosticsSnapshot()

    public init() {}

    public var snapshot: VoiceBoostAudioTapDiagnosticsSnapshot {
        lock.withLock { state }
    }

    func recordTapInstallAttempt() {
        lock.withLock {
            state.tapInstallAttemptCount += 1
        }
    }

    func recordTapInstallSuccess() {
        lock.withLock {
            state.tapInstallSuccessCount += 1
        }
    }

    func recordTapInstallFailure(_ error: Error) {
        let description = error.localizedDescription
        lock.withLock {
            state.tapInstallFailureCount += 1
            state.lastTapInstallErrorDescription = description
        }
    }

    func recordTapCreationFailure(status: OSStatus?) {
        lock.withLock {
            state.tapCreationFailureCount += 1
            state.lastTapCreationStatus = Int(status ?? 0)
        }
    }

    func recordPrepare(sampleRate: Double, channelCount: Int, isSupported: Bool) {
        lock.withLock {
            state.prepareCount += 1
            state.lastSampleRate = sampleRate
            state.lastChannelCount = channelCount
            if !isSupported {
                state.unsupportedFormatCount += 1
            }
        }
    }

    func recordUnprepare() {
        lock.withLock {
            state.unprepareCount += 1
        }
    }

    func recordSourceError() {
        lock.withLock {
            state.sourceErrorCount += 1
        }
    }

    func recordProcess(frameCount: Int, wasProcessed: Bool, durationNanoseconds: UInt64?) {
        lock.withLock {
            state.processCount += 1
            if wasProcessed {
                state.processedFrameCount += frameCount
            } else {
                state.bypassedFrameCount += frameCount
            }
            if let durationNanoseconds {
                state.timedProcessCount += 1
                state.lastProcessDurationNanoseconds = durationNanoseconds
                state.maxProcessDurationNanoseconds = max(
                    state.maxProcessDurationNanoseconds,
                    durationNanoseconds
                )
                state.totalProcessDurationNanoseconds += durationNanoseconds
            }
        }
    }
}

nonisolated private enum VoiceBoostAudioTapCallbacks {
    static let initCallback: MTAudioProcessingTapInitCallback = { _, clientInfo, tapStorageOut in
        guard let clientInfo else {
            tapStorageOut.pointee = nil
            return
        }
        let context = Unmanaged<VoiceBoostAudioTapContext>
            .fromOpaque(clientInfo)
            .takeUnretainedValue()
        tapStorageOut.pointee = Unmanaged.passRetained(context).toOpaque()
    }

    static let finalizeCallback: MTAudioProcessingTapFinalizeCallback = { tap in
        let storage = MTAudioProcessingTapGetStorage(tap)
        Unmanaged<VoiceBoostAudioTapContext>
            .fromOpaque(storage)
            .release()
    }

    static let prepareCallback: MTAudioProcessingTapPrepareCallback = { tap, maximumFrames, processingFormat in
        guard let context = context(for: tap) else {
            return
        }
        context.prepare(maximumFrames: Int(maximumFrames), processingFormat: processingFormat.pointee)
    }

    static let unprepareCallback: MTAudioProcessingTapUnprepareCallback = { tap in
        context(for: tap)?.unprepare()
    }

    static let processCallback: MTAudioProcessingTapProcessCallback = {
        tap,
        numberFrames,
        _,
        bufferListInOut,
        numberFramesOut,
        flagsOut
    in
        let context = context(for: tap)
        let signpostState: OSSignpostIntervalState? = if context?.isDiagnosticsEnabled == true {
            VoiceBoostAudioTapSignposts.signposter.beginInterval("Process")
        } else {
            nil
        }
        defer {
            if let signpostState {
                VoiceBoostAudioTapSignposts.signposter.endInterval("Process", signpostState)
            }
        }

        let startedAt = context?.startTiming()
        let status = MTAudioProcessingTapGetSourceAudio(
            tap,
            numberFrames,
            bufferListInOut,
            flagsOut,
            nil,
            numberFramesOut
        )
        guard status == noErr, let context else {
            context?.recordSourceError()
            numberFramesOut.pointee = 0
            return
        }
        let wasProcessed = context.process(
            bufferList: bufferListInOut,
            frameCount: Int(numberFramesOut.pointee)
        )
        context.recordProcess(
            frameCount: Int(numberFramesOut.pointee),
            wasProcessed: wasProcessed,
            startedAt: startedAt
        )
    }

    private static func context(for tap: MTAudioProcessingTap) -> VoiceBoostAudioTapContext? {
        let storage = MTAudioProcessingTapGetStorage(tap)
        return Unmanaged<VoiceBoostAudioTapContext>
            .fromOpaque(storage)
            .takeUnretainedValue()
    }
}

nonisolated private enum VoiceBoostAudioTapSignposts {
    static let signposter = OSSignposter(
        subsystem: "com.connor.opencast",
        category: "VoiceBoostAudioTap"
    )
}

nonisolated private final class VoiceBoostAudioTapContext {
    private let diagnostics: VoiceBoostAudioTapDiagnostics?
    private let stateLock = VoiceBoostAudioTapStateLock()
    private var state: VoiceBoostAudioTapRuntimeState

    init(configuration: VoiceBoostConfiguration, diagnostics: VoiceBoostAudioTapDiagnostics?) {
        self.diagnostics = diagnostics
        state = VoiceBoostAudioTapRuntimeState(configuration: configuration)
    }

    var isDiagnosticsEnabled: Bool {
        diagnostics != nil
    }

    func prepare(maximumFrames: Int, processingFormat: AudioStreamBasicDescription) {
        let channelCount = Int(processingFormat.mChannelsPerFrame)
        let isFloat32 = processingFormat.mFormatID == kAudioFormatLinearPCM
            && (processingFormat.mFormatFlags & kAudioFormatFlagIsFloat) != 0
            && processingFormat.mBitsPerChannel == 32
        let isNonInterleaved = (processingFormat.mFormatFlags & kAudioFormatFlagIsNonInterleaved) != 0
        let isSupported = isFloat32 && (1...2).contains(channelCount) && processingFormat.mSampleRate > 0
        diagnostics?.recordPrepare(
            sampleRate: processingFormat.mSampleRate,
            channelCount: channelCount,
            isSupported: isSupported
        )

        stateLock.withLock {
            state.prepare(
                maximumFrames: maximumFrames,
                sampleRate: processingFormat.mSampleRate,
                channelCount: channelCount,
                isFloat32: isFloat32,
                isNonInterleaved: isNonInterleaved,
                isSupported: isSupported
            )
        }
    }

    func unprepare() {
        diagnostics?.recordUnprepare()
        stateLock.withLock {
            state.unprepare()
        }
    }

    func update(configuration: VoiceBoostConfiguration) {
        stateLock.withLock {
            state.update(configuration: configuration)
        }
    }

    func reset() {
        stateLock.withLock {
            state.reset()
        }
    }

    func recordSourceError() {
        diagnostics?.recordSourceError()
    }

    func startTiming() -> UInt64? {
        guard diagnostics != nil else {
            return nil
        }
        return DispatchTime.now().uptimeNanoseconds
    }

    func recordProcess(frameCount: Int, wasProcessed: Bool, startedAt: UInt64?) {
        diagnostics?.recordProcess(
            frameCount: frameCount,
            wasProcessed: wasProcessed,
            durationNanoseconds: startedAt.map { DispatchTime.now().uptimeNanoseconds - $0 }
        )
    }

    @discardableResult
    func process(
        bufferList: UnsafeMutablePointer<AudioBufferList>,
        frameCount: Int
    ) -> Bool {
        stateLock.withLockIfAvailable {
            state.process(bufferList: bufferList, frameCount: frameCount)
        } ?? false
    }
}
