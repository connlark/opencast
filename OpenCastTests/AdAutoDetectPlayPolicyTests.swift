import Testing
@testable import OpenCast

@MainActor
@Suite("Auto-detect play policy")
struct AdAutoDetectPlayPolicyTests {
    @Test("Play qualifies for an auto pass only when opted in, without an attached current analysis, and out of the queue")
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
            // Already queued or running.
            (true, false, .queued(ahead: 1), false),
            (true, false, .queued(ahead: 0), false),
            (true, false, .running, false),
            // A pass that completed this session left no current analysis
            // behind: decided like a never-scanned episode.
            (true, false, .completed(zoneCount: 2), true),
            // It needed the listener's key this session; playing it again
            // would only ask again.
            (true, false, .keyRequired(.noKey), false),
            // A parked cloud item still owns its server job.
            (true, false, .remoteParked(.connectionLost), false)
        ]

        for (isEnabled, hasAnalysis, status, expected) in cases {
            let policy = AdAutoDetectPlayPolicy(
                isAutoDetectEnabled: isEnabled,
                hasCurrentCompletedAnalysis: hasAnalysis,
                isAnalysisAttached: true,
                queueStatus: status
            )
            #expect(
                policy.shouldEnqueue == expected,
                "enabled \(isEnabled) hasAnalysis \(hasAnalysis) status \(status)"
            )
        }
    }

    @Test(
        "A detached analysis qualifies like a never-scanned episode; only a current, attached one is done",
        arguments: [
            // Detached, auto show: enqueue.
            (AdFreePassQueueEpisodeStatus.notQueued, true, false, true),
            // Retained completed, detached: enqueue.
            (.completed(zoneCount: 2), true, false, true),
            // Retained completed, attached but stale: enqueue.
            (.completed(zoneCount: 2), false, true, true),
            // Retained completed, attached and current: done.
            (.completed(zoneCount: 2), true, true, false),
            (.notQueued, true, true, false),
            // Work in the queue blocks whatever the attachment.
            (.queued(ahead: 1), true, false, false),
            (.queued(ahead: 1), false, false, false),
            (.running, true, false, false),
            (.running, false, true, false),
            (.remoteParked(.parked), true, false, false),
            (.remoteParked(.parked), false, false, false),
            // A key is still needed, detached or not.
            (.keyRequired(.noKey), true, false, false),
            (.keyRequired(.trialExhausted), false, false, false)
        ]
    )
    func attachmentDecidesDetachedPlays(
        status: AdFreePassQueueEpisodeStatus,
        isCurrent: Bool,
        isAttached: Bool,
        expected: Bool
    ) {
        let policy = AdAutoDetectPlayPolicy(
            isAutoDetectEnabled: true,
            hasCurrentCompletedAnalysis: isCurrent,
            isAnalysisAttached: isAttached,
            queueStatus: status
        )
        #expect(policy.shouldEnqueue == expected)
    }

    @Test(
        "A play reaches the policy only with no retained outcome or a completed one; a failure this session is not retried on play",
        arguments: [
            (AdFreePassQueueEpisodeStatus.notQueued, true),
            (.completed(zoneCount: 1), true),
            (.failed(message: "probe"), false),
            (.cloudUnavailable(message: "No credits."), false),
            (.keyRequired(.noKey), false),
            (.queued(ahead: 0), false),
            (.running, false),
            (.remoteParked(.parked), false)
        ]
    )
    func playAdmission(status: AdFreePassQueueEpisodeStatus, admitted: Bool) {
        #expect(AdAutoDetectPlayPolicy.admitsPlay(with: status) == admitted)
    }
}
