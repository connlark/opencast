/// Pure decision table for a manual Detect Ads tap. A completed local
/// transcript always runs on-device (the analysis-only path is free, so a
/// cloud job would only re-buy what already exists); a stored mode runs it;
/// unset asks — but only when the remote surface is visible at all.
nonisolated struct AdDetectionModePromptPolicy {
    enum Decision: Equatable {
        case runOnDevice
        case runCloud
        case prompt
    }

    let storedMode: AdDetectionMode?
    let hasCurrentCompletedTranscript: Bool
    let isRemoteSurfaceVisible: Bool

    var decision: Decision {
        if hasCurrentCompletedTranscript {
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
