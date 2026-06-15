import Foundation
import Testing
@testable import OpenCastPlayback

@Suite("Playback failure recovery policy")
@MainActor
struct PlaybackFailureRecoveryPolicyTests {
    @Test
    func timeoutErrorsAreEligibleForOneAutomaticRetry() {
        var policy = PlaybackFailureRecoveryPolicy()
        let timeout = NSError(domain: NSURLErrorDomain, code: NSURLErrorTimedOut)

        let firstAttempt = policy.shouldAttemptAutomaticRetry(error: timeout, errorLog: nil)
        #expect(firstAttempt)
        #expect(policy.automaticTransientFailureRetryCount == 1)
        let secondAttempt = policy.shouldAttemptAutomaticRetry(error: timeout, errorLog: nil)
        #expect(!secondAttempt)

        policy.reset()
        let resetAttempt = policy.shouldAttemptAutomaticRetry(error: timeout, errorLog: nil)
        #expect(resetAttempt)
    }

    @Test
    func underlyingTimeoutErrorIsEligibleForAutomaticRetry() {
        var policy = PlaybackFailureRecoveryPolicy()
        let timeout = NSError(domain: NSURLErrorDomain, code: NSURLErrorTimedOut)
        let wrapper = NSError(
            domain: "AVFoundationErrorDomain",
            code: -11800,
            userInfo: [NSUnderlyingErrorKey: timeout]
        )

        let attempt = policy.shouldAttemptAutomaticRetry(error: wrapper, errorLog: nil)
        #expect(attempt)
    }

    @Test
    func localizedDescriptionTimeoutErrorIsEligibleForAutomaticRetry() {
        var policy = PlaybackFailureRecoveryPolicy()
        let wrapper = NSError(
            domain: "AVFoundationErrorDomain",
            code: -11800,
            userInfo: [NSLocalizedDescriptionKey: "The playback request timed out."]
        )

        let attempt = policy.shouldAttemptAutomaticRetry(error: wrapper, errorLog: nil)
        #expect(attempt)
    }

    @Test
    func urlErrorLogTimeoutFieldsAreEligibleForAutomaticRetry() {
        let isTimeout = PlaybackFailureRecoveryPolicy.errorLogFieldsIndicateTimedOut(
            errorDomain: NSURLErrorDomain,
            errorStatusCode: NSURLErrorTimedOut,
            errorComment: nil
        )

        #expect(isTimeout)
    }

    @Test
    func nonURLErrorLogStatusCodeOnlyTimeoutIsNotEligibleForAutomaticRetry() {
        let statusCodeOnlyTimeout = PlaybackFailureRecoveryPolicy.errorLogFieldsIndicateTimedOut(
            errorDomain: "AVFoundationErrorDomain",
            errorStatusCode: NSURLErrorTimedOut,
            errorComment: nil
        )
        let commentTimeout = PlaybackFailureRecoveryPolicy.errorLogFieldsIndicateTimedOut(
            errorDomain: "AVFoundationErrorDomain",
            errorStatusCode: NSURLErrorTimedOut,
            errorComment: "The media request timed out while loading."
        )

        #expect(!statusCodeOnlyTimeout)
        #expect(commentTimeout)
    }

    @Test
    func nonTimeoutErrorsAreNotEligibleForAutomaticRetry() {
        var policy = PlaybackFailureRecoveryPolicy()
        let offline = NSError(domain: NSURLErrorDomain, code: NSURLErrorNotConnectedToInternet)

        let attempt = policy.shouldAttemptAutomaticRetry(error: offline, errorLog: nil)
        #expect(!attempt)
        #expect(policy.automaticTransientFailureRetryCount == 0)
    }
}
