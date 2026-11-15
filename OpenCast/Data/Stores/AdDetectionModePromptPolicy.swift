/// Pure decision table for a manual Detect Ads tap. A completed transcript
/// of the trusted download always runs on-device (the analysis-only path is
/// free, so a cloud job would only re-buy what already exists); a stored
/// mode runs it; unset asks — but only when the remote surface is visible at
/// all. A transcript of other bytes counts as none: the pass transcribes the
/// download again, in whichever mode this picks.
nonisolated struct AdDetectionModePromptPolicy {
    enum Decision: Equatable {
        case runOnDevice
        case runCloud
        case prompt
    }

    let storedMode: AdDetectionMode?
    let hasAttachedCompletedTranscript: Bool
    let isRemoteSurfaceVisible: Bool

    var decision: Decision {
        if hasAttachedCompletedTranscript {
            return .runOnDevice
        }
        switch storedMode {
        case .onDevice:
            return .runOnDevice
        case .cloud:
            return .runCloud
        case nil:
            return isRemoteSurfaceVisible ? .prompt : .runOnDevice
        }
    }
}
