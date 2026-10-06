import Foundation

/// Which of Apple's checks declined a request, read from the model's debug
/// text. Recorded for evaluation and retry policy; never shown to the
/// listener.
nonisolated enum TranscriptIntelligenceGuardrailSide: String, Equatable, Sendable {
    /// The input check ("Safety guardrail was triggered."). Deterministic for
    /// a given input.
    case input
    /// The output safety check ("Response may contain sensitive or unsafe
    /// content", also in a streamed form). Varies between attempts.
    case output
    /// The output recitation check ("Recitation detected"): the answer looked
    /// like a copy of existing text, such as a long run of consecutive line
    /// numbers.
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
