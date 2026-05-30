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

    public var metrics: VoiceBoostMetrics {
        VoiceBoostMetrics(cMetrics: OCVBProcessorCopyMetrics(handle))
    }
}
