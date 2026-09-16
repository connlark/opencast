import Foundation

/// Every way a Private Cloud Compute request ends short of a result, reduced
/// to what the product reacts to. The PCC client maps Foundation Models
/// errors here; the scripted test client throws these directly.
nonisolated enum TranscriptIntelligenceFailure: Error, Equatable, Sendable {
    case cancelled
    /// Apple's input or output guardrail declined the passage. Never retried.
    case guardrailViolation
    case refusal
    case rateLimited(resetDate: Date?)
    case quotaLimitReached(resetDate: Date?)
    case contextSizeExceeded(tokenCount: Int, contextSize: Int)
    /// Generation failed because the running build lacks the PCC entitlement;
    /// availability reads `.available` regardless, so only a request tells.
    case notEntitled
    case offline
    case serviceUnavailable
    case timeout
    case unsupportedLanguage
    case malformedOutput
    case unknown(String)

    /// Clears on the next availability refresh. The rest either persist for
    /// the process (`notEntitled`) or expire on their own clock (rate limits).
    var isTransient: Bool {
        switch self {
        case .notEntitled, .rateLimited, .quotaLimitReached:
            false
        case .cancelled, .guardrailViolation, .refusal, .contextSizeExceeded, .offline,
             .serviceUnavailable, .timeout, .unsupportedLanguage, .malformedOutput, .unknown:
            true
        }
    }

    /// Calm, per-request copy. Cancellation is normal and shows nothing.
    var userMessage: String? {
        switch self {
        case .cancelled:
            nil
        case .guardrailViolation, .refusal:
            "Apple’s model declined this passage."
        case .rateLimited, .quotaLimitReached:
            "Apple Intelligence usage limit reached. Try again later."
        case .contextSizeExceeded:
            "This passage is too long for Apple’s model."
        case .notEntitled:
            "Recap and Ask aren’t available in this build."
        case .offline:
            "You’re offline. Recap and Ask need a connection to Apple’s Private Cloud Compute."
        case .serviceUnavailable:
            "Apple’s Private Cloud Compute is unavailable right now."
        case .timeout:
            "Apple’s model took too long to respond."
        case .unsupportedLanguage:
            "Apple’s model doesn’t support this transcript’s language."
        case .malformedOutput:
            "Couldn’t read the model’s answer."
        case .unknown(let description):
            "Apple’s model couldn’t respond: \(description)"
        }
    }
}
