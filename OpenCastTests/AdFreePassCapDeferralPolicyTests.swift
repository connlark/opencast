import Foundation
import Testing
@testable import OpenCast

@MainActor
@Suite("Ad-free pass cap deferral policy")
struct AdFreePassCapDeferralPolicyTests {
    @Test("429 with a worker cap code classifies as cap-exceeded; everything else does not")
    func capClassificationTable() {
        let capCodes = [
            "daily_request_cap_exceeded",
            "daily_input_token_cap_exceeded",
            "global_capacity_exhausted"
        ]
        for code in capCodes {
            #expect(EpisodeAdAnalysisHTTPError(statusCode: 429, code: code, detail: nil).isCapExceeded)
            // A cap code without the 429 status is not a cap rejection.
            #expect(!EpisodeAdAnalysisHTTPError(statusCode: 500, code: code, detail: nil).isCapExceeded)
        }
        #expect(!EpisodeAdAnalysisHTTPError(statusCode: 429, code: "rate_limited_other", detail: nil).isCapExceeded)
        #expect(!EpisodeAdAnalysisHTTPError(statusCode: 503, code: "overloaded", detail: nil).isCapExceeded)
    }

    @Test("One automatic probe per foreground session; manual taps always probe")
    func probePolicyTable() {
        typealias Trigger = AdFreePassCapDeferralPolicy.Trigger
        let cases: [(AdFreePassQueueState, Bool, Trigger, Bool)] = [
            (.capDeferred, false, .sceneActivated, true),
            (.capDeferred, false, .refreshCompleted, true),
            (.capDeferred, false, .manualTap, true),
            (.capDeferred, true, .sceneActivated, false),
            (.capDeferred, true, .refreshCompleted, false),
            (.capDeferred, true, .manualTap, true),
            (.idle, false, .sceneActivated, false),
            (.running, false, .refreshCompleted, false),
            (.pausedInterrupted, false, .manualTap, false),
            (.awaitingModelConsent, false, .sceneActivated, false)
        ]

        for (state, hasProbed, trigger, expected) in cases {
            let policy = AdFreePassCapDeferralPolicy(
                queueState: state,
                hasProbedThisForegroundSession: hasProbed,
                trigger: trigger
            )
            #expect(policy.shouldProbe == expected, "state \(state) hasProbed \(hasProbed) trigger \(trigger)")
        }
    }

    #if DEBUG
    @Test("Force-cap hook reads the environment variable or launch argument")
    func forceCapHookReadsEnvironmentAndArguments() {
        #expect(URLSessionEpisodeAdAnalysisClient.forcesCapRejection(
            environment: ["OPENCAST_ADANALYSIS_FORCE_CAP": "1"],
            arguments: []
        ))
        #expect(URLSessionEpisodeAdAnalysisClient.forcesCapRejection(
            environment: [:],
            arguments: ["-OPENCAST_ADANALYSIS_FORCE_CAP"]
        ))
        #expect(!URLSessionEpisodeAdAnalysisClient.forcesCapRejection(
            environment: ["OPENCAST_ADANALYSIS_FORCE_CAP": "0"],
            arguments: []
        ))
        #expect(!URLSessionEpisodeAdAnalysisClient.forcesCapRejection(
            environment: [:],
            arguments: []
        ))
    }
    #endif
}
