import Foundation
import FoundationModels

extension TranscriptIntelligenceFailure {
    /// Reduces a Foundation Models error to the product outcome. Tool failures
    /// unwrap to their cause; the unentitled-build code gets its own state
    /// because `availability` never reports it.
    nonisolated static func failure(mapping error: any Error) -> TranscriptIntelligenceFailure {
        if let failure = error as? TranscriptIntelligenceFailure {
            return failure
        }
        if error is CancellationError {
            return .cancelled
        }
        if let toolError = error as? LanguageModelSession.ToolCallError {
            return failure(mapping: toolError.underlyingError)
        }
        if let modelError = error as? LanguageModelError {
            return failure(modelError)
        }
        if let pccError = error as? PrivateCloudComputeLanguageModel.Error {
            return failure(pccError)
        }
        let nsError = error as NSError
        if isUnentitled(nsError) {
            return .notEntitled
        }
        if nsError.domain == NSURLErrorDomain {
            return .offline
        }
        return .unknown(nsError.localizedDescription)
    }

    private nonisolated static func failure(_ error: LanguageModelError) -> TranscriptIntelligenceFailure {
        switch error {
        case .guardrailViolation:
            .guardrailViolation
        case .refusal:
            .refusal
        case .rateLimited(let detail):
            .rateLimited(resetDate: detail.resetDate)
        case .contextSizeExceeded(let detail):
            .contextSizeExceeded(tokenCount: detail.tokenCount, contextSize: detail.contextSize)
        case .unsupportedLanguageOrLocale:
            .unsupportedLanguage
        case .timeout:
            .timeout
        case .unsupportedCapability, .unsupportedTranscriptContent, .unsupportedGenerationGuide:
            .unknown(error.localizedDescription)
        @unknown default:
            .unknown(error.localizedDescription)
        }
    }

    private nonisolated static func failure(_ error: PrivateCloudComputeLanguageModel.Error) -> TranscriptIntelligenceFailure {
        switch error {
        case .networkFailure:
            .offline
        case .quotaLimitReached(let detail):
            .quotaLimitReached(resetDate: detail.resetDate)
        case .serviceUnavailable:
            .serviceUnavailable
        @unknown default:
            .unknown(error.localizedDescription)
        }
    }

    /// `ModelManagerServices.ModelManagerError` 1046: the process lacks
    /// `com.apple.developer.private-cloud-compute`.
    private nonisolated static let unentitledErrorCode = 1046

    private nonisolated static func isUnentitled(_ error: NSError) -> Bool {
        if error.domain.contains("ModelManager"), error.code == unentitledErrorCode {
            return true
        }
        var underlying = error.userInfo[NSMultipleUnderlyingErrorsKey] as? [NSError] ?? []
        if let single = error.userInfo[NSUnderlyingErrorKey] as? NSError {
            underlying.append(single)
        }
        return underlying.contains(where: isUnentitled)
    }
}
