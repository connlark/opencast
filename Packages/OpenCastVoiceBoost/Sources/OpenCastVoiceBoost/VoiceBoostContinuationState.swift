import OpenCastVoiceBoostC

/// Loudness adaptation for a continuing listen, without audio or filter memory.
/// Completed energy buckets prevent a short passage after a handoff from
/// replacing the programme's established loudness estimate.
public struct VoiceBoostContinuationState: Sendable {
    var cState: OCVBContinuationState

    public var controlSnapshot: VoiceBoostControlSnapshot {
        VoiceBoostControlSnapshot(cSnapshot: cState.control)
    }

    public var integratedBlockCount: Int { Int(cState.integratedCount) }
}
