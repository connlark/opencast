import Foundation

/// What Recap and Ask can do right now, resolved from model eligibility, the
/// quota snapshot, and the last request failure. Ordered so the most
/// permanent reason wins: hardware, then the build, then quota, then network.
nonisolated enum TranscriptIntelligenceAvailability: Equatable, Sendable {
    case unsupportedDevice
    case appleIntelligenceOff
    case modelNotReady
    case notEntitled
    case offline
    case quotaReached(resetDate: Date?)
    case available

    /// A rate limit without a reset date blocks new requests for this long.
    static let rateLimitBackoff: TimeInterval = 5 * 60

    static func resolve(
        model: TranscriptIntelligenceModelAvailability,
        quota: TranscriptIntelligenceQuotaSnapshot,
        lastFailure: TranscriptIntelligenceFailure?,
        failedAt: Date?,
        now: Date
    ) -> TranscriptIntelligenceAvailability {
        switch model {
        case .deviceNotEligible:
            return .unsupportedDevice
        case .appleIntelligenceNotEnabled:
            return .appleIntelligenceOff
        case .systemNotReady:
            return .modelNotReady
        case .available:
            break
        }
        if lastFailure == .notEntitled {
            return .notEntitled
        }
        if quota.isLimitReached {
            return .quotaReached(resetDate: quota.resetDate)
        }
        switch lastFailure {
        case .rateLimited(let resetDate), .quotaLimitReached(let resetDate):
            let retryDate = resetDate ?? failedAt.map { $0.addingTimeInterval(rateLimitBackoff) }
            if let retryDate, now < retryDate {
                return .quotaReached(resetDate: retryDate)
            }
        case .offline, .serviceUnavailable:
            return .offline
        default:
            break
        }
        return .available
    }
}
