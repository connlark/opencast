import Foundation
import OpenCastVoiceBoostC

/// Not synchronized: callers sharing an instance across threads must serialize every access.
public final class VoiceBoostProcessor {
    private let handle: OpaquePointer
    private let channelCount: Int

    /// `measuresOutputTruePeak` affects reporting only: limiting and output are unchanged.
    public init(
        sampleRate: Double,
        channelCount: Int,
        configuration: VoiceBoostConfiguration = .default,
        measuresOutputTruePeak: Bool = true
    ) {
        precondition(sampleRate.isFinite && sampleRate > 0, "VoiceBoostProcessor requires a positive sample rate.")
        precondition((1...2).contains(channelCount), "VoiceBoostProcessor v1 supports mono and stereo.")

        guard let handle = OCVBProcessorCreate(
            sampleRate,
            Int32(channelCount),
            configuration.cConfiguration
        ) else {
            preconditionFailure("Unable to create VoiceBoostProcessor.")
        }

        self.handle = handle
        self.channelCount = channelCount
        OCVBProcessorSetOutputTruePeakMeteringEnabled(handle, measuresOutputTruePeak ? 1 : 0)
    }

    deinit {
        OCVBProcessorDestroy(handle)
    }

    public func reset() {
        OCVBProcessorReset(handle)
    }

    public func update(configuration: VoiceBoostConfiguration) {
        OCVBProcessorUpdateConfiguration(handle, configuration.cConfiguration)
    }

    public func processInterleavedFloat32(
        _ buffer: UnsafeMutableBufferPointer<Float>,
        frameCount: Int
    ) {
        guard frameCount >= 0 else {
            assertionFailure("Frame count cannot be negative.")
            return
        }

        let requiredSampleCount = frameCount * channelCount
        guard buffer.count >= requiredSampleCount else {
            assertionFailure("Buffer is smaller than frameCount * channelCount.")
            return
        }

        guard frameCount > 0, let baseAddress = buffer.baseAddress else {
            return
        }

        OCVBProcessorProcessInterleavedFloat32(handle, baseAddress, Int32(frameCount))
    }

    /// In place. `channels` holds `channelCount` non-nil pointers to `frameCount` samples each.
    public func processPlanarFloat32(
        _ channels: UnsafeMutablePointer<UnsafeMutablePointer<Float>?>,
        frameCount: Int
    ) {
        guard frameCount > 0 else {
            return
        }
        for channel in 0..<channelCount {
            guard channels[channel] != nil else {
                assertionFailure("Planar processing requires a pointer per channel.")
                return
            }
        }
        OCVBProcessorProcessPlanarFloat32(handle, channels, Int32(frameCount))
    }

    /// Set once, right after creation: the scalar and vectorized engines keep independent signal
    /// state.
    public func setScalarReferenceProcessing(_ usesScalarReference: Bool) {
        OCVBProcessorSetScalarReferenceProcessing(handle, usesScalarReference ? 1 : 0)
    }

    public var metrics: VoiceBoostMetrics {
        VoiceBoostMetrics(cMetrics: OCVBProcessorCopyMetrics(handle))
    }

    public var controlSnapshot: VoiceBoostControlSnapshot {
        VoiceBoostControlSnapshot(cSnapshot: OCVBProcessorCopyControlSnapshot(handle))
    }

    public func apply(controlSnapshot: VoiceBoostControlSnapshot) {
        OCVBProcessorApplyControlSnapshot(handle, controlSnapshot.cSnapshot)
    }

    public var continuationState: VoiceBoostContinuationState {
        var state = OCVBContinuationState()
        OCVBProcessorCopyContinuationState(handle, &state)
        return VoiceBoostContinuationState(cState: state)
    }

    public func apply(continuationState: VoiceBoostContinuationState) {
        withUnsafePointer(to: continuationState.cState) {
            OCVBProcessorApplyContinuationState(handle, $0)
        }
    }

    /// Wet/dry crossfade position: 1 fully wet, 0 fully dry. Reaches the
    /// exact endpoints, so equality against 0 detects a completed drain.
    public var currentWetMix: Double {
        OCVBProcessorCurrentWetMix(handle)
    }
}
