import Foundation

nonisolated enum TranscriptIntelligenceGuardrailSide: String, Equatable, Sendable {
    /// Deterministic for a given input.
    case input
    /// Varies between attempts.
    case output
    /// Fires on output that looks copied, such as a long run of consecutive line numbers.
    case recitation
    case unknown

    init(debugDescription: String) {
        if debugDescription.contains("Safety guardrail was triggered") {
            self = .input
        } else if debugDescription.contains("may contain sensitive or unsafe content") {
            self = .output
        } else if debugDescription.contains("Recitation detected") {
            self = .recitation
        } else {
            self = .unknown
        }
    }
}
