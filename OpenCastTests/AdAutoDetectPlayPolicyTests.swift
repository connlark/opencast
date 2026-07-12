import Testing
@testable import OpenCast

@MainActor
@Suite("Auto-detect play policy")
struct AdAutoDetectPlayPolicyTests {
    @Test("Play qualifies for an auto pass only when opted in, unanalyzed, and out of the queue")
    func playQualificationTable() {
        let cases: [(Bool, Bool, AdFreePassQueueEpisodeStatus, Bool)] = [
            // Qualifying: toggle on, no current analysis, not in the queue.
            (true, false, .notQueued, true),
            // A failed item left the queue — the next play retries it.
            (true, false, .failed(message: "probe"), true),
            // Toggle off never enqueues.
            (false, false, .notQueued, false),
            (false, false, .failed(message: "probe"), false),
            // A current completed analysis never re-analyzes.
            (true, true, .notQueued, false),
            (true, true, .failed(message: "probe"), false),
            // Already queued, running, finished this session, or cap-deferred.
            (true, false, .queued(ahead: 1), false),
            (true, false, .queued(ahead: 0), false),
            (true, false, .running, false),
            (true, false, .completed(zoneCount: 2), false),
            (true, false, .capDeferred, false)
        ]

        for (isEnabled, hasAnalysis, status, expected) in cases {
            let policy = AdAutoDetectPlayPolicy(
                isAutoDetectEnabled: isEnabled,
                hasCurrentCompletedAnalysis: hasAnalysis,
                queueStatus: status
            )
            #expect(
                policy.shouldEnqueue == expected,
                "enabled \(isEnabled) hasAnalysis \(hasAnalysis) status \(status)"
            )
        }
    }
}
