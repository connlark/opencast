import Foundation
import Testing
@testable import OpenCast

@Suite("Transcript intelligence availability")
struct TranscriptIntelligenceAvailabilityTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func resolve(
        model: TranscriptIntelligenceModelAvailability = .available,
        quota: TranscriptIntelligenceQuotaSnapshot = TranscriptIntelligenceQuotaSnapshot(),
        lastFailure: TranscriptIntelligenceFailure? = nil,
        failedAt: Date? = nil
    ) -> TranscriptIntelligenceAvailability {
        TranscriptIntelligenceAvailability.resolve(
            model: model,
            quota: quota,
            lastFailure: lastFailure,
            failedAt: failedAt ?? now,
            now: now
        )
    }

    @Test("Model eligibility wins over everything else")
    func modelEligibilityWins() {
        let limitReached = TranscriptIntelligenceQuotaSnapshot(isLimitReached: true)
        #expect(resolve(model: .deviceNotEligible, quota: limitReached, lastFailure: .notEntitled) == .unsupportedDevice)
        #expect(resolve(model: .appleIntelligenceNotEnabled, lastFailure: .notEntitled) == .appleIntelligenceOff)
        #expect(resolve(model: .systemNotReady, lastFailure: .offline) == .modelNotReady)
    }

    @Test("An unentitled build outranks quota and network state")
    func notEntitledOutranksQuota() {
        let limitReached = TranscriptIntelligenceQuotaSnapshot(isLimitReached: true)
        #expect(resolve(quota: limitReached, lastFailure: .notEntitled) == .notEntitled)
    }

    @Test("A reached quota snapshot reports its reset date")
    func quotaSnapshotLimitReached() {
        let reset = now.addingTimeInterval(3_600)
        let quota = TranscriptIntelligenceQuotaSnapshot(isLimitReached: true, resetDate: reset)
        #expect(resolve(quota: quota) == .quotaReached(resetDate: reset))
        #expect(resolve(quota: quota, lastFailure: .offline) == .quotaReached(resetDate: reset))
    }

    @Test("A rate limit with a reset date blocks until that date")
    func rateLimitWithResetDate() {
        let reset = now.addingTimeInterval(120)
        #expect(resolve(lastFailure: .rateLimited(resetDate: reset)) == .quotaReached(resetDate: reset))
        #expect(resolve(lastFailure: .quotaLimitReached(resetDate: reset)) == .quotaReached(resetDate: reset))
        let past = now.addingTimeInterval(-1)
        #expect(resolve(lastFailure: .rateLimited(resetDate: past)) == .available)
    }

    @Test("A rate limit without a reset date backs off for five minutes")
    func rateLimitWithoutResetDate() {
        let failedAt = now.addingTimeInterval(-60)
        let expectedRetry = failedAt.addingTimeInterval(TranscriptIntelligenceAvailability.rateLimitBackoff)
        #expect(resolve(lastFailure: .rateLimited(resetDate: nil), failedAt: failedAt) == .quotaReached(resetDate: expectedRetry))
        let expired = now.addingTimeInterval(-TranscriptIntelligenceAvailability.rateLimitBackoff)
        #expect(resolve(lastFailure: .rateLimited(resetDate: nil), failedAt: expired) == .available)
    }

    @Test("Network failures read as offline until refreshed")
    func networkFailuresReadOffline() {
        #expect(resolve(lastFailure: .offline) == .offline)
        #expect(resolve(lastFailure: .serviceUnavailable) == .offline)
    }

    @Test("Per-request outcomes leave the feature available")
    func perRequestOutcomesStayAvailable() {
        #expect(resolve() == .available)
        #expect(resolve(lastFailure: .guardrailViolation) == .available)
        #expect(resolve(lastFailure: .refusal) == .available)
        #expect(resolve(lastFailure: .timeout) == .available)
        #expect(resolve(lastFailure: .contextSizeExceeded(tokenCount: 40_000, contextSize: 32_768)) == .available)
        #expect(resolve(lastFailure: .malformedOutput) == .available)
        #expect(resolve(lastFailure: .unknown("x")) == .available)
    }

    @Test("Transient failures clear on refresh; the rest persist")
    func transientFailures() {
        #expect(TranscriptIntelligenceFailure.offline.isTransient)
        #expect(TranscriptIntelligenceFailure.guardrailViolation.isTransient)
        #expect(!TranscriptIntelligenceFailure.notEntitled.isTransient)
        #expect(!TranscriptIntelligenceFailure.rateLimited(resetDate: nil).isTransient)
        #expect(!TranscriptIntelligenceFailure.quotaLimitReached(resetDate: nil).isTransient)
    }

    @Test("Cancellation carries no user message; everything else does")
    func userMessages() {
        #expect(TranscriptIntelligenceFailure.cancelled.userMessage == nil)
        #expect(TranscriptIntelligenceFailure.guardrailViolation.userMessage == "Apple’s model declined this passage.")
        #expect(TranscriptIntelligenceFailure.unknown("boom").userMessage?.contains("boom") == true)
    }
}
