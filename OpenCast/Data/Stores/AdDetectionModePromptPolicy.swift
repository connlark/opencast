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
