import Foundation
import OpenCastVoiceBoostC

/// A single-threaded wrapper around the Voice Boost DSP handle.
///
/// This type does not provide internal synchronization. Callers that share an
/// instance across threads must serialize `reset`, `update`, `process`, and
/// `metrics` access externally.
public final class VoiceBoostProcessor {
    private let handle: OpaquePointer
    private let channelCount: Int

    public init(
        sampleRate: Double,
        channelCount: Int,
        configuration: VoiceBoostConfiguration = .default
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

    /// Processes planar (non-interleaved) Float32 channel buffers in place —
    /// the production tap path, no marshalling copies. `channels` must hold
    /// `channelCount` non-nil pointers, each to `frameCount` samples.
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

    /// Routes interleaved processing through the retained pre-vectorization
    /// scalar implementation — the test oracle. Set once right after
    /// creation; the two engines keep independent signal state.
    public func setScalarReferenceProcessing(_ usesScalarReference: Bool) {
        OCVBProcessorSetScalarReferenceProcessing(handle, usesScalarReference ? 1 : 0)
    }

    public var metrics: VoiceBoostMetrics {
        VoiceBoostMetrics(cMetrics: OCVBProcessorCopyMetrics(handle))
    }

    /// Adaptation control state for carrying across processor recreation.
    /// Same external-serialization contract as every other member.
    public var controlSnapshot: VoiceBoostControlSnapshot {
        VoiceBoostControlSnapshot(cSnapshot: OCVBProcessorCopyControlSnapshot(handle))
    }

    public func apply(controlSnapshot: VoiceBoostControlSnapshot) {
        OCVBProcessorApplyControlSnapshot(handle, controlSnapshot.cSnapshot)
    }

    /// Wet/dry crossfade position: 1 fully wet, 0 fully dry. Reaches the
    /// exact endpoints, so equality against 0 detects a completed drain.
    public var currentWetMix: Double {
        OCVBProcessorCurrentWetMix(handle)
    }
}
