/// Where one tap process callback's frames went. Splitting the bypass
/// reasons keeps lock contention distinguishable from an intentional
/// disable and gives the drain path a visible state.
nonisolated enum VoiceBoostTapProcessOutcome: Equatable {
    /// Frames ran through the processor in steady state.
    case processedEngaged
    /// Frames ran through the processor during an enable/disable
    /// transition (drain, latency splice, or delay-line warmup).
    case processedTransition
    /// Steady-state disabled short-circuit: untouched, zero-latency dry.
    case bypassedDisabled
    /// The state lock was contended; the buffer passed through untouched.
    case bypassedContended
    /// No prepared processor or a format the tap cannot process.
    case bypassedUnsupported

    var wasProcessed: Bool {
        self == .processedEngaged || self == .processedTransition
    }
}
