nonisolated enum VoiceBoostTapProcessOutcome: Equatable {
    case processedEngaged
    case processedTransition
    case bypassedDisabled
    case bypassedContended
    case bypassedUnsupported

    var wasProcessed: Bool {
        self == .processedEngaged || self == .processedTransition
    }
}
