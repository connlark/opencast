import OpenCastVoiceBoostC

/// Carries no audio or filter memory. Its completed energy buckets stop a short passage after
/// a handoff from replacing the established loudness estimate.
public struct VoiceBoostContinuationState: Sendable {
    var cState: OCVBContinuationState

    public var controlSnapshot: VoiceBoostControlSnapshot {
        VoiceBoostControlSnapshot(cSnapshot: cState.control)
    }

    public var integratedBlockCount: Int { Int(cState.integratedCount) }
}
